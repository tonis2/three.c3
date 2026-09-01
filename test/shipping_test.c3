<*
 What a shipped game needs and a viewer does not — §22.

	`c3c test --trust=full --test-noleak --test-filter three_tests::shipping`

 Four things, and the reason they are one file is that they are one change: a
 binary a player runs rather than a developer. The cache stops following the
 launcher around, the window can be named, a game can declare itself, and it can
 write a save somewhere an update will not delete.

 ## The user's own directories are redirected, and that is load-bearing

 `user_state_dir` answers under `$HOME` — `~/Library/Application Support` here,
 `%AppData%` on Windows, `$XDG_CONFIG_HOME` elsewhere — and a test that let it
 would leave folders in the machine's real one. So `@with_home` points those
 variables at `build/test-home` for the length of a check and puts them back
 afterwards, restoring whatever was there rather than clearing it: a run under a
 shell with no `HOME` is not the same as a run under a shell that has one, and
 the tests after this file must see what they saw before it.
*>
module three_tests::shipping;

import three;
import vk;
import std::core::test;
import std::io::path;
import std::os::env;

// Under `build/`, which is gitignored, so a failed run leaves nothing that
// becomes a diff and `rm -rf build` is the whole of the cleanup.
const String TEST_HOME = "build/test-home";
// The two XDG roots, under it. Written out rather than composed, because a
// const here is what the macro below assigns without allocating.
const String TEST_CONFIG_HOME = "build/test-home/.config";
const String TEST_CACHE_HOME = "build/test-home/.cache";

<*
 Runs the body with every "where does user data go" variable pointing at
 `TEST_HOME`, and the directory itself gone before and after.

 The variables differ by platform because `paths.c3` reads different ones:
 `AppData` on Windows, and `HOME` plus `XDG_CONFIG_HOME` everywhere else —
 both, because a Linux session usually sets the second and it wins.
*>
macro @with_home(; @body)
{
	String[3] names;
	String[3] values = { TEST_HOME, TEST_HOME, TEST_HOME };
	usz name_count;
	$if env::WIN32:
		names[0] = "AppData";
		name_count = 1;
	$else
		names[0] = "HOME";
		names[1] = "XDG_CONFIG_HOME";
		names[2] = "XDG_CACHE_HOME";
		name_count = 3;
		// The two XDG roots have to differ, or `saves_and_shaders_do_not_share_a_root`
		// is asking a question the environment already answered: pointing both at
		// one directory *is* one directory, whatever `paths.c3` does. They stay
		// under TEST_HOME, which is what the rmtree and the cache-root check want.
		values[1] = TEST_CONFIG_HOME;
		values[2] = TEST_CACHE_HOME;
	$endif

	String[3] saved;
	bool[3] had;
	for (usz i = 0; i < name_count; i++)
	{
		String? was = env::get_var(mem, names[i]);
		if (try was)
		{
			saved[i] = was;
			had[i] = true;
		}
		env::set_var(names[i], values[i]);
	}

	defer
	{
		for (usz i = 0; i < name_count; i++)
		{
			if (had[i])
			{
				env::set_var(names[i], saved[i]);
				saved[i].free(mem);
			}
			else
			{
				env::clear_var(names[i]);
			}
		}
		(void)path::rmtree((Path)TEST_HOME);
	}

	(void)path::rmtree((Path)TEST_HOME);
	@body();
}

<*
 A runtime with no device behind it, which is everything but the resize checks.

 The same construction `reload_test.c3` uses: saving, `three.configure` and the
 window verbs are all about state that has nothing to do with a GPU, and asking
 for one would make this file need a machine that has one.
*>
macro @with_js(; @body(three::JsRuntime* run))
{
	three::MeshPass pass;
	pass.assets.init();
	pass.init_scenes();
	pass.camera = three::default_camera();
	defer pass.free_scenes();
	defer pass.assets.free(null);

	three::JsRuntime runtime;
	runtime.open(&pass)!!;
	defer runtime.close();

	@body(&runtime);
}

macro @with_gpu_js(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 200, 150)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&runtime, &renderer);
}

macro String @answer(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the reading script succeeded: %s", result.error);
	return result.value.copy(tmem);
}

macro @ok(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the setup script succeeded: %s", result.error);
}

// ============================================================================
// Where the cache goes
// ============================================================================

<*
 The flag wins, and is not interpreted.

 A path with no `build/` in it and no relation to any user directory comes back
 exactly as written: a developer pointing the cache at a scratch disk is doing
 so on purpose, and a resolver that improved on the answer would be unusable for
 the one job the flag has.
