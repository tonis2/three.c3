#!/usr/bin/env bash
#
# Builds the Quest APK: the engine as a NativeActivity, with one game inside.
#
#     packaging/android/build-apk.sh [game] [--install] [--run]
#
# `game` is a .js file (packed as script.js) or a directory holding a main.js.
# It defaults to examples/vr_castle.js. --install puts the APK on the headset
# adb is connected to; --run also launches it.
#
# A game pushed to the headset beats the packed one, so a script can be changed
# without a rebuild:
#
#     adb push my_scene.js /sdcard/Android/data/dev.threec3.quest/files/game/script.js
#
# Needs the Android SDK (platform 34+, build-tools, NDK) and `./setup.sh android`.
# The SDK is found from ANDROID_HOME / ANDROID_SDK_ROOT, else from where adb is.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/packaging/android"
PACKAGE="dev.threec3.quest"
API=32

game="$ROOT/examples/vr_castle.js"
install=0
run=0
for arg in "$@"; do
	case "$arg" in
		--install) install=1 ;;
		--run)     install=1; run=1 ;;
		-h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)         game="$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")" ;;
	esac
done

sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$sdk" ]] && command -v adb >/dev/null; then
	sdk="$(cd "$(dirname "$(readlink -f "$(command -v adb)")")/.." && pwd)"
fi
[[ -d "$sdk/platforms" ]] || { echo "build-apk: no Android SDK; set ANDROID_HOME" >&2; exit 1; }

latest() { ls -1 "$1" | sort -V | tail -1; }
ndk="${ANDROID_NDK:-$sdk/ndk/$(latest "$sdk/ndk")}"
tools="$sdk/build-tools/$(latest "$sdk/build-tools")"
platform="$sdk/platforms/$(latest "$sdk/platforms")/android.jar"
# The NDK ships one prebuilt toolchain per host: linux-x86_64, darwin-x86_64, ...
bin="$(echo "$ndk"/toolchains/llvm/prebuilt/*/bin)"
cc="$bin/aarch64-linux-android$API-clang"
[[ -x "$cc" ]] || { echo "build-apk: no $cc" >&2; exit 1; }
sha1() { if command -v sha1sum >/dev/null; then sha1sum; else shasum -a 1; fi; }

loader="$HERE/third_party/aar/jni/arm64-v8a/libopenxr_loader.so"
[[ -f "$loader" ]] || { echo "build-apk: no OpenXR loader; run ./setup.sh android" >&2; exit 1; }

out="$ROOT/build/android"
rm -rf "$out/apk" "$out/obj"
mkdir -p "$out/apk/lib/arm64-v8a" "$out/apk/assets/game" "$out/obj"

echo "==> engine (c3c, android-aarch64)"
(cd "$ROOT" && c3c build quest --android-ndk "$ndk")

echo "==> libthree.so"
"$cc" -O2 -fPIC -c "$ndk/sources/android/native_app_glue/android_native_app_glue.c" -o "$out/obj/glue.o"
# --no-undefined so a missing symbol fails here rather than at dlopen on the headset.
"$cc" -shared -o "$out/apk/lib/arm64-v8a/libthree.so" \
	"$out/obj/glue.o" "$ROOT/build/quest.a" \
	"$ROOT/lib/ktx.c3l/lib/android-aarch64/libzstd.a" \
	-L"$(dirname "$loader")" -lopenxr_loader \
	-landroid -llog -lm -ldl \
	-u ANativeActivity_onCreate \
	-Wl,--no-undefined -Wl,-soname,libthree.so -Wl,-z,max-page-size=16384
cp "$loader" "$out/apk/lib/arm64-v8a/"

echo "==> game: ${game#"$ROOT/"}"
if [[ -d "$game" ]]; then
	[[ -f "$game/main.js" ]] || { echo "build-apk: $game has no main.js" >&2; exit 1; }
	cp -r "$game/." "$out/apk/assets/game/"
	# aapt2 leaves dot files and folders out of the assets, so they go before the
	# list is made: a listed file the APK lacks stops the unpack on the headset.
	find "$out/apk/assets/game" -mindepth 1 -name '.*' -prune -exec rm -rf {} +
else
	cp "$game" "$out/apk/assets/game/script.js"
fi
# The stamp tells the app to unpack again; the list is what it unpacks, since an
# APK's assets cannot be listed recursively from native code.
(
	cd "$out/apk/assets/game"
	echo "$(date -u +%Y%m%dT%H%M%SZ)-$(find . -type f -print0 | sort -z | xargs -0 cat | sha1 | cut -c1-12)"
	find . -type f ! -name manifest.txt | sed 's|^\./||' | sort
) > "$out/manifest.txt"
mv "$out/manifest.txt" "$out/apk/assets/game/manifest.txt"

echo "==> apk"
keystore="$HERE/debug.keystore"
if [[ ! -f "$keystore" ]]; then
	keytool -genkeypair -keystore "$keystore" -alias three -keyalg RSA -keysize 2048 -validity 10000 \
		-storepass android -keypass android -dname "CN=three.c3 debug" >/dev/null
fi
"$tools/aapt2" link -o "$out/unaligned.apk" --manifest "$HERE/AndroidManifest.xml" -I "$platform" -A "$out/apk/assets"
(cd "$out/apk" && zip -q -r "$out/unaligned.apk" lib)
"$tools/zipalign" -f -p 4 "$out/unaligned.apk" "$out/aligned.apk"
"$tools/apksigner" sign --ks "$keystore" --ks-pass pass:android --key-pass pass:android \
	--out "$out/three.apk" "$out/aligned.apk"
rm -f "$out/unaligned.apk" "$out/aligned.apk"
echo "wrote ${out#"$ROOT/"}/three.apk ($(du -h "$out/three.apk" | cut -f1))"

if (( install )); then
	echo "==> install"
	# An install signed with another machine's debug key cannot be updated in place.
	if ! result="$(adb install -r "$out/three.apk" 2>&1)"; then
		echo "$result"
		if [[ "$result" == *INSTALL_FAILED_UPDATE_INCOMPATIBLE* ]]; then
			echo "==> signed with another key; uninstalling the old one"
			adb uninstall "$PACKAGE"
			adb install "$out/three.apk"
		else
			exit 1
		fi
	fi
fi
if (( run )); then
	adb shell am force-stop "$PACKAGE"
	adb shell am start -n "$PACKAGE/android.app.NativeActivity"
	echo "logs: adb logcat -s three:* OpenXR:* DEBUG:*"
fi
