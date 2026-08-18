<*
 The keyboard: the table, the edges, and what a handler is allowed to do.

	`c3c test --trust=full --test-noleak --test-filter three_tests::input`

 **No window.** `InputTracker.step` takes what is held and answers with what
 changed, so every check below says what the keyboard did rather than what the
 machine happened to be doing — which is the same seam `controls_test.c3` uses
 and it is here for the same reason.

 The first half is the table and the difference; the second is what a script can
 see of them. They are worth separating: a wrong edge and a wrong binding fail
 identically from JavaScript, and only one of them is a bug in the diff.
*>
module three_tests::input;

import three;
import c3w;
import qjs;
import vk;
import std::core::test;
import std::io;

macro @with_js(; @body(three::JsRuntime* run, three::MeshPass* pass))
{
	three::MeshPass pass;
	pass.scene.init();
	pass.assets.init();
	pass.camera = three::default_camera();
	defer pass.scene.free();
	defer pass.assets.free(null);

	three::JsRuntime runtime;
	runtime.open(&pass)!!;
	defer runtime.close();

	@body(&runtime, &pass);
}

<*
 A runtime with a headless device, for the one check that needs a raycast to
 answer with something.

 `js_test.c3` has the same macro for the same reason: headless here means no
 window, not no GPU, and the whole point of the check below is that a pixel in
 the window becomes a pixel in the *image* and then an object.
*>
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

macro @ok(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the setup script succeeded: %s", result.error);
}

macro String @answer(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the reading script succeeded: %s", result.error);
	return result.value.copy(mem);
}

// One frame of keyboard: these names held, this text typed.
fn three::InputState frame(three::InputTracker* tracker, String[] held, String text = "")
{
	three::KeyBits bits;
	foreach (String name : held)
	{
		test::@check(bits.add(name), "the fixture names a real key: '%s'", name);
	}
	return tracker.step(bits, text);
}

// ============================================================================
// The table
// ============================================================================

<*
 Every name resolves, and to the key it says.

 A table this long is written by hand once and read by everything afterwards. A
 row whose name is misspelled is a key that cannot be bound, and nothing else in
 the suite would ever mention it.
*>
fn void every_name_in_the_table_resolves() @test
{
	foreach (three::KeyName row : three::KEY_NAMES)
	{
		three::KeyName? found = three::find_key(row.name);
		if (catch err = found)
		{
			test::@check(false, "'%s' is in the table and cannot be found", row.name);
			continue;
		}
		test::@check(found.key == row.key, "'%s' resolves to its own key", row.name);
	}
}

<*
 No name appears twice.

 A duplicate is invisible: `find_key` takes the first, the second is dead, and
 the only symptom is a key that binds to something else. One was introduced by a
 careless reflow of this very table while it was being written, which is why
 there is a check rather than a careful reading.
*>
fn void no_two_names_are_the_same() @test
{
	usz count = three::KEY_NAMES.len;
	for (usz i = 0; i < count; i++)
	{
		for (usz j = i + 1; j < count; j++)
		{
			test::@check(
				three::KEY_NAMES[i].name != three::KEY_NAMES[j].name,
				"'%s' appears twice, at %d and %d",
				three::KEY_NAMES[i].name, i, j
			);
		}
	}
}

fn void names_are_case_insensitive() @test
{
	three::KeyName? upper = three::find_key("W");
	three::KeyName? mixed = three::find_key("Space");
	if (catch err = upper) { test::@check(false, "'W' is 'w'"); return; }
	if (catch err = mixed) { test::@check(false, "'Space' is 'space'"); return; }
	test::@check(upper.key == c3w::EventKey.W, "'W' is the w key");
	test::@check(mixed.key == c3w::EventKey.SPACE, "'Space' is the space bar");
}

<*
 A name nobody has is a fault, not a key that is never down.

 The whole argument for throwing is here: the two are indistinguishable from
 JavaScript, and one of them is a typo the script will never find.
*>
fn void an_unknown_name_is_a_fault() @test
{
	three::KeyName? missing = three::find_key("banana");
	if (try row = missing) test::@check(false, "there is no banana key, but one was found");

	// A name that starts with a real one is not that key. Names are compared
	// whole; matching a prefix would make `three.onKeyDown('spacebar', ...)`
	// bind the space bar, which is right by luck and wrong in general.
	three::KeyName? longer = three::find_key("spacex");
	if (try row = longer) test::@check(false, "'spacex' is not the space bar");

	test::@check(true, "neither name is a key");
}

<*
 The mouse is deliberately not in this table.

 `c3w` carries the buttons in the same latch and naming them would be two rows.
 They are absent because AppKit swallows the mouse-up that ends a title-bar drag
 — `controls.c3` documents it — so a script polling one would be told the button
 is held for the rest of the session. `Controls` has a release gate for that and
 a script would have nothing.
*>
fn void the_table_has_no_mouse_buttons() @test
{
	foreach (three::KeyName row : three::KEY_NAMES)
	{
		bool mouse = row.key == c3w::EventKey.LEFT_MOUSE
			|| row.key == c3w::EventKey.RIGHT_MOUSE
			|| row.key == c3w::EventKey.MIDDLE_MOUSE;
		test::@check(!mouse, "'%s' is a mouse button and should not be nameable", row.name);
	}
}