*>
fn void the_flag_is_the_answer_when_there_is_one() @test
{
	String chosen = three::resolve_cache_dir("/tmp/three-cache-somewhere", tmem);
	test::@check(chosen == "/tmp/three-cache-somewhere",
		"--cache-dir was not taken as written: %s", chosen);
}

<*
 A checkout keeps what it always had.

 This is the clause that makes the change safe: the suite, `c3c run` and a shell
 at the project root all start where a `build/` exists, so every one of them
 resolves to the directory they have been sharing since the cache was written.
 A test binary is itself started from the project root, so the check is the
 situation rather than a simulation of it.
*>
fn void a_checkout_stays_on_its_build_directory() @test
{
	// The environment is read before `build/` is looked at, and a machine that
	// happens to have this set would otherwise fail a check about something else.
	String? had = env::get_var(mem, "THREE_CACHE_DIR");
	defer if (try had)
	{
		env::set_var("THREE_CACHE_DIR", had);
		had.free(mem);
	}
	env::clear_var("THREE_CACHE_DIR");

	test::@check(path::is_dir((Path)"build"),
		"this check reads the working directory, and it is not a checkout's root");

	String chosen = three::resolve_cache_dir("", tmem);
	test::@check(chosen == three::SHADER_CACHE_DEFAULT_DIR,
		"a checkout was moved off build/shader-cache, onto %s", chosen);
}

<*
 The environment is read when the flag says nothing, and outranks `build/`.

 Above the checkout clause deliberately: a CI job that sets this has said where
 it wants the cache, and it is usually running in a tree that has a `build/`.
*>
fn void the_environment_names_it_when_the_flag_does_not() @test
{
	String? had = env::get_var(mem, "THREE_CACHE_DIR");
	defer
	{
		if (try had)
		{
			env::set_var("THREE_CACHE_DIR", had);
			had.free(mem);
		}
		else
		{
			env::clear_var("THREE_CACHE_DIR");
		}
	}

	env::set_var("THREE_CACHE_DIR", "/tmp/three-cache-from-env");
	String chosen = three::resolve_cache_dir("", tmem);
	test::@check(chosen == "/tmp/three-cache-from-env",
		"THREE_CACHE_DIR was ignored: %s", chosen);

	// And the flag still beats it, which is the order a person expects from a
	// command line they typed against an environment they inherited.
	String flagged = three::resolve_cache_dir("/tmp/three-cache-from-flag", tmem);
	test::@check(flagged == "/tmp/three-cache-from-flag",
		"the environment beat the flag: %s", flagged);
}

<*
 With no checkout to fall into, the answer is under the user's cache root.

 The one case a shipped game is actually in, reached here by pointing the cache
 variables somewhere else rather than by deleting `build/`. What matters is that
 it is *under a user directory* and named for this engine — the exact platform
 root is `paths.c3`'s business and differs on all three.
*>
fn void a_bundle_lands_in_the_users_cache_directory() @test
{
	@with_home()
	{
		String user = three::user_cache_dir(tmem) ?? "";
		test::@check(user.len > 0, "there was no user cache directory under a home that exists");
		test::@check(user.contains(TEST_HOME), "the cache root ignored the home it was given: %s", user);
		test::@check(user.contains("three.c3"), "the cache root is not named for this engine: %s", user);
	};
}

<*
 The state directory is not the cache directory.

 Two roots on every platform, and the reason is what a disk cleaner is allowed
 to do: emptying a cache costs a recompile, and emptying a save costs a
 playthrough. A change that collapsed them would pass every other check here.
*>
fn void saves_and_shaders_do_not_share_a_root() @test
{
	@with_home()
	{
		String cache = three::user_cache_dir(tmem) ?? "";
		String state = three::user_state_dir(tmem) ?? "";
		test::@check(cache.len > 0 && state.len > 0, "one of the two user directories has no answer");
		test::@check(cache != state,
			"saves and compiled shaders were given the same directory: %s", cache);
	};
}

// ============================================================================
// The flag
// ============================================================================

<*
 `--cache-dir ""` is a decision and `--cache-dir` absent is not.

 The two fields exist for this one distinction. An empty value turns the cache
 off, so a resolver that could not tell it from silence would leave the off
 switch unreachable — and "off" is what a benchmark of cold compiles needs.
