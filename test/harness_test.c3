<*
 The bounded headless run — `plan.md` §20.3's one flag — and the two helpers it
 needs.

	`c3c test --trust=full --test-noleak --test-filter three_tests::harness`

 **What is under test here is argument handling and path formatting, not the
 loop.** The loop itself is `JsRuntime.tick` called N times and drawn between,
 and `three_tests::frame` already states what a tick does; what could break
 silently is the decision of *how many* ticks a command line asks for, and the
 numbering of the files it writes. Both are pure functions of their input, and
 both fail invisibly: a `--frames` that resolved to one is a physics test that
 asserts about a frame that never stepped, and a `--every` that formatted every
 shot to the same name is a flipbook with one page in it.
*>
module three_tests::harness;
import three;
import std::core::test;

// `--screenshot` on its own has always meant one frame, and everything
// downstream reads `frames` rather than asking which mode it is in — so the
// place that "1" comes from has to be the parse.
fn void a_screenshot_is_one_frame_unless_told_otherwise() @test
{
	String[*] shot = { "three", "--screenshot", "out.png" };
	three::Options one = three::parse_args(shot[..])!!;
	test::@check(one.frames == 1, "a bare --screenshot is one frame, got %d", one.frames);
	test::@check(one.headless, "and needs no window");

	String[*] many = { "three", "--screenshot", "out.png", "--frames", "600" };
	three::Options run = three::parse_args(many[..])!!;
	test::@check(run.frames == 600, "--frames wins over the implied one, got %d", run.frames);
}

// A bounded run is a batch. A window that opened, played six hundred frames at
// whatever rate the compositor felt like, and closed is not something anybody
// asked to watch — and the point of counting frames is that the same count
// means the same thing on every machine.
fn void counting_frames_implies_headless() @test
{
	String[*] args = { "three", "--script", "level.js", "--frames", "120" };
	three::Options opts = three::parse_args(args[..])!!;
	test::@check(opts.headless, "--frames did not imply --headless");
	test::@check(opts.frames == 120);
	test::@check(opts.screenshot.len == 0, "and asked for no picture");
}

// A server that rendered one frame and exited would be no server at all, and
// one that played six hundred and exited is the same mistake with a longer
// fuse. Both are cleared by the parse rather than checked for later.
fn void a_server_is_never_a_bounded_run() @test
{
	String[*] args = { "three", "--mcp", "--frames", "300", "--screenshot", "out.png" };
	three::Options opts = three::parse_args(args[..])!!;
	test::@check(opts.frames == 0, "the server kept a frame count, %d", opts.frames);
	test::@check(opts.screenshot.len == 0, "and a screenshot path");
	test::@check(opts.mcp_port > 0, "but is still a server");
}

fn void the_camera_override_is_carried_verbatim() @test
{
	String[*] args = { "three", "--script", "a.js", "--camera", "45,30,80", "--every", "60" };
	three::Options opts = three::parse_args(args[..])!!;
	test::@check(opts.camera == "45,30,80", "got '%s'", opts.camera);
	test::@check(opts.every == 60);
}

<*
 A bare word on the command line is refused, and named in the refusal.

 **The regression this exists for is a model on screen that no script can
 reach.** `three model.glb` used to load and display a file, and the scene that
 put it there was one nothing had a handle to: nothing could add to it, nothing
 could dispose it, and — since `new three.Scene()` stopped emptying the one
 before it — it stayed live for the rest of the process. Loading is `three.load`
 inside a script, which is the version that hands the model back as an object.

 The third case is the other half: what is refused is the word, not the line it
 was on.

 Proved by injection: restore the `opts.model = arg` default case and both
 parses succeed, so `@catch` comes back false.
*>
fn void a_bare_word_is_not_a_file_to_load() @test
{
	String[*] alone = { "three", "model.glb" };
	three::Options? only = three::parse_args(alone[..]);
	test::@check(@catch(only), "a bare path was accepted");

	String[*] beside = { "three", "--script", "boot.js", "model.glb" };
	three::Options? trailing = three::parse_args(beside[..]);
	test::@check(@catch(trailing), "a bare path beside --script was accepted");

	String[*] flags = { "three", "--script", "boot.js", "--headless" };
	three::Options opts = three::parse_args(flags[..])!!;
	test::@check(opts.script == "boot.js" && opts.headless, "the flags stopped parsing");
}

// The numbering, which is what makes `--every` a flipbook rather than one file
// written N times. A path with no specifier is returned unchanged — that is the
// property that keeps a plain `--screenshot out.png` writing `out.png`.
fn void a_shot_path_numbers_itself_only_when_asked() @test
{
	test::@check(three::frame_path("out.png", 0) == "out.png", "no specifier, no number");
	test::@check(three::frame_path("out.png", 7) == "out.png", "still no number");

	test::@check(three::frame_path("shot-%03d.png", 0) == "shot-000.png");
	test::@check(three::frame_path("shot-%03d.png", 42) == "shot-042.png");
	// A width pads whether or not the zero was written: these are filenames, and
	// a run of more than nine frames should still sort.
	test::@check(three::frame_path("shot-%3d.png", 5) == "shot-005.png");
	test::@check(three::frame_path("shot-%d.png", 5) == "shot-5.png");
	// Wider than the width is not truncated — a filename that collided with an
	// earlier one would silently lose a frame.
	test::@check(three::frame_path("f%02d.png", 1234) == "f1234.png");
	// The directory part survives, which is the common shape of the flag.
	test::@check(three::frame_path("/tmp/run/%04d.png", 9) == "/tmp/run/0009.png");
}

<*
 `--assets` is a root before it is a boot.

 The regression: `--assets kit --script probe.js` opened by printing
 `kit/main.js did not run: MODULE_IS_NOT_A_FILE` and then ran the script
 perfectly well. A kit is a directory of models — `--assets` is what makes
 `three.load("buildings.glb")` inside it mean the kit's own file and stops it
 climbing out — and a kit that ships no entry module was never asked to have
 one. The rule is that a missing `main.js` is only a failure when nothing else
 was given to run.

 `test/fixtures` is the kit here: glTF and images, no `main.js`.
 `test/fixtures/game` is the game, and still boots with a script beside it —
 losing that would take `--assets ./game --script probe.js` with it, which is
 how a running game gets probed.
*>
fn void a_kit_with_no_main_js_is_a_root_and_not_a_failure() @test
{
	test::@check(three::wants_entry_module("test/fixtures/game", ""),
		"--assets alone boots main.js");
	test::@check(three::wants_entry_module("test/fixtures", ""),
		"and still asks for one that is missing, which is where the error comes from");

	test::@check(three::wants_entry_module("test/fixtures/game", "probe.js"),
		"a main.js that is there boots under --script too, and the script runs after it");
	test::@check(!three::wants_entry_module("test/fixtures", "probe.js"),
		"but a directory with none beside a --script is only an assets root");
}