// ============================================================================
// The difference between two frames
// ============================================================================

<*
 Holding a key is not pressing it again.

 This is the entire reason there are two questions rather than one. A jump bound
 to the level state fires every frame the space bar is down, which is sixty
 jumps a second and reads as the game being broken rather than as the binding
 being wrong.
*>
fn void a_held_key_is_pressed_once() @test
{
	three::InputTracker tracker;

	three::InputState first = frame(&tracker, { "space" });
	three::KeyName space = three::find_key("space")!!;

	test::@check(first.is_down(space), "it is down on the first frame");
	test::@check(first.went_down(space), "and that frame is the edge");

	three::InputState second = frame(&tracker, { "space" });
	test::@check(second.is_down(space), "it is still down");
	test::@check(!second.went_down(space), "and the edge does not repeat");
}

fn void letting_go_is_an_edge_too() @test
{
	three::InputTracker tracker;
	three::KeyName w = three::find_key("w")!!;

	frame(&tracker, { "w" });
	three::InputState let_go = frame(&tracker, {});

	test::@check(!let_go.is_down(w), "it is no longer held");
	test::@check(let_go.went_up(w), "and the release is the edge");
	test::@check(!let_go.went_down(w), "which is not the press");

	three::InputState after = frame(&tracker, {});
	test::@check(!after.went_up(w), "and it does not repeat either");
}

<*
 `'shift'` means either shift, and the sided names mean one.

 The browser reports both as `Shift` and an agent will write that; a script that
 genuinely cares which hand is on the key can say so.
*>
fn void shift_means_either_shift() @test
{
	three::InputTracker tracker;
	three::InputState state = frame(&tracker, { "shiftright" });

	test::@check(state.is_down(three::find_key("shift")!!), "either shift is down");
	test::@check(state.is_down(three::find_key("shiftright")!!), "the right one specifically");
	test::@check(!state.is_down(three::find_key("shiftleft")!!), "and not the left one");
}

fn void keys_are_independent() @test
{
	three::InputTracker tracker;
	three::InputState state = frame(&tracker, { "w", "a" });

	test::@check(state.is_down(three::find_key("w")!!), "w is down");
	test::@check(state.is_down(three::find_key("a")!!), "a is down");
	test::@check(!state.is_down(three::find_key("s")!!), "s is not");
	test::@check(!state.is_down(three::find_key("d")!!), "nor is d");
}

// ============================================================================
// What a script can see
// ============================================================================

fn void a_script_can_ask_what_is_held() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "w" }));

		String answer = @answer(run, `return [three.input.isDown('w'), three.input.isDown('s')];`);
		defer answer.free(mem);
		test::@check(answer == "[true,false]", "w is held and s is not, got '%s'", answer);
	};
}

<*
 An edge lasts exactly one frame from JavaScript too.

 Asserted through the binding as well as through the tracker, because the two
 could disagree: the runtime keeps its own copy of the frame's input, and a copy
 taken at the wrong moment would report the previous frame's edges forever.
*>
fn void an_edge_lasts_exactly_one_frame_from_a_script() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::InputTracker tracker;

		run.tick(0, frame(&tracker, { "space" }));
		String first = @answer(run, `return three.input.pressed('space');`);
		defer first.free(mem);
		test::@check(first == "true", "the press is visible, got '%s'", first);

		run.tick(16, frame(&tracker, { "space" }));
		String second = @answer(run, `return [three.input.pressed('space'), three.input.isDown('space')];`);
		defer second.free(mem);
		test::@check(second == "[false,true]", "held, not pressed again, got '%s'", second);
	};
}

fn void the_typed_text_reaches_the_script() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "h" }, "hé"));

		String typed = @answer(run, "return three.input.text;");
		defer typed.free(mem);
		test::@check(typed == `"hé"`, "the text came through as typed, got %s", typed);

		run.tick(16, frame(&tracker, {}));
		String empty = @answer(run, "return three.input.text;");
		defer empty.free(mem);
		test::@check(empty == `""`, "and a frame with no typing is empty, got %s", empty);
	};
}

<*
 The text is copied, not borrowed.

 `Window.get_text` hands back a view into a buffer the window clears on its very
 next `getEvent` — so a borrowed string would answer with whatever has been typed
 since, and the same question would have a different answer depending on when it
 was asked. The buffer below is rewritten between the tick and the read for
 exactly that reason: it is what the window does.
*>
fn void the_typed_text_is_copied_and_not_borrowed() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::InputTracker tracker;

		DString window_buffer;
		window_buffer.init(mem, 32);
		defer window_buffer.free();
		window_buffer.append_string("hello");

		run.tick(0, frame(&tracker, {}, window_buffer.str_view()));

		// The window moves on to the next frame.
		window_buffer.clear();
		window_buffer.append_string("later");

		String seen = @answer(run, "return three.input.text;");
		defer seen.free(mem);
		test::@check(seen == `"hello"`, "the frame's own text, got %s", seen);
	};
}

