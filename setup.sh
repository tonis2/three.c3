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
	# archive is too large for git, so it lives on that repository's `static`
	# orphan branch and this fetches it: the same arrangement as run_driver
	# below, for the same reason.
	#
	# Skipping it fails at the linker with "library not found for -lslang".
	#
	# A target nobody has published yet has to be built on a machine of that
	# architecture — Slang runs code generators it compiled for the host, so
	# there is no cross-build — with lib/slang.c3l/native/build-slang.sh, then
	# pushed with native/publish-static.sh. Only macos-aarch64 exists today, and
	# fetch-static.sh says so by name when it comes up empty.
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

	local target="lib/vulkan.c3l/macos-aarch64/libvulkan_kosmickrisp.dylib"
	echo "==> driver"

	# 10 MB rather than -f: a failed fetch also leaves a file behind, and an
	# HTML error page saved under this name would otherwise be reported as a
	# working driver. It has never been under 14 MB.
	if [[ -f "$target" && "$(wc -c < "$target")" -gt 10000000 ]]; then
		echo "    already present"
		return 0
	fi

	# KosmicKrisp is 15 MB and is rebuilt on every Mesa bump, so vulkan.c3l keeps
	# it on a `driver` orphan branch that is amended and force-pushed rather than
	# added to — one revision, however many bumps. It is therefore not on main
	# and not in the submodule checkout.
	#
	# **Skipping this does not fail the build.** vk::findBundledDriver treats "no
	# bundled driver" as a normal outcome and falls back to the loader's own ICD
	# discovery (vk/driver.c3), so three runs on whatever other ICD is installed,
	# or reports no devices — neither of which mentions a missing file.
	git -C lib/vulkan.c3l fetch --depth 1 origin driver
	git -C lib/vulkan.c3l cat-file blob FETCH_HEAD:libvulkan_kosmickrisp.dylib > "$target"
	chmod 755 "$target"

	if [[ "$(wc -c < "$target")" -lt 10000000 ]]; then
		rm -f "$target"
		echo "    the fetched driver is too small to be one — removed" >&2
		exit 1
	fi
	echo "    fetched $(git -C lib/vulkan.c3l show FETCH_HEAD:VERSION 2>/dev/null || echo 'unversioned')"
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
