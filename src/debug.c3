<*
 The build's own diagnostics, and the one switch that removes them.

	c3c build --trust=full                    # ship it: nothing below is compiled in
	c3c build --trust=full -D DEBUG           # validation layers and debug logging

 ## What the switch removes

 Mostly one thing: the Khronos validation layer. It is not a driver flag or a
 few asserts but a second complete implementation of Vulkan inserted in front of
 the real one, tracking every object, handle and state transition so it can name
 the rule you broke. Everything else here is a print.

 `DEBUG_BUILD` gates the layer, the `VK_EXT_debug_utils` extension, the debug
 messenger carrying its output, the sink holding it, and the per-run capture
 that attributes it to a script. `validation_layer_present` in `gpu/device.c3`
 is the lock the rest hangs off.

 ## What it costs

 400 boxes, 400 distinct materials, 400 draw calls a frame, 100 frames timed
 inside the script after a warm one:

	-D DEBUG                      2.02 ms/frame
	-D DEBUG, layer not installed 0.97 ms/frame
	default build                 0.92 ms/frame
	default build, --safe=no -O3  0.63 ms/frame

 The layer is a little over 2x, and it scales with Vulkan calls rather than with
 pixels — the same bench at 24 draw calls a frame cannot tell the two apart. So
 it is worth most exactly where a game gets into trouble and worth nothing on a
 scene that is one instanced draw. The gap between the middle two rows is the
 machinery merely being present, and it is the width of the noise.

 ## Why there is no runtime flag

 A `-D DEBUG` build validates, always; a release build has no layer in it to
 run. There is no `--validate` — passing one is an unknown option and
 `parse_args` refuses it (`test/mcp_test.c3` pins that). A binary that can be
 *asked* to load the layer is one somebody eventually ships in that state, and
 the flag's meaning would depend on which build it was passed to.

 Getting a debug binary back to full speed is a rebuild rather than a flag.
 At 2x that is the right trade: anyone who cares about the 2x is measuring, and
 anyone measuring wants the fourth row, not the second.

 ## What the switch is *not*

 Not C3's own safety. Contracts, bounds checks and null checks are `--safe=no`,
 and the optimiser is `-O`; together they are worth about as much again as the
 layer:

	c3c build --trust=full --safe=no -O3      # the fast one

 They stay separate flags because they are a different risk: dropping the layer
 loses diagnostics, dropping contracts turns a caught mistake into undefined
 behaviour.

 Not the frame timer either. `gpu/timing.c3` costs two timestamp writes and a
 sixteen byte readback per frame, and `gpu_ms` is part of what `run_script`
 answers with — a profiling feature that reports itself, not a check.
*>
module three;

import std::io;

<*
 Whether this binary was built with `-D DEBUG`.

 A plain constant rather than a `$if` at every reading, so it can be branched on
 in ordinary code and asserted on in tests.
*>
const bool DEBUG_BUILD = $feat(DEBUG);

<*
 A log line that exists only in a debug build.

 The arguments are not evaluated without one, which makes this usable where
 composing the message costs more than printing it: `@debug_log("%s", describe())`
 does not call `describe` in a release build.

 That property is why the signature uses untyped varargs. A typed parameter list
 — `macro @debug_log(String format, args...)` — still evaluates everything at the
 call site even with the same `$if`'d body; only `$vaarg` inside the `$if`
 disappears with it.

 This is for the developer at the terminal, not the agent: anything a
 `run_script` should see belongs in `log`, which comes back through `RunResult`.
*>
macro @debug_log(format, ...)
{
	$if DEBUG_BUILD:
		io::printfn(format, ...$vaarg);
	$endif
}