fn void asking_about_a_key_that_does_not_exist_throws() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::RunResult result = run.run("return three.input.isDown('banana');");
		defer result.free();

		test::@check(!result.ok, "it did not quietly answer false");
		test::@check(result.error.contains("no key called"), "and says so: '%s'", result.error);
		test::@check(result.error.contains("three.input.keys()"), "and where to look");
	};
}

<*
 The names an agent reads are the names the host searches.

 Two lists would drift the first time one gained a key, and the symptom would be
 a documented key that cannot be bound — which is worse than an undocumented one
 that can.
*>
fn void the_docs_list_the_whole_table() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		String count = @answer(run, "return three.getApiDocs().keys.length;");
		defer count.free(mem);

		DString expected;
		expected.init(mem, 8);
		defer expected.free();
		expected.appendf("%d", three::KEY_NAMES.len)!!;

		test::@check(
			count == expected.str_view(),
			"the docs list every row: %s of %s",
			count, expected.str_view()
		);
	};
}

// ============================================================================
// Handlers
// ============================================================================

fn void a_key_handler_fires_on_the_edge() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "globalThis.n = 0; three.onKeyDown('space', () => { globalThis.n++; });");

		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "space" }));
		run.tick(16, frame(&tracker, { "space" }));
		run.tick(32, frame(&tracker, {}));
		run.tick(48, frame(&tracker, { "space" }));

		String n = @answer(run, "return globalThis.n;");
		defer n.free(mem);
		test::@check(n == "2", "two presses, two calls, got '%s'", n);
	};
}

fn void a_handler_is_told_which_key_it_was() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.seen = [];
			const push = (key) => { globalThis.seen.push(key); };
			three.onKeyDown('w', push);
			three.onKeyDown('a', push);
		`);

		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "a", "w" }));

		String seen = @answer(run, "return globalThis.seen.sort();");
		defer seen.free(mem);
		test::@check(seen == `["a","w"]`, "one function, both keys, got '%s'", seen);
	};
}

fn void onkeyup_fires_on_the_other_edge() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.log = [];
			three.onKeyDown('e', () => { globalThis.log.push('down'); });
			three.onKeyUp('e', () => { globalThis.log.push('up'); });
		`);

		three::InputTracker tracker;

		// Read after each frame rather than once at the end. Reading only at the
		// end asserts the *order* of the two, which an implementation that fires
		// both handlers on the press satisfies exactly — an injection that did
		// that walked straight through this check until it was split in two.
		run.tick(0, frame(&tracker, { "e" }));
		String pressed = @answer(run, "return globalThis.log;");
		defer pressed.free(mem);
		test::@check(pressed == `["down"]`, "the press edge alone, got '%s'", pressed);

		run.tick(16, frame(&tracker, {}));
		String released = @answer(run, "return globalThis.log;");
		defer released.free(mem);
		test::@check(released == `["down","up"]`, "and the release adds the other, got '%s'", released);
	};
}

fn void binding_again_replaces_and_null_unbinds() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.a = 0;
			globalThis.b = 0;
			three.onKeyDown('q', () => { globalThis.a++; });
			three.onKeyDown('q', () => { globalThis.b++; });
		`);

		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "q" }));

		String counts = @answer(run, "return [globalThis.a, globalThis.b];");
		defer counts.free(mem);
		test::@check(counts == "[0,1]", "only the second is bound, got '%s'", counts);

		@ok(run, "three.onKeyDown('q', null);");
		run.tick(16, frame(&tracker, {}));
		run.tick(32, frame(&tracker, { "q" }));

		String after = @answer(run, "return globalThis.b;");
		defer after.free(mem);
		test::@check(after == "1", "and null unbinds it, got '%s'", after);
	};
}

<*
 A handler runs with no animation callback at all.

 Binding a key is a complete thing to want. If it needed `setAnimationLoop` to
 be running as well, the dependency would be invisible — the binding would
 simply never fire — and it is exactly the sort of thing a script would work
 around by registering an empty callback.
*>
fn void a_handler_runs_with_no_animation_callback() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "globalThis.n = 0; three.onKeyDown('r', () => { globalThis.n++; });");

		three::InputTracker tracker;
		test::@check(run.tick(0, frame(&tracker, { "r" })), "the tick did something");

		String n = @answer(run, "return globalThis.n;");
		defer n.free(mem);
		test::@check(n == "1", "the handler ran, got '%s'", n);
	};
}

<*
 Keys are dispatched before the animation callback.

 A handler that moves something and a callback that draws the consequence in the
 same frame is what a person expects. The other order shows every keypress one
 frame late, which is not a bug anybody reports — it is a control scheme that
 feels slightly wrong.
*>
fn void handlers_run_before_the_animation_callback() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.order = [];
			three.onKeyDown('t', () => { globalThis.order.push('key'); });
			three.setAnimationLoop(() => { globalThis.order.push('frame'); });
		`);

		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "t" }));

		String order = @answer(run, "return globalThis.order;");
		defer order.free(mem);
		test::@check(order == `["key","frame"]`, "keys first, got '%s'", order);
	};
}

