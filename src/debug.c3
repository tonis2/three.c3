<*
 The build's own diagnostics, and the one switch that removes them.

	c3c build --trust=full                    # ship it: nothing below is compiled in
	c3c build --trust=full -D DEBUG           # validation layers and debug logging

 ## What the switch is actually removing

 One thing, mostly: the Khronos validation layer. It is not a flag the driver
 reads and it is not a few asserts — it is a second, complete implementation of
 Vulkan inserted in front of the real one, tracking every object, every handle
 and every state transition so that it can name the rule you broke. Everything
 else here is a print.

 So `DEBUG_BUILD` gates the layer, the `VK_EXT_debug_utils` extension, the debug
 messenger that carries its output, the sink that holds it and the per-run
 capture that attributes it to a script. `validation_layer_present` is the one
 lock the rest hangs off — see its note in `gpu/device.c3`.

 ## What it measured, so the claim is not a guess

 400 boxes, 400 distinct materials, 400 draw calls a frame, 100 frames timed
 inside the script after a warm one, on the machine this was written on:

	-D DEBUG, --validate         2.02 ms/frame
	-D DEBUG, validation off     0.97 ms/frame
	default build                0.92 ms/frame
	default build, --safe=no -O3 0.63 ms/frame

 **The layer is a little over 2x, and it scales with Vulkan calls rather than
 with pixels** — the same bench at 24 draw calls a frame could not tell the two
 apart at all. So the flag is worth most exactly where a game gets into trouble,
 and worth nothing on a scene that is one instanced draw. The gap between the
 middle two rows is the machinery that is merely *present*, and it is the width
 of the noise: compiling it out buys nothing on its own, which is the honest
 reason this switch exists at build time rather than as a smaller runtime one.

 ## Why it is a compile-time switch when `--validate` already exists

 Because they answer different questions. `--validate` is "do I want the layer
 running *this time*", and it stays: a debug build still starts without it
 unless asked. `-D DEBUG` is "does this binary contain the diagnostic machinery
 at all", which is the question a shipped build wants to have answered no — a
 runtime flag can still be passed, and a binary that can still be asked to load
 the layer is a binary somebody will accidentally ship in that state.

 The visible consequence, and it is worth knowing before it surprises somebody:
 **`--mcp` no longer implies validation in a release build.** It implies it in a
 debug one, because `plan.md` §4 wants the layer running whenever a script is
 and a `run_script` answer is a third empty without it. In a release build there
 is nothing to imply, so the implication is dropped silently rather than
 refused — nobody asked for it. An explicit `--validate` *is* refused, out loud,
 by `create_instance`: a flag that silently did nothing would be worse than one
 that is not there.

 ## What this switch is not

 **It is not C3's own safety.** `@require` contracts, bounds checks and null
 checks are `--safe=no`, and the optimiser is `-O`. Together they are worth
 about as much again as the layer — the fourth row above — and neither is
 spelled `-D`:

	c3c build --trust=full --safe=no -O3      # the fast one

 Left as separate flags rather than folded into this one, because they are a
 different decision with a different risk: dropping the layer loses diagnostics,
 dropping the contracts turns a caught mistake into undefined behaviour. A
 single flag that did both would make that second choice on somebody's behalf.

 **It is not the frame timer.** `gpu/timing.c3` costs two timestamp writes and a
 sixteen byte readback per frame, and `gpu_ms` is part of what `run_script`
 answers with — a profiling feature that reports itself, not a check. Compiling
 it out would take a number away from every agent to save a rounding error.
*>
module three;

import std::io;

<*
 Whether this binary was built with `-D DEBUG`.

 A plain constant rather than a `$if` at every reading, so it can be branched on
 in ordinary code and asserted on in tests — `test/mcp_test.c3` pins the
 relationship between this and what `--mcp` implies, which is the one place the
 switch is visible from outside.
*>
const bool DEBUG_BUILD = $feat(DEBUG);

<*
 A line that exists only in a debug build.

 **The arguments are not evaluated without one**, which is what makes this
 usable on a path where composing the message costs more than printing it:
 `@debug_log("%s", describe())` does not call `describe` in a release build.

 That property is the reason for the signature. An ordinary typed parameter list
 does *not* give it — `macro @debug_log(String format, args...)` with the same
 `$if`'d body still evaluates everything at the call site, which was measured
 rather than assumed: a probe with a `printn` in it fired in both builds. Only
 untyped varargs reached through `$vaarg` inside the `$if` disappear with it.

 Written for the developer at the terminal and not for the agent: what a script
 needs to know comes back through `RunResult`, which is a different channel with
 a different lifetime. Anything a `run_script` should see belongs in `log`, not
 here.
*>
macro @debug_log(format, ...)
{
	$if DEBUG_BUILD:
		io::printfn(format, ...$vaarg);
	$endif
}
