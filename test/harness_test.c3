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