fn void an_unknown_key_throws_at_registration() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::RunResult result = run.run("three.onKeyDown('banana', () => {});");
		defer result.free();

		test::@check(!result.ok, "the registration failed");
		test::@check(result.error.contains("no key called"), "and says so: '%s'", result.error);
	};
}

fn void an_async_handler_is_refused_at_registration() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::RunResult result = run.run("three.onKeyDown('space', async () => {});");
		defer result.free();

		test::@check(!result.ok, "the registration failed");
		test::@check(result.error.contains("synchronous"), "and says what is wrong: '%s'", result.error);
	};
}

fn void a_throwing_handler_is_stopped_and_names_its_key() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.n = 0;
			three.onKeyDown('y', () => { globalThis.n++; throw new Error('the wheels came off'); });
		`);

		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "y" }));
		run.tick(16, frame(&tracker, {}));
		run.tick(32, frame(&tracker, { "y" }));

		three::RunResult result = run.run("return globalThis.n;");
		defer result.free();

		test::@check(result.value == "1", "it ran once and was stopped, got '%s'", result.value);
		test::@check(result.ok, "the run that reports it is not itself a failure");
		test::@check(
			result.frame_error.contains("'y' key handler") && result.frame_error.contains("the wheels came off"),
			"and the reason names the key and the throw: '%s'",
			result.frame_error
		);
	};
}

fn void a_handler_that_returns_a_promise_is_stopped() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.onKeyDown('u', () => Promise.resolve(1));");

		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "u" }));

		three::RunResult result = run.run("return 1;");
		defer result.free();
		test::@check(
			result.frame_error.contains("promise"),
			"and says what it did: '%s'",
			result.frame_error
		);
	};
}

<*
 One wedged handler does not take the animation callback with it.

 They share the frame's budget, so once it is spent every later call in that
 frame would be interrupted on its first instruction — and stopped for good, for
 a failure that belongs to somebody else. The rest of the frame is skipped
 instead, and the next one is clean because the handler that spent it is gone.
*>
fn void a_wedged_handler_does_not_stop_the_animation_callback() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.frames = 0;
			three.onKeyDown('i', () => { while (true) {} });
			three.setAnimationLoop(() => { globalThis.frames++; });
		`);

		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "i" }));
		run.tick(16, frame(&tracker, {}));
		run.tick(32, frame(&tracker, {}));

		three::RunResult result = run.run("return globalThis.frames;");
		defer result.free();

		test::@check(result.frame_running, "the animation callback survived");
		test::@check(result.value == "2", "and ran on every frame after the wedge, got '%s'", result.value);
		test::@check(
			result.frame_error.contains("100 ms"),
			"while the handler was stopped by the frame budget: '%s'",
			result.frame_error
		);
	};
}

<*
 Two things failing in one frame produce two reasons.

 A frame now has more than one thing that can fail in it, and the first failure
 is usually the one that explains the rest. Keeping only the last would report
 the consequence and throw away the cause.