*>
fn void an_empty_cache_dir_is_told_from_an_absent_one() @test
{
	String[*] silent = { "three", "--headless" };
	three::Options quiet = three::parse_args(silent[..])!!;
	test::@check(!quiet.cache_dir_set, "a line that never said --cache-dir set one");

	String[*] emptied = { "three", "--cache-dir", "", "--headless" };
	three::Options off = three::parse_args(emptied[..])!!;
	test::@check(off.cache_dir_set, "--cache-dir '' did not register as having been given");
	test::@check(off.cache_dir.len == 0, "--cache-dir '' came back with something in it");
	test::@check(off.headless, "--cache-dir swallowed the flag beside it");

	String[*] named = { "three", "--cache-dir", "/tmp/somewhere" };
	three::Options set = three::parse_args(named[..])!!;
	test::@check(set.cache_dir == "/tmp/somewhere", "--cache-dir lost its value: %s", set.cache_dir);
}

// ============================================================================
// What may be a save's name
// ============================================================================

<*
 The allowlist, from both sides.

 Escapes are the point, and the two that matter are the two a path resolver
 would have had to think about: `..` and a separator. Neither is refused by
 name here — they are refused for not being in the set — which is why the
 refusals below include the ones nobody would have written a rule for.
*>
fn void a_save_name_is_a_name_and_not_a_path() @test
{
	String[*] fine = { "slot1", "auto-save", "settings.json", "A_1", "x" };
	foreach (name : fine)
	{
		test::@check(three::valid_slot(name), "'%s' should be a usable save name", name);
	}

	String[*] refused = {
		"",             // nothing to open
		"..",           // the escape, refused for not being in the set
		".",            // the directory itself
		".hidden",      // a file a person would not find in a file manager
		"a/b",          // posix separator
		"a\\b",         // windows separator
		"/etc/passwd",  // absolute, and both of the above
		"C:name",       // a drive letter
		"a b",          // a space is not in the set
		"na\tme",       // nor is a tab
	};
	foreach (name : refused)
	{
		test::@check(!three::valid_slot(name), "'%s' should not be a usable save name", name);
	}

	// The length rule, from either side of the line.
	char[65] long_name;
	for (usz i = 0; i < 65; i++) long_name[i] = 'a';
	test::@check(three::valid_slot(((String)long_name[..])[:64]), "64 characters should be allowed");
	test::@check(!three::valid_slot((String)long_name[..]), "65 characters should not be");
}

// ============================================================================
// Saving
// ============================================================================

<*
 A save goes out and comes back, and the folder is where it was said to be.

 The round trip is three shapes rather than one because they are three
 different paths through the binding: JSON through the prelude's stringify, a
 string straight through, and bytes through the size-then-fill pair that exists
 because the engine's ArrayBuffer constructor does not copy.
*>
fn void what_a_game_saves_comes_back() @test
{
	@with_home()
	{
		@with_js(; three::JsRuntime* run)
		{
			String where = @answer(run, `return three.configure({ saveDir: 'a-game' }).saveDir;`);
			test::@check(where.contains("a-game"), "the save folder was not named: %s", where);
			test::@check(where.contains(TEST_HOME), "the save folder ignored the home it was given: %s", where);

			@ok(run, `three.save.write('slot1', { level: 3, hp: 80 });`);
			test::@check(@answer(run, `return three.save.read('slot1').level;`) == "3",
				"a JSON save did not come back");

			@ok(run, `three.save.writeText('notes', 'hello');`);
			test::@check(@answer(run, `return three.save.readText('notes');`) == `"hello"`,
				"a text save did not come back");

			@ok(run, `three.save.writeBytes('blob', new Uint8Array([1, 2, 250]));`);
			test::@check(@answer(run, `return Array.from(three.save.readBytes('blob')).join(',');`) == `"1,2,250"`,
				"a byte save did not come back");
		};
	};
}

<*
 Nothing there is null, not a throw.

 The first run of every game there has ever been. A game that had to wrap its
 own cold start in a `try` would be paying for the one case that is guaranteed
 to happen.
*>
fn void reading_a_save_that_is_not_there_answers_null() @test
{
	@with_home()
	{
		@with_js(; three::JsRuntime* run)
		{
			@ok(run, `three.configure({ saveDir: 'empty-game' });`);
			test::@check(@answer(run, `return three.save.read('never-written');`) == "null",
				"a missing save was not null");
			test::@check(@answer(run, `return three.save.readText('never-written');`) == "null",
				"a missing text save was not null");
			test::@check(@answer(run, `return three.save.readBytes('never-written');`) == "null",
				"a missing byte save was not null");
			test::@check(@answer(run, `return three.save.list().length;`) == "0",
				"an empty save folder listed something");
			test::@check(@answer(run, `return three.save.remove('never-written');`) == "false",
				"removing what was never there did not answer false");
		};
	};
}

<*
 List and remove agree with what was written.

 `list` is filtered by the same rule the writers are, so whatever else ends up
 in that directory it answers with names it would accept back — which is what a
 load menu is going to hand straight to `read`.
