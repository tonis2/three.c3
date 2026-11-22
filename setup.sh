#!/usr/bin/env bash
#
# Everything a fresh checkout needs before `c3c build` works.
#
#     ./setup.sh              # all of it
#     ./setup.sh submodules   # just one step, by name
#     ./setup.sh driver
#     ./setup.sh android      # the OpenXR loader for the Quest build (not in "all")
#
# Safe to re-run: every step checks whether it has already been done.
#
# ## Why a checkout is not enough on its own
#
# One of this project's dependencies carries binaries that are deliberately not
# in git: somebody else's build, tens of megabytes, replaced wholesale rather
# than edited, and useless to every version of the repository except the one it
# shipped with. Git keeps every version of a tracked file for ever, so
# committing them charges every clone, and every clone of anything using this as
# a submodule, for binaries nobody will run again.
#
# **They are release assets, not an orphan branch.** The driver used to live on
# a `driver` branch, which is a trick that does not work: a branch keeps a
# binary out of a checkout but not out of the object database, `git clone`
# fetches every `refs/heads/*` unconditionally, and no setting opts one out. So
# every clone paid for it anyway. An asset is reachable from no ref — a clone
# costs nothing and the fetch is on demand, verified against a hash committed
# beside the script.
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
	# --recursive because cui.c3l and ktx.c3l have submodules of their own —
	# font, image and window under cui; getopt and image under ktx. Without it
	# those trees come back empty and c3c fails on missing dependencies rather
	# than on anything that names a submodule.
	git submodule update --init --recursive
}

run_driver() {
	# Only macOS on Apple Silicon needs these dylibs at all. Linux and Windows
	# have a system Vulkan and the loader finds it; there is nothing to fetch.
	if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
		echo "==> driver: not macOS arm64, nothing to fetch"
		return 0
	fi

	echo "==> driver"
	# KosmicKrisp is 15 MB and the loader 1.4 MB, and both are replaced whenever
	# Mesa or the SDK is bumped, so vulkan.c3l keeps them as assets on its rolling
	# `latest` release rather than in git, pinned by that repository's
	# dylibs.sha256 — sha256, name and the version the bytes were built from. They
	# are therefore not on main and not in the submodule checkout.
	#
	# The script does the size and hash checking this step used to do inline, and
	# is a no-op with the files already there. It is also what build.sh and
	# vulkan.c3l's own release workflow call, so there is one fetch to get wrong.
	#
	# **Skipping this does not fail the build.** vk::findBundledDriver treats "no
	# bundled driver" as a normal outcome and falls back to the loader's own ICD
	# discovery (vk/driver.c3), so three runs on whatever other ICD is installed,
	# or reports no devices — neither of which mentions a missing file.
	./lib/vulkan.c3l/fetch-dylibs.sh
}

run_android() {
	# The Khronos OpenXR loader for Android, which the Quest APK ships beside
	# libthree.so. Published as an AAR on Maven Central; pinned by version and
	# the sha1 Maven publishes beside it. packaging/android/build-apk.sh links
	# against jni/arm64-v8a/libopenxr_loader.so out of the unpacked copy.
	local version="1.1.65"
	local sha1="b81c1049f63302428fbf473d1b310de51c32b969"
	local dir="packaging/android/third_party"
	local aar="$dir/openxr_loader_for_android-$version.aar"
	echo "==> android: OpenXR loader $version"
	mkdir -p "$dir"
	if [[ ! -f "$aar" ]]; then
		curl -fsSL -o "$aar.part" \
			"https://repo1.maven.org/maven2/org/khronos/openxr/openxr_loader_for_android/$version/openxr_loader_for_android-$version.aar"
		mv "$aar.part" "$aar"
	fi
	# sha1sum is missing on older macOS; shasum is everywhere Perl is.
	local sum
	if command -v sha1sum >/dev/null; then sum="$(sha1sum "$aar")"; else sum="$(shasum -a 1 "$aar")"; fi
	if [[ "${sum%% *}" != "$sha1" ]]; then
		echo "setup: $aar does not match its pinned sha1" >&2
		rm -f "$aar"
		exit 1
	fi
	rm -rf "$dir/aar"
	mkdir -p "$dir/aar"
	unzip -q -o "$aar" -d "$dir/aar"
}

case "$step" in
	all)        run_submodules; run_driver ;;
	submodules) run_submodules ;;
	driver)     run_driver ;;
	android)    run_android ;;
	-h|--help)  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)          echo "setup: unknown step '$step' (all, submodules, driver, android)" >&2; exit 2 ;;
esac

echo "==> done"