*>
fn void every_failure_in_a_frame_is_reported() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			three.onKeyDown('p', () => { throw new Error('the key failed'); });
			three.setAnimationLoop(() => { throw new Error('the frame failed'); });
		`);

		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "p" }));

		three::RunResult result = run.run("return 1;");
		defer result.free();

		test::@check(result.frame_error.contains("the key failed"), "the handler's reason: '%s'", result.frame_error);
		test::@check(result.frame_error.contains("the frame failed"), "and the callback's: '%s'", result.frame_error);
	};
}

<*
 What a handler logged goes where a frame's log goes.

 It is inside the frame, so it belongs to the frame — anything else would mean
 two answers to "where did that line come from" depending on which callback
 wrote it.
*>
fn void what_a_handler_logged_arrives_with_the_next_run() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `three.onKeyDown('o', (key) => { console.log('pressed ' + key); });`);

		three::InputTracker tracker;
		run.tick(0, frame(&tracker, { "o" }));

		three::RunResult result = run.run(`console.log("the script");`);
		defer result.free();
		test::@check(
			result.log == "[animation loop]\npressed o\n[script]\nthe script\n",
			"under the frame's own markers, got '%s'",
			result.log
		);
	};
}

<*
 Running out of handler slots is a sentence, not a silent drop.

 A script that binds in a loop is the only way to reach this, and the useful
 answer is the one that says what happened rather than a thirty-third key that
 quietly does nothing.
*>
fn void too_many_handlers_is_a_message() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::RunResult result = run.run(`
			const keys = three.input.keys();
			for (let i = 0; i < 40; i++) three.onKeyDown(keys[i], () => {});
		`);
		defer result.free();

		test::@check(!result.ok, "it did not silently drop the extras");
		test::@check(result.error.contains("all taken"), "and says so: '%s'", result.error);
		test::@check(result.error.contains("null"), "and how to make room: '%s'", result.error);
	};
}

// ============================================================================
// The pointer — where the cursor is
// ============================================================================

// A cursor reading, in the units the window reports: window-relative, in
// points, counted from the bottom-left. `WindowView.cursor` is the thing under
// test, so nothing here does any of the conversion itself.
macro three::Cursor @cursor(three::WindowView view, float x, float y, bool down = false)
{
	return view.cursor({ x, y }, down);
}

<*
 A window whose picture is the same size as the image it shows.

 The uninteresting case, and the one every other check below is a departure
 from: one point is one pixel, and the only thing that happens is the flip.
*>
fn void the_centre_of_the_window_is_the_centre_of_the_image() @test
{
	three::WindowView view = { .width = 800, .height = 600, .scale = 1, .image_width = 800, .image_height = 600 };
	three::Cursor at = @cursor(view, 400, 300);

	test::@check(at.inside, "the middle of the window is in it");
	test::@check(at.x == 400, "and in the middle of the image across, got %f", at.x);
	test::@check(at.y == 300, "and down, got %f", at.y);
}

<*
 The flip, which is the whole reason a cursor cannot be handed to `pick` as it
 arrives.

 `c3w`'s contract is Cocoa's — y grows upward from the bottom-left, and the
 Linux backends convert to it — while `screen_ray` counts rows from the top,
 the way the image is stored. A cursor a fifth of the way up the window is four
 fifths of the way down the picture, and the unflipped answer would be 120.
*>
fn void the_cursor_is_flipped_because_the_window_counts_up() @test
{
	three::WindowView view = { .width = 800, .height = 600, .scale = 1, .image_width = 800, .image_height = 600 };
	three::Cursor at = @cursor(view, 100, 120);

	test::@check(at.x == 100, "across is untouched, got %f", at.x);
	test::@check(at.y == 480, "and 120 up from the bottom is row 480, got %f", at.y);
}

<*
 A retina window maps by fraction, not by the backing scale.

 The tempting version multiplies the pointer by `get_scale()` — which is what
 `drive_camera` does, correctly, for a *delta* — and it is wrong here by exactly
 the scale: the centre of this window would come back as 800, off the right edge
 of an 800-pixel image. The picture is the target stretched onto the swapchain,
 so the only thing that survives the trip is the fraction.
*>
fn void a_retina_window_maps_by_fraction_and_not_by_the_backing_scale() @test
{
	// An 800x600-point window on a 2x display, showing an 800x600 image.
	three::WindowView view = { .width = 1600, .height = 1200, .scale = 2, .image_width = 800, .image_height = 600 };
	three::Cursor at = @cursor(view, 400, 300);

	test::@check(at.inside, "the middle of the window is in it");
	test::@check(at.x == 400, "and the middle of the image, not twice it, got %f", at.x);
	test::@check(at.y == 300, "in both directions, got %f", at.y);
}

<*
 A window dragged to a different size than the image still lands on it.

 `--width`/`--height` fix the offscreen target and a resize drag moves only the
 swapchain, so the two disagree for the whole rest of the session. This is the
 case that makes the mapping a fraction rather than an identity.
*>
fn void a_resized_window_still_maps_onto_the_image() @test
{
	three::WindowView view = { .width = 1600, .height = 1200, .scale = 1, .image_width = 800, .image_height = 600 };
	three::Cursor at = @cursor(view, 400, 300);

	test::@check(at.x == 200, "a quarter across the window is a quarter across the image, got %f", at.x);
	test::@check(at.y == 450, "and a quarter up is three quarters down, got %f", at.y);
}

<*
 The window answers where the cursor is even when it is somewhere else.

 `getMousePos` is window-relative and unclamped, so a cursor on the desktop
 reports a negative column or one past the edge. Nothing downstream would notice
 — `pick` would happily raycast through a pixel that does not exist — so it is
 caught at the conversion, which is the only place that knows how big the window
 is.
*>
fn void a_cursor_off_the_window_is_not_inside() @test
{
	three::WindowView view = { .width = 800, .height = 600, .scale = 1, .image_width = 800, .image_height = 600 };

	test::@check(!@cursor(view, -1, 300).inside, "to the left");
	test::@check(!@cursor(view, 800, 300).inside, "past the right edge, which is exclusive");
	test::@check(!@cursor(view, 400, -1).inside, "below");
	test::@check(!@cursor(view, 400, 600).inside, "and above");
	test::@check(@cursor(view, 0, 0).inside, "while the bottom-left corner itself is in");
}

<*
 A minimised window divides by nothing.

 The extent goes to zero while a window is minimised and the scale is zero
 before the first frame. Both reach this function on an ordinary frame, and the
 answer wanted is "the cursor is nowhere" rather than an infinity that
 propagates into a raycast.
*>
fn void a_window_with_no_size_answers_nothing() @test
{
	three::WindowView none = { .width = 0, .height = 0, .scale = 1, .image_width = 800, .image_height = 600 };
	three::Cursor at = @cursor(none, 400, 300, true);
	test::@check(!at.inside && at.x == 0 && at.y == 0, "a zero extent is nowhere, got %f, %f", at.x, at.y);

	three::WindowView unscaled = { .width = 800, .height = 600, .scale = 0, .image_width = 800, .image_height = 600 };
	test::@check(!@cursor(unscaled, 400, 300).inside, "and so is a zero scale");
}

// ============================================================================
// The pointer — what a click is
// ============================================================================

// One reading of the cursor, already in image pixels, so these checks say what
// the mouse did rather than where a hypothetical window was.
macro three::MouseState @moved(three::MouseTracker* tracker, float x, float y, bool down, double at_ms, bool inside = true)
{
	three::Cursor cursor = { .inside = inside, .down = down, .x = x, .y = y };
	return tracker.step(cursor, at_ms);
}

fn void a_press_and_a_release_in_one_place_is_a_click() @test
{
	three::MouseTracker mouse;

	test::@check(!@moved(&mouse, 100, 100, true, 0).clicked, "the press alone is not one");
	three::MouseState up = @moved(&mouse, 100, 100, false, 50);
	test::@check(up.clicked, "the release completes it");
	test::@check(up.x == 100 && up.y == 100, "where it happened, got %f, %f", up.x, up.y);
}

<*
 A click lasts one frame, like every other edge here.

 A `clicked` that stayed true would be read once per frame by an animation
 callback and would pick something new sixty times a second — the same failure
 `a_held_key_is_pressed_once` guards the keyboard against.
*>
fn void a_click_is_reported_for_exactly_one_frame() @test
{
	three::MouseTracker mouse;

	@moved(&mouse, 100, 100, true, 0);
	test::@check(@moved(&mouse, 100, 100, false, 50).clicked, "the frame it finished on");
	test::@check(!@moved(&mouse, 100, 100, false, 100).clicked, "and not the next");
	test::@check(!@moved(&mouse, 100, 100, false, 150).clicked, "or the one after that");
}

<*
 A drag is not a click, which is the whole reason the slop exists: the left
 button orbits the camera, so every drag ends in a release over the scene.
*>
fn void a_press_that_travels_is_a_drag() @test
{
	three::MouseTracker mouse;

	@moved(&mouse, 100, 100, true, 0);
	@moved(&mouse, 300, 100, true, 50);
	test::@check(!@moved(&mouse, 300, 100, false, 60).clicked, "an orbit does not select anything");
}

<*
 A press held in one place is not a click either.

 Half a second is longer than any click and shorter than any deliberate hold,
 and the direction of the mistake is chosen: a click that has to be repeated is
 better than an object picked without being asked for, because the second one
 changes the scene and the person has to work out what it changed.
*>
fn void a_press_that_is_held_is_not_a_click() @test
{
	three::MouseTracker mouse;

	@moved(&mouse, 100, 100, true, 0);
	test::@check(!@moved(&mouse, 100, 100, false, 800).clicked, "a hold is not a click");
	test::@check(@moved(&mouse, 100, 100, true, 900).clicked == false, "and the next press is only a press");
	test::@check(@moved(&mouse, 100, 100, false, 950).clicked, "which does click when it is let go in time");
}

<*
 A press that started somewhere else is not a click that ends here.

 The window reports a cursor position whether or not the cursor is over it, so
 a press on the desktop and a release over the scene arrives as a perfectly
 ordinary pair of edges. `inside` at the press is what tells them apart.
*>
fn void a_press_that_starts_outside_is_not_a_click() @test
{
	three::MouseTracker mouse;

	@moved(&mouse, 100, 100, true, 0, inside: false);
	test::@check(!@moved(&mouse, 100, 100, false, 50).clicked, "a press from off the window is not aimed at it");
}

fn void a_release_outside_the_window_is_not_a_click() @test
{
	three::MouseTracker mouse;

	@moved(&mouse, 100, 100, true, 0);
	test::@check(!@moved(&mouse, 100, 100, false, 50, inside: false).clicked, "and neither is a release off it");
}

<*
 The stuck latch, and why there is no release gate here.

 AppKit swallows the mouse-up that ends a title-bar drag, so the button reads as
 held for the rest of the session — the bug `controls.c3` documents and waits a
 button-free frame for. Nothing waits here, because a click needs a press *edge*
 and a latch that never falls produces none: the failure is no clicks rather
 than a click a frame, and it heals on its own.
*>
fn void a_stuck_button_never_clicks_and_heals_at_the_next_one() @test
{
	three::MouseTracker mouse;

	// A drag by the title bar: pressed, moved away, and the release never comes.
	@moved(&mouse, 100, 100, true, 0);
	test::@check(!@moved(&mouse, 700, 500, true, 100).clicked, "the drag itself clicks nothing");
	test::@check(!@moved(&mouse, 700, 500, true, 200).clicked, "and the stuck frames after it click nothing");
	test::@check(!@moved(&mouse, 400, 300, true, 1000).clicked, "however far the cursor is moved");

	// The user's next real click. Its press is invisible — the latch was already
	// set — and its release is what finally clears it.
	test::@check(!@moved(&mouse, 400, 300, false, 1010).clicked, "the first real click after is swallowed");

	// And the one after that is an ordinary click.
	@moved(&mouse, 400, 300, true, 2000);
	test::@check(@moved(&mouse, 400, 300, false, 2010).clicked, "the one after it works");
}

// ============================================================================
// The pointer, from a script
// ============================================================================

// One frame of mouse and nothing else held.
fn three::InputState pointer_frame(
	three::InputTracker* tracker, float x, float y, bool down, double at_ms, bool inside = true
)
{
	three::Cursor cursor = { .inside = inside, .down = down, .x = x, .y = y };
	return tracker.step({}, "", cursor, at_ms);
}

fn void a_script_can_ask_where_the_pointer_is() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::InputTracker tracker;
		run.tick(0, pointer_frame(&tracker, 120, 90, true, 0));

		String where = @answer(run, `
			const p = three.input.pointer;
			return [p.x, p.y, p.inside, p.down, p.clicked];
		`);
		defer where.free(mem);
		test::@check(where == "[120,90,true,true,false]", "all five, got '%s'", where);
	};
}

<*
 The pointer is taken whether or not anything is registered to read it.

 `tick` returns early when there is no callback and no handler, and the input
 has to have been taken before that return — otherwise `three.input.pointer`
 from an ordinary `run_script` would answer about whatever frame last happened
 to have a handler on it.
*>
fn void the_pointer_arrives_with_nothing_registered() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::InputTracker tracker;
		bool ran = run.tick(0, pointer_frame(&tracker, 33, 44, false, 0));

		test::@check(!ran, "nothing was registered, so nothing ran");

		String x = @answer(run, "return three.input.pointer.x;");
		defer x.free(mem);
		test::@check(x == "33", "and the pointer arrived anyway, got '%s'", x);
	};
}

fn void a_click_handler_fires_once_and_says_where() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.clicks = [];
			three.onClick((hit, x, y) => { globalThis.clicks.push(x + ',' + y); });
		`);

		three::InputTracker tracker;
		run.tick(0, pointer_frame(&tracker, 200, 150, true, 0));
		run.tick(16, pointer_frame(&tracker, 200, 150, true, 16));
		run.tick(32, pointer_frame(&tracker, 200, 150, false, 32));
		run.tick(48, pointer_frame(&tracker, 200, 150, false, 48));

		String clicks = @answer(run, "return globalThis.clicks;");
		defer clicks.free(mem);
		test::@check(clicks == `["200,150"]`, "once, at the pixel it happened on, got '%s'", clicks);
	};
}

