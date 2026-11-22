#!/usr/bin/env bash
#
# Day-to-day work against a headset over adb, once build-apk.sh has installed
# the app.
#
#     packaging/android/quest.sh push <game.js | dir>   # the app reloads it, no restart
#     packaging/android/quest.sh clear                  # back to the game packed in the APK
#     packaging/android/quest.sh run | stop | restart
#     packaging/android/quest.sh mcp [port]             # agent tools on 127.0.0.1:<port> (8808)
#     packaging/android/quest.sh logs
#
set -euo pipefail

PACKAGE="dev.threec3.quest"
GAME="/sdcard/Android/data/$PACKAGE/files/game"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

start() { adb shell am start -n "$PACKAGE/android.app.NativeActivity" >/dev/null; }
stop() { adb shell am force-stop "$PACKAGE"; }

case "${1:-}" in
	push)
		[[ $# -ge 2 ]] || usage 2
		src="$2"
		adb shell mkdir -p "$GAME"
		if [[ -d "$src" ]]; then
			[[ -f "$src/main.js" ]] || { echo "quest: $src has no main.js" >&2; exit 1; }
			adb push "$src/." "$GAME/" >/dev/null
		else
			# main.js beats script.js, so one left from an earlier push would win.
			adb shell rm -f "$GAME/main.js"
			adb push "$src" "$GAME/script.js" >/dev/null
		fi
		# Touched last, so the reload sees the whole push.
		adb shell touch "$GAME/.reload"
		echo "pushed $src; the app reloads it"
		;;
	clear)
		adb shell rm -rf "$GAME"
		echo "cleared; restart to run the APK's own game"
		;;
	run) start ;;
	stop) stop ;;
	restart) stop; start ;;
	mcp)
		port="${2:-8808}"
		adb forward "tcp:$port" tcp:8808
		echo "mcp: http://127.0.0.1:$port/mcp is the headset"
		;;
	logs) adb logcat -s 'three:*' 'OpenXR:*' 'DEBUG:*' ;;
	-h|--help|"") usage ;;
	*) echo "quest: unknown command '$1'" >&2; usage 2 ;;
esac
