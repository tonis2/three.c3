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