<*
 The handler is told what is under the cursor, and with no device that is
 nothing.

 A miss and a context with no GPU answer the same `null`, which is the truth in
 both cases: there is nothing under the cursor. The alternative — throwing the
 way `scene.pick` does — would make a click handler written for a window fail
 every frame under `--headless` for a mistake nobody made.
*>
fn void a_click_with_no_device_is_told_null() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.seen = 'not called';
			three.onClick((hit) => { globalThis.seen = hit === null ? 'null' : typeof hit; });
		`);

		three::InputTracker tracker;
		run.tick(0, pointer_frame(&tracker, 10, 10, true, 0));
		run.tick(16, pointer_frame(&tracker, 10, 10, false, 16));

		String seen = @answer(run, "return globalThis.seen;");
		defer seen.free(mem);
		test::@check(seen == `"null"`, "a hit that is nothing is null, got '%s'", seen);
	};
}

fn void binding_a_click_again_replaces_and_null_unbinds() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.seen = [];
			three.onClick(() => { globalThis.seen.push('first'); });
			three.onClick(() => { globalThis.seen.push('second'); });
		`);

		three::InputTracker tracker;
		run.tick(0, pointer_frame(&tracker, 10, 10, true, 0));
		run.tick(16, pointer_frame(&tracker, 10, 10, false, 16));

		@ok(run, "three.onClick(null);");
		run.tick(32, pointer_frame(&tracker, 10, 10, true, 32));
		run.tick(48, pointer_frame(&tracker, 10, 10, false, 48));

		String seen = @answer(run, "return globalThis.seen;");
		defer seen.free(mem);
		test::@check(seen == `["second"]`, "one handler, replaced then removed, got '%s'", seen);
	};
}

