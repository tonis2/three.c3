#!/usr/bin/env bash
#
# Unified build, run, and tuning helper for PC (flat), Desktop PCVR (OpenXR),
# Quest preview on PC, and Android/Quest 3.
#
#     ./run.sh pc <game> [--fast] [--tune k=v ...] [-- <three args...>]
#     ./run.sh pcvr <game> [--fast] [--tune k=v ...] [-- <three args...>]
#     ./run.sh preview <game> [scale] [--fast] [--tune k=v ...] [-- <three args...>]
#     ./run.sh quest <game> [--build | --install | --run | --push]
#     ./run.sh quest-tune [k=v ... | reset]
#     ./run.sh quest-perf [seconds]
#     ./run.sh quest-bench [log]
#     ./run.sh quest-logs
#     ./run.sh quest-mcp [port]
#
# Examples:
#     ./run.sh pc examples/vr_castle.js --tune shadow_filter=1tap --tune prepass=0
#     ./run.sh pcvr examples/vr_castle.js --fast --tune msaa=4
#     ./run.sh preview examples/vr_castle.js 1.0 -- --debug
#     ./run.sh quest examples/vr_castle.js --push
#     ./run.sh quest-tune msaa=2 xr_scale=0.85 shadow_filter=1tap
#     ./run.sh quest-tune reset
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
THREE_BIN="$ROOT/build/three"

usage() {
	sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
	exit "${1:-0}"
}

resolve_entry() {
	local target="$1"
	if [[ -d "$target" ]]; then
		[[ -f "$target/main.js" ]] || { echo "run.sh: $target has no main.js" >&2; exit 1; }
		echo "$target/main.js"
	else
		[[ -f "$target" ]] || { echo "run.sh: script not found: $target" >&2; exit 1; }
		echo "$target"
	fi
}

build_desktop() {
	local fast="$1"
	if (( fast )); then
		(cd "$ROOT" && c3c build three --safe=no -O3)
	else
		(cd "$ROOT" && c3c build three)
	fi
}

run_desktop_mode() {
	local mode="$1"
	shift
	[[ $# -ge 1 ]] || usage 2
	local game="$1"
	shift
	local entry
	entry="$(resolve_entry "$game")"

	local fast=0
	local preview_scale=""
	local -a args=()

	if [[ "$mode" == "preview" && $# -ge 1 && "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		preview_scale="$1"
		shift
	fi

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--fast) fast=1; shift ;;
			--tune)
				[[ $# -ge 2 ]] || { echo "run.sh: --tune needs key=value" >&2; exit 2; }
				args+=(--tune "$2")
				shift 2
				;;
			--) shift; args+=("$@"); break ;;
			*) args+=("$1"); shift ;;
		esac
	done

	build_desktop "$fast"

	local -a mode_flags=()
	case "$mode" in
		pc) ;;
		pcvr) mode_flags=(--vr) ;;
		preview)
			if [[ -n "$preview_scale" ]]; then
				mode_flags=(--quest "$preview_scale")
			else
				mode_flags=(--quest)
			fi
			;;
	esac

	exec "$THREE_BIN" "${mode_flags[@]}" --script "$entry" "${args[@]}"
}

TUNE_KEYS=(profile msaa xr_scale xr_filter direct_eyes prepass shadow_filter foveation scene_cache frame_skip timestamps lazy_post pipeline_stats dynamic_res compute_skin)

quest_tune() {
	[[ $# -ge 1 ]] || usage 2
	if [[ "$1" == "reset" ]]; then
		for k in "${TUNE_KEYS[@]}"; do
			adb shell "setprop debug.three.$k ''"
		done
		echo "quest-tune: cleared all debug.three.* overrides"
		"$ROOT/packaging/android/quest.sh" restart
		return
	fi
	for spec in "$@"; do
		[[ "$spec" == *=* ]] || { echo "quest-tune: expected key=value, got '$spec'" >&2; exit 2; }
		local k="${spec%%=*}"
		local v="${spec#*=}"
		adb shell "setprop debug.three.$k '$v'"
		echo "quest-tune: debug.three.$k = $v"
	done
	"$ROOT/packaging/android/quest.sh" restart
}

case "${1:-}" in
	pc|pcvr|preview)
		mode="$1"; shift
		run_desktop_mode "$mode" "$@"
		;;
	quest)
		shift
		[[ $# -ge 1 ]] || usage 2
		game="$1"; shift
		qargs=()
		action="--run"
		while [[ $# -gt 0 ]]; do
			case "$1" in
				--push|--build|--install|--run) action="$1"; shift ;;
				--fast) qargs+=(--fast); shift ;;
				*) echo "run.sh: unknown quest action '$1' (expected --build, --install, --run, --push, or --fast)" >&2; exit 2 ;;
			esac
		done
		case "$action" in
			--push)    exec "$ROOT/packaging/android/quest.sh" push "$game" ;;
			--build)   exec "$ROOT/packaging/android/build-apk.sh" "$game" "${qargs[@]}" ;;
			--install) exec "$ROOT/packaging/android/build-apk.sh" "$game" --install "${qargs[@]}" ;;
			--run)     exec "$ROOT/packaging/android/build-apk.sh" "$game" --run "${qargs[@]}" ;;
		esac
		;;
	quest-tune)  shift; quest_tune "$@" ;;
	quest-perf)  shift; exec "$ROOT/packaging/android/quest.sh" perf "$@" ;;
	quest-bench) shift; exec "$ROOT/packaging/android/quest.sh" bench "$@" ;;
	quest-logs)  exec "$ROOT/packaging/android/quest.sh" logs ;;
	quest-mcp)   shift; exec "$ROOT/packaging/android/quest.sh" mcp "$@" ;;
	-h|--help|"") usage ;;
	*) echo "run.sh: unknown command '$1'" >&2; usage 2 ;;
esac
