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
#     packaging/android/quest.sh perf [seconds]           # one row of frame cost and GPU clock
#     packaging/android/quest.sh bench [log]              # restart, run examples/vr_bench.js, a row a setup
#
set -euo pipefail

PACKAGE="dev.threec3.quest"
GAME="/sdcard/Android/data/$PACKAGE/files/game"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
	perf)
		# Watches the running app for a while and prints one row. The headset's GPU clock moves
		# with load (the governor keeps it 81-87% busy), so the engine's own gpu ms means little
		# without the level and clock beside it. Meta's VrApi line gives both once a second, and
		# cur_freq is sampled alongside it. Pin a level with `setprop debug.oculus.gpuLevel N`;
		# charging raises the clocks unless `setprop debug.crcs.disable_charging_boost 1`.
		secs="${2:-20}"
		adb logcat -c
		freqs="$(adb shell "for i in \$(seq $secs); do cat /sys/class/kgsl/kgsl-3d0/devfreq/cur_freq; sleep 1; done" | tr -d '\r')"
		props="$(adb shell 'echo "$(getprop debug.three.xr_scale)|$(getprop debug.oculus.gpuLevel)|$(getprop debug.crcs.disable_charging_boost)"' | tr -d '\r')"
		{ adb logcat -d -s 'three:*' 'VrApi:*'; echo "freqs $freqs" | tr '\n' ' '; echo; echo "props $props"; } | awk -v secs="$secs" '
			function tally(arr,   k, s) { s = ""; for (k in arr) s = s (s ? " " : "") k "x" arr[k]; return s ? s : "-" }
			/VrApi/ && /FPS=/ {
				n++
				k = split(substr($0, index($0, "FPS=")), f, ",")
				for (i = 1; i <= k; i++) {
					if (want_mhz) { split(f[i], a, "/"); sub("MHz", "", a[2]); mhz[a[2]]++; want_mhz = 0; continue }
					split(f[i], kv, "=")
					if (kv[1] == "FPS") { split(kv[2], a, "/"); fps += a[1] }
					else if (kv[1] ~ /^CPU[0-9]+\/GPU$/) { split(kv[2], a, "/"); cpul[a[1]]++; gpul[a[2]]++; want_mhz = 1 }
					else if (kv[1] == "App") { sub("ms", "", kv[2]); app += kv[2] }
					else if (kv[1] == "TW") { sub("ms", "", kv[2]); tw += kv[2] }
					else if (kv[1] == "GPU%") gpu += kv[2]
					else if (kv[1] == "Stale") stale += kv[2]
				}
			}
			/xr: [0-9.]+ fps, cpu/ {
				x++
				s = substr($0, index($0, "xr: ")); gsub(/[(),]/, " ", s)
				m = split(s, w, " ")
				for (i = 1; i < m; i++) {
					if (w[i + 1] == "fps") xfps += w[i]
					else if (w[i] == "cpu" || w[i] == "wait" || w[i] == "gpu" || w[i] == "prepare" || w[i] == "shadow" || w[i] == "ao" || w[i] == "scene" || w[i] == "post" || w[i] == "present") xr[w[i]] += w[i + 1]
				}
			}
			/^freqs / { for (i = 2; i <= NF; i++) cur[int($i / 1000000)]++ }
			/^props / { split(substr($0, 7), p, "|") }
			END {
				printf "perf: %d s, xr_scale %s, gpuLevel pin %s, charging boost %s\n", secs, p[1] ? p[1] : "default", p[2] ? p[2] : "none", p[3] == "1" ? "off" : "on"
				if (x) printf "  engine: %.1f fps, cpu %.2f ms, fence wait %.2f ms, gpu %.2f ms (prepare %.2f, shadow %.2f, ao %.2f, scene %.2f, post %.2f, present %.2f)  [%d reports]\n", xfps / x, xr["cpu"] / x, xr["wait"] / x, xr["gpu"] / x, xr["prepare"] / x, xr["shadow"] / x, xr["ao"] / x, xr["scene"] / x, xr["post"] / x, xr["present"] / x, x
				else print "  engine: no xr: lines (is the app running and drawing?)"
				if (n) printf "  VrApi:  %.1f fps, app gpu %.2f ms, timewarp %.2f ms, gpu busy %.0f%%, stale %d, GPU level %s, CPU level %s, MHz %s\n", fps / n, app / n, tw / n, 100 * gpu / n, stale, tally(gpul), tally(cpul), tally(mhz)
				else print "  VrApi:  no lines"
				printf "  cur_freq MHz: %s\n", tally(cur)
			}'
		;;
	bench)
		# The installed APK must be examples/vr_bench.js. It logs `bench: begin <name>` and
		# `bench: end <name> | ...` round each measured window; the VrApi lines between the two
		# are Meta's own GPU time for that setup. The log is streamed to a file, so a long run
		# can't lose its first setups to the headset's ring buffer.
		log="${2:-${TMPDIR:-/tmp}/vr_bench.log}"
		adb logcat -c
		adb logcat -v time -s 'three:*' 'VrApi:*' > "$log" &
		reader=$!
		trap 'kill $reader 2>/dev/null' EXIT
		stop; start
		echo "bench: running, log in $log"
		waited=0
		until grep -q 'bench: done' "$log"; do
			sleep 5
			waited=$((waited + 5))
			if [[ $waited -ge 900 ]]; then echo "bench: no 'bench: done' after 15 minutes" >&2; break; fi
		done
		kill $reader 2>/dev/null || true
		props="$(adb shell 'echo "$(getprop debug.three.xr_scale)|$(getprop debug.oculus.gpuLevel)|$(getprop debug.crcs.disable_charging_boost)"' | tr -d '\r')"
		echo "xr_scale ${props%%|*}, gpuLevel pin $(echo "$props" | cut -d'|' -f2), charging boost off: $(echo "$props" | cut -d'|' -f3)"
		awk '
			function tally(arr,   k, s) { s = ""; for (k in arr) s = s (s ? " " : "") k; return s ? s : "-" }
			/bench: the head moved/ { moved++; next }
			/bench: begin / { name = substr($0, index($0, "bench: begin ") + 13); n = 0; app = 0; busy = 0; stale = 0; delete lv; delete mhz; next }
			/bench: end / && name != "" {
				rest = substr($0, index($0, " | ") + 3)
				if (moved) rest = rest " | restarted " moved "x for head movement"
				printf "%-34s | app gpu %6.2f ms, busy %3.0f%%, stale %3d, level %s @ %s MHz | %s\n", name, n ? app / n : 0, n ? 100 * busy / n : 0, stale, tally(lv), tally(mhz), rest
				name = ""; moved = 0; next
			}
			name != "" && /VrApi/ && /FPS=/ {
				n++
				k = split(substr($0, index($0, "FPS=")), f, ",")
				for (i = 1; i <= k; i++) {
					if (want) { split(f[i], a, "/"); sub("MHz", "", a[2]); mhz[a[2]] = 1; want = 0; continue }
					split(f[i], kv, "=")
					if (kv[1] ~ /^CPU[0-9]+\/GPU$/) { split(kv[2], a, "/"); lv[a[2]] = 1; want = 1 }
					else if (kv[1] == "App") { sub("ms", "", kv[2]); app += kv[2] }
					else if (kv[1] == "GPU%") busy += kv[2]
					else if (kv[1] == "Stale") stale += kv[2]
				}
			}' "$log"
		;;
	-h|--help|"") usage ;;
	*) echo "quest: unknown command '$1'" >&2; usage 2 ;;
esac
