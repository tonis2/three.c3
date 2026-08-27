#!/usr/bin/env bash
#
# Everything a fresh checkout needs before `c3c build` works.
#
#     ./setup.sh              # all of it
#     ./setup.sh submodules   # just one step, by name
#     ./setup.sh slang
#     ./setup.sh driver
#
# Safe to re-run: every step checks whether it has already been done.
#
# ## Why a checkout is not enough on its own
#
# Three of this project's dependencies carry binaries that are deliberately not
# in git, for the same reason in three shapes — somebody else's build, tens of
# megabytes, replaced wholesale rather than edited, and useless to every version
# of the repository except the one it shipped with. Git keeps every version of a
# tracked file for ever, so committing them charges every clone, and every clone
# of anything using this as a submodule, for binaries nobody will run again.
#
# **They are release assets, not orphan branches.** Both used to be branches,
# which is a trick that does not work: a branch keeps a binary out of a checkout
# but not out of the object database, `git clone` fetches every `refs/heads/*`
# unconditionally, and no setting opts one out. So every clone paid for them
# anyway. An asset is reachable from no ref — a clone costs nothing and the
# fetch is on demand, verified against a hash committed beside the script.
#
# The cost of that decision is this file. Without it the build does not fail
# cleanly — see each step below for how it fails instead, which is the part
# worth knowing.
#
set -euo pipefail
cd "$(dirname "$0")"

step="${1:-all}"

run_submodules() {
	echo "==> submodules"
	# sync first: an existing checkout may have a stale or malformed URL cached
	# in .git/config, and `update` would keep using it. .gitmodules is the
	# authority.
	git submodule sync --recursive
	# --recursive because quickjs.c3l has a submodule of its own, vendor/quickjs-ng,
	# which its shim #includes. Without it the build fails in the C compiler,
	# pointing at a missing header, with nothing on screen naming submodules.
	git submodule update --init --recursive
}

run_slang() {
	echo "==> slang"
	# slang.c3l links Slang IN, as one 43 MB static archive, and has no other
	# mode — no SDK on the machine, no dylibs beside the binary, no rpath. The
	# archive is too large for git, so it is published as a release asset on
	# that repository's `static` tag and this fetches it, verified against the
	# SHA256SUMS published beside it: the same arrangement as run_driver below,
	# for the same reason.
	#
	# Skipping it fails at the linker with "library not found for -lslang".
	#
	# A target nobody has published yet has to be built on a machine of that
	# architecture — Slang runs code generators it compiled for the host, so
	# there is no cross-build — with lib/slang.c3l/native/build-slang.sh, then
	# published with native/publish-static.sh. Only macos-aarch64 exists today,
	# and fetch-static.sh says so by name, listing what the release does have.
	#
	# **The archive carries no spirv-opt**, so src/shader/compile.c3's
	# SLANG_ARGUMENTS must keep its `-O0`. Without it every shader compile fails
	# with "failed to load downstream compiler 'spirv-opt'".
	./lib/slang.c3l/native/fetch-static.sh
}

run_driver() {
	# Only macOS on Apple Silicon bundles a driver at all. Linux and Windows
	# have a system Vulkan and the loader finds it; there is nothing to fetch.
	if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
		echo "==> driver: not macOS arm64, nothing to fetch"
		return 0
	fi

	echo "==> driver"
	# KosmicKrisp is 15 MB and is rebuilt on every Mesa bump, so vulkan.c3l keeps
	# it as an asset on its rolling `latest` release rather than in git, pinned by
	# that repository's driver.sha256. It is therefore not on main and not in the
	# submodule checkout.
	#
	# The script does the size and hash checking this step used to do inline, and
	# is a no-op with the file already there. It is also what build.sh and
	# vulkan.c3l's own release workflow call, so there is one fetch to get wrong.
	#
	# **Skipping this does not fail the build.** vk::findBundledDriver treats "no
	# bundled driver" as a normal outcome and falls back to the loader's own ICD
	# discovery (vk/driver.c3), so three runs on whatever other ICD is installed,
	# or reports no devices — neither of which mentions a missing file.
	./lib/vulkan.c3l/fetch-driver.sh
}

case "$step" in
	all)        run_submodules; run_slang; run_driver ;;
	submodules) run_submodules ;;
	slang)      run_slang ;;
	# `static` was this script's name for the Slang fetch while there was also a
	# dylib path to tell it apart from. There is not any more; kept so the old
	# invocation does not fail with "unknown step".
	static)     run_slang ;;
	driver)     run_driver ;;
	-h|--help)  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)          echo "setup: unknown step '$step' (all, submodules, slang, driver)" >&2; exit 2 ;;
esac

echo "==> done"
