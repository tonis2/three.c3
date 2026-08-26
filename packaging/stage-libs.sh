#!/usr/bin/env bash
#
# Copy a staged native-library directory into a bundle, once per FILE rather
# than once per name.
#
#     ./packaging/stage-libs.sh lib/slang.c3l/lib/macos-aarch64 dist/three-macos-arm64
#
# `lib/slang.c3l/lib/<target>/` holds symlinks into a per-machine SDK, and on
# macOS three of its four names — libslang.dylib, libslang-compiler.dylib and
# libslang-compiler.<ver>.dylib — resolve to the SAME 27 MB file. A plain
# `cp -RL` dereferences each one separately and ships that file three times: a
# measured 115 MB bundle where 61 MB is the whole content.
#
# So: one real copy per distinct target, and every other name recreated as a
# relative symlink beside it. The loader is looking for a NAME, and both the
# install name recorded in the binary and any alias a future link might use
# keep working.
#
# Symlinks that survive a zip are a Unix thing. If `ln -s` is unavailable or
# fails — Windows without developer mode — the alias is copied instead, which
# is correct and merely larger, and Windows DLLs come without aliases anyway.
set -euo pipefail

src="${1:?usage: stage-libs.sh <srcdir> <outdir>}"
out="${2:?usage: stage-libs.sh <srcdir> <outdir>}"

[ -d "$src" ] || { echo "stage-libs: no such directory: $src" >&2; exit 1; }
mkdir -p "$out"

# python3 rather than `readlink -f`: BSD readlink only grew -f recently and the
# macOS runners are not guaranteed to have a coreutils one on PATH.
realpath_of() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# A newline-separated list stands in for an associative array, which bash 3.2 —
# still what /bin/bash is on macOS — does not have.
copied=""

for f in "$src"/*; do
	[ -e "$f" ] || continue                      # an empty directory globs to itself
	name="$(basename "$f")"
	real="$(realpath_of "$f")"
	realname="$(basename "$real")"

	case "
$copied" in
		*"
$realname"*) ;;                              # this FILE is already in the bundle
		*)
			cp -L "$real" "$out/$realname"
			chmod u+w "$out/$realname" 2>/dev/null || true
			copied="$copied
$realname"
			echo "  $realname  ($(wc -c < "$out/$realname" | tr -d ' ') bytes)"
			;;
	esac

	if [ "$name" != "$realname" ]; then
		ln -sf "$realname" "$out/$name" 2>/dev/null \
			|| cp -L "$real" "$out/$name"
		echo "  $name -> $realname"
	fi
done