fn void a_click_handler_alone_is_enough_to_tick() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.onClick(() => {});");

		three::InputTracker tracker;
		test::@check(
			run.tick(0, pointer_frame(&tracker, 10, 10, false, 0)),
			"a click handler with no animation callback still makes a frame"
		);
	};
}

<*
 The click runs before the animation callback, for the reason the keys do: a
 handler that moves something and a callback that draws the consequence in the
 same frame is the order a person expects.
*>
fn void the_click_runs_before_the_animation_callback() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.order = [];
			three.onClick(() => { globalThis.order.push('click'); });
			three.setAnimationLoop(() => { globalThis.order.push('frame'); });
		`);

		three::InputTracker tracker;
		run.tick(0, pointer_frame(&tracker, 10, 10, true, 0));
		run.tick(16, pointer_frame(&tracker, 10, 10, false, 16));

		String order = @answer(run, "return globalThis.order;");
		defer order.free(mem);
		test::@check(order == `["frame","click","frame"]`, "the click is inside its own frame, got '%s'", order);
	};
}

fn void a_throwing_click_handler_is_stopped() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, `
			globalThis.n = 0;
			three.onClick(() => { globalThis.n++; throw new Error('the wheels came off'); });
		`);

		three::InputTracker tracker;
		run.tick(0, pointer_frame(&tracker, 10, 10, true, 0));
		run.tick(16, pointer_frame(&tracker, 10, 10, false, 16));
		run.tick(32, pointer_frame(&tracker, 10, 10, true, 32));
		run.tick(48, pointer_frame(&tracker, 10, 10, false, 48));

		three::RunResult result = run.run("return globalThis.n;");
		defer result.free();

		test::@check(result.value == "1", "it ran once and was stopped, got '%s'", result.value);
		test::@check(result.ok, "the run that reports it is not itself a failure");
		test::@check(
			result.frame_error.contains("click handler") && result.frame_error.contains("the wheels came off"),
			"and the reason says what threw: '%s'",
			result.frame_error
		);
	};
}

fn void a_click_handler_that_returns_a_promise_is_stopped() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		@ok(run, "three.onClick(() => Promise.resolve(1));");

		three::InputTracker tracker;
		run.tick(0, pointer_frame(&tracker, 10, 10, true, 0));
		run.tick(16, pointer_frame(&tracker, 10, 10, false, 16));

		three::RunResult result = run.run("return 1;");
		defer result.free();
		test::@check(result.frame_error.contains("promise"), "and says what it did: '%s'", result.frame_error);
	};
}

fn void an_async_click_handler_is_refused_at_registration() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		three::RunResult result = run.run("three.onClick(async () => {});");
		defer result.free();

		test::@check(!result.ok, "an async click handler is refused where it was written");
		test::@check(result.error.contains("synchronous"), "and says why: '%s'", result.error);
	};
}

fn void the_docs_describe_the_click() @test
{
	@with_js(; three::JsRuntime* run, three::MeshPass* pass)
	{
		String found = @answer(run, `
			const d = three.getApiDocs();
			return [
				'three.onClick(fn)' in d.functions,
				'three.input.pointer' in d.functions,
				d.differences.some(s => s.includes('onClick')),
			];
		`);
		defer found.free(mem);
		test::@check(found == "[true,true,true]", "the click is documented where the rest is, got '%s'", found);
	};
}

<*
 The whole of T3, end to end: a click becomes the object a script is holding.

 Everything above this is a piece — the fraction, the flip, the edge, the
 dispatch — and each is checked where it can be checked exactly. This is the
 one that says the pieces are joined the right way round, and it is the only
 check here that needs a device, because a raycast with nothing uploaded can
 only ever answer `null`.

 The box is at the origin and the camera is aimed at it, so the centre of the
 image is the one pixel whose answer is not in doubt. `hit.object === box` is
 the assertion that matters: the host answers with a node index, and turning
 that back into the object the script built is `asIntersection` going through
 the live scene — the branch a deviceless click can never reach.
*>
fn void a_click_picks_the_object_under_it() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ok(run, `
			const scene = new three.Scene();
			globalThis.box = new three.Mesh(new three.BoxGeometry(1, 1, 1));
			globalThis.box.name = 'the box';
			scene.add(globalThis.box);
			three.camera.frameAll();

			globalThis.seen = 'not called';
			three.onClick((hit) => {
				globalThis.seen = hit === null
					? 'nothing'
					: (hit.object === globalThis.box ? 'the object itself' : 'a stranger: ' + hit.name);
			});
		`);

		// The centre of the image, which is where `frameAll` has just put the
		// box. The pixel is the *image's*, which is what a click arrives as.
		float x = (float)renderer.target.extent.width / 2.0f;
		float y = (float)renderer.target.extent.height / 2.0f;

		three::InputTracker tracker;
		run.tick(0, pointer_frame(&tracker, x, y, true, 0));
		run.tick(16, pointer_frame(&tracker, x, y, false, 16));

		String seen = @answer(run, "return globalThis.seen;");
		defer seen.free(mem);
		test::@check(seen == `"the object itself"`, "the click found the box, got '%s'", seen);
	};
}

<*
 And a click on empty space finds nothing rather than the nearest thing.

 The corner of the image with a single box at the centre: `null` is the whole
 answer, and a picker that answered with the box anyway would pass every check
 above this one.
*>
fn void a_click_on_nothing_is_a_miss() @test
{
	@with_gpu_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ok(run, `
			const scene = new three.Scene();
			scene.add(new three.Mesh(new three.BoxGeometry(1, 1, 1)));
			three.camera.frameAll();

			globalThis.seen = 'not called';
			three.onClick((hit) => { globalThis.seen = hit === null ? 'nothing' : hit.name; });
		`);

		three::InputTracker tracker;
		run.tick(0, pointer_frame(&tracker, 0, 0, true, 0));
		run.tick(16, pointer_frame(&tracker, 0, 0, false, 16));

		String seen = @answer(run, "return globalThis.seen;");
		defer seen.free(mem);
		test::@check(seen == `"nothing"`, "the corner found nothing, got '%s'", seen);
	};
}