*>
fn void the_folder_lists_what_is_in_it() @test
{
	@with_home()
	{
		@with_js(; three::JsRuntime* run)
		{
			@ok(run, `three.configure({ saveDir: 'listing-game' });
				three.save.write('a', 1);
				three.save.write('b', 2);`);

			test::@check(@answer(run, `return three.save.list().sort().join(',');`) == `"a,b"`,
				"the folder did not list both saves");
			test::@check(@answer(run, `return three.save.remove('a');`) == "true", "the save was not removed");
			test::@check(@answer(run, `return three.save.list().join(',');`) == `"b"`,
				"the removed save is still listed");
		};
	};
}

<*
 A name that could leave the folder is refused before anything opens.

 The whole reason this file's sandbox may widen at all. Each of these is a
 throw, not a false: a game asking to write outside its folder has a bug, and
 answering "no" quietly would let it ship.
*>
fn void a_save_cannot_be_written_outside_its_folder() @test
{
	@with_home()
	{
		@with_js(; three::JsRuntime* run)
		{
			@ok(run, `three.configure({ saveDir: 'walled-game' });`);

			String[*] attempts = {
				`three.save.write('../escape', 1);`,
				`three.save.write('a/b', 1);`,
				`three.save.write('/tmp/escape', 1);`,
				`three.save.readText('../../etc/passwd');`,
				`three.save.remove('..');`,
			};
			foreach (attempt : attempts)
			{
				three::RunResult result = run.run(attempt);
				defer result.free();
				test::@check(!result.ok, "'%s' was allowed", attempt);
			}
		};
	};
}

<*
 With nothing to name a folder after, every verb says which call fixes it.

 A `--script` or `--mcp` run has no assets directory, so there is no name to
 derive and inventing one would put a player's saves somewhere they would never
 find twice. `list` is the exception and answers empty, because it is what a
 load menu calls before anything exists.
*>
fn void a_run_with_no_folder_says_so_rather_than_guessing() @test
{
	@with_home()
	{
		@with_js(; three::JsRuntime* run)
		{
			test::@check(@answer(run, `return three.save.path;`) == "null",
				"a run that named no folder reported one");
			test::@check(@answer(run, `return three.save.list().length;`) == "0",
				"listing with no folder was not empty");

			three::RunResult result = run.run(`three.save.write('slot1', 1);`);
			defer result.free();
			test::@check(!result.ok, "writing with no folder was allowed");
			test::@check(result.error.contains("three.configure"),
				"the refusal did not name the call that fixes it: %s", result.error);
		};
	};
}

// ============================================================================
// What a game declares about itself
// ============================================================================

<*
 `configure` answers with what stands after it, and leaves out what it was not
 given.

 The return value is there so a boot log can print one line and be right. Every
 key being optional is what lets a game name itself without also taking a
 position on fullscreen.
*>
fn void configure_sets_what_it_is_given_and_nothing_else() @test
{
	@with_home()
	{
		@with_js(; three::JsRuntime* run)
		{
			test::@check(@answer(run, `return three.configure({ title: 'Wumpa Run' }).title;`) == `"Wumpa Run"`,
				"the title was not taken");
			test::@check(@answer(run, `return three.window.title;`) == `"Wumpa Run"`,
				"the title did not read back off the window");

			// A second call that says nothing about the title must not clear it.
			test::@check(@answer(run, `return three.configure({}).title;`) == `"Wumpa Run"`,
				"an empty configure reset the title");

			test::@check(@answer(run, `three.window.title = 'Level 3'; return three.window.title;`) == `"Level 3"`,
				"the live property did not take");

			three::RunResult bad = run.run(`three.configure(7);`);
			defer bad.free();
			test::@check(!bad.ok, "configure took something that was not an object");
		};
	};
}

<*
 Under `--headless` there is no window, and the verbs say so without failing.

 A game that names itself has to start where there is no title bar — a
 screenshot batch, a test, an agent's server — and the shape is the one
 `three.window.resize` and `three.input.pointerLock` already use: the state is
 kept, the answer is false, nothing throws.
*>
fn void the_window_verbs_work_where_there_is_no_window() @test
{
	@with_home()
	{
		@with_js(; three::JsRuntime* run)
		{
			test::@check(@answer(run, `return three.window.fullscreen;`) == "false",
				"a run with no window reported itself fullscreen");
			@ok(run, `three.window.fullscreen = true;`);
			test::@check(@answer(run, `return three.window.fullscreen;`) == "false",
				"a window that does not exist went fullscreen");

			// The title is still remembered, because a game reading back what it
			// configured should get what it configured wherever it is running.
			@ok(run, `three.configure({ title: 'Headless Game' });`);
			test::@check(@answer(run, `return three.window.title;`) == `"Headless Game"`,
				"the title was not kept without a window");

			three::RunResult empty = run.run(`three.window.title = '';`);
			defer empty.free();
			test::@check(!empty.ok, "an empty title was accepted");
		};
	};
}

// ============================================================================
// The render size
// ============================================================================

<*
 A resize from outside a frame happens on the call.

 What a booting script and an agent's tool call both want: the very next
 screenshot is the new size, rather than one taken a frame before the change
 landed.
*>
fn void a_resize_outside_a_frame_is_immediate() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		test::@check(@answer(run, `return three.setRenderSize(320, 240);`) == "true",
			"a resize outside a frame reported itself as queued");
		test::@check(renderer.target.extent.width == 320 && renderer.target.extent.height == 240,
			"the target is %dx%d", renderer.target.extent.width, renderer.target.extent.height);
		test::@check(@answer(run, `return three.renderSize().width;`) == "320",
			"renderSize did not follow the target");
	};
}

<*
 A resize from inside a frame waits for the loop.

 The images a resize frees are the ones the frame that asked for it is drawing
 into, so the request is held and the host performs it between frames — the same
 deferral `three.reload()` and `three.quit()` use, and here the flag is set by
 hand because a real frame would need a loop around it.
*>
fn void a_resize_inside_a_frame_waits_for_the_loop() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		uint was_wide = renderer.target.extent.width;

		run.in_frame = true;
		test::@check(@answer(run, `return three.setRenderSize(320, 240);`) == "false",
			"a resize inside a frame reported itself as done");
		run.in_frame = false;

		test::@check(renderer.target.extent.width == was_wide,
			"the target moved while a frame was on the stack");

		test::@check(run.take_render_resize(), "nothing was pending");
		test::@check(renderer.target.extent.width == 320 && renderer.target.extent.height == 240,
			"the loop did not perform the resize: %dx%d",
			renderer.target.extent.width,
			renderer.target.extent.height);

		test::@check(!run.take_render_resize(), "the resize was still pending after being performed");
	};
}

<*
 Setting a size pins it; passing null gives the window back.

 The default is that the picture follows the window — a resize, a fullscreen
 transition, a move between displays — and the only reason to set a size is to
 stop it doing that, which is the render-scale slider. So the pin is not a
 separate switch: it is what setting a size MEANS, and the check is that the
 flag moves with the call rather than needing one of its own.

 Headless here, where there is no window to follow, because the flag is the
 whole of what is under test: `follow_window` is the same call on either path
 and a windowed run of it is `resize_test.c3`'s job.
*>
fn void setting_a_render_size_pins_it_and_null_gives_it_back() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		test::@check(!renderer.render_size_pinned, "a fresh renderer was already pinned");

		@ok(run, `three.setRenderSize(320, 240);`);
		test::@check(renderer.render_size_pinned, "setting a size did not pin it");

		test::@check(@answer(run, `return three.setRenderSize(null);`) == "true",
			"unpinning did not report itself done");
		test::@check(!renderer.render_size_pinned, "null did not give the window back");
	};
}

<*
 Unpinning drops a resize that had been queued.

 Otherwise the sequence "ask for 320x240 from inside a frame, change your mind
 before the frame ends" would apply the size a frame later and pin nothing —
 a resolution the game no longer wants, arriving after it said so.
*>
fn void giving_the_window_back_cancels_a_queued_resize() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		uint was_wide = renderer.target.extent.width;

		run.in_frame = true;
		@ok(run, `three.setRenderSize(320, 240);`);
		@ok(run, `three.setRenderSize(null);`);
		run.in_frame = false;

		test::@check(!run.take_render_resize(), "a cancelled resize was still pending");
		test::@check(renderer.target.extent.width == was_wide,
			"the cancelled resize happened anyway: %d", renderer.target.extent.width);
	};
}

<*
 A size nothing could allocate is refused, and the old target survives it.

 The failure that must not take the renderer with it: the new images are built
 before the old ones are freed, so a device that says no leaves the run drawing
 exactly what it was drawing.
*>
fn void a_refused_size_leaves_the_target_alone() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		uint was_wide = renderer.target.extent.width;
		uint was_high = renderer.target.extent.height;

		three::RunResult result = run.run(`three.setRenderSize(0, 100);`);
		defer result.free();
		test::@check(!result.ok, "a zero-wide target was accepted");

		test::@check(renderer.target.extent.width == was_wide && renderer.target.extent.height == was_high,
			"a refused resize moved the target anyway");
	};
}
