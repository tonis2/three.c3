<*
 The interface layer — `src/render/ui.c3` and `Target.begin_overlay`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::ui`

 **Two claims, and they are the ones that would be quietly wrong.**

 The first is that the overlay draws *over* the finished frame rather than
 instead of it. `LOAD_OP_CLEAR` where `LOAD_OP_LOAD` belongs, or a barrier from
 `UNDEFINED` where the current layout belongs, both produce a frame that is
 exactly the interface on a black field — and neither is a validation error,
 because discarding an attachment is a legal thing to ask for. So the check is a
 pixel one: the scene has to still be there underneath.

 The second is that it is in `target.color` and therefore in `capture()`. The
 whole argument for drawing before the blit rather than after it is that
 `--screenshot`, the MCP screenshot tool and the window all show the same
 picture. *For free* is exactly the kind of claim that needs a test under it.

 Everything else is the validation layer's job, and it is armed here: a wrong
 load op is silent, but a missing barrier, a second `close`, or a rendering left
 open is not.
*>
module three_tests::ui;

import three;
import cui;
import cui::widgets;
import vk;
import c3w;
import image;
import std::core::test;
import std::math;
import std::io;

const uint W = 200;
const uint H = 120;

macro @with_renderer(; @body(three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(true, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H, validate: true)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
}

// A line, through the same entry point `three.debug.overlay` reaches.
fn void set(three::Renderer* renderer, String line)
{
	renderer.ui.set_overlay(&renderer.gpu, &renderer.target, line)!!;
}

// How much of the top-left corner is not the background — the band the overlay
// is anchored into. Counted rather than sampled: a glyph is thin, and the exact
// pixel a stem lands on is a fact about the font and not about the renderer.
fn uint lit_pixels(image::Image* img)
{
	sz bpp   = img.bytes_per_pixel();
	uint lit = 0;
	sz rows  = math::min((sz)img.height, (sz)40);
	for (sz y = 0; y < rows; y++)
	{
		for (sz x = 0; x < (sz)img.width; x++)
		{
			if (img.pixels[(y * (sz)img.width + x) * bpp] > 128) lit++;
		}
	}
	return lit;
}

// Whether that pixel is the saturated red nothing else in a frame is — how a
// test asks which of two overlapping things was drawn on top.
fn bool red_at(image::Image* img, uint x, uint y)
{
	sz bpp = img.bytes_per_pixel();
	sz at  = ((sz)y * (sz)img.width + (sz)x) * bpp;
	return img.pixels[at] > 150 && img.pixels[at + 1] < 90;
}

// ============================================================================
// Nothing until something asks
// ============================================================================

<*
 A renderer nobody asked for an interface is a renderer with no interface.

 The claim the headless tests rest on: `Renderer.init` builds no `Ui`, no
 buffers and no pipeline, so every frame in every other file is byte-identical to
 one drawn before this layer existed.
*>
fn void the_layer_does_not_exist_until_it_is_used() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		test::@check(!renderer.ui.active(), "a fresh renderer already had an interface layer");

		image::Image shot = renderer.capture()!!;
		defer shot.free();
		test::@check(shot.width == W, "the frame came back the wrong size");

		test::@check(!renderer.ui.active(), "drawing a frame brought the interface layer up on its own");
	};
}

<*
 An empty line is not a line.

 `three.debug.overlay('')` is how a script takes the overlay away, and taking
 away something that was never there must not build a font atlas and a pipeline
 to do it.
*>
fn void an_empty_line_never_brings_the_layer_up() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		set(renderer, "");
		test::@check(!renderer.ui.active(), "an empty overlay built the whole layer");
	};
}

// ============================================================================
// The pixels
// ============================================================================

<*
 The line appears, and the frame under it survives.

 Both halves in one check, because they fail in opposite directions and a test
 for either one alone passes on the other's bug: an overlay that clears first
 shows *more* text on a *black* frame, which a "did anything appear" check
 cannot tell from success.
*>
fn void the_overlay_draws_over_the_frame_and_not_instead_of_it() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		// Not the default: a background this test picked, so "the scene survived"
		// is a fact about a specific colour rather than about whatever the default
		// happens to be today.
		renderer.clear = { 0.20, 0.05, 0.05, 1.0 };

		image::Image bare = renderer.capture()!!;
		defer bare.free();
		uint before = lit_pixels(&bare);

		set(renderer, "HELLO OVERLAY 12345");
		image::Image with = renderer.capture()!!;
		defer with.free();

		test::@check(lit_pixels(&with) > before, "the overlay put no bright pixels in the top band");

		// The bottom of the frame is nowhere near the overlay, so it is the half of
		// the picture a clear would have taken and a draw-over cannot touch.
		// 0.20 is written as sRGB and stored as sRGB, so the byte is 0.20 * 255 and
		// not the linear value — see `TARGET_COLOR_FORMAT`. A cleared frame reads 0
		// here, so anything near 51 is the background still being there.
		sz bpp    = with.bytes_per_pixel();
		sz bottom = ((sz)with.height - 4) * (sz)with.width + (sz)with.width / 2;
		test::@check(
			with.pixels[bottom * bpp] > 40,
			"the frame under the overlay was cleared — the red background is gone (r = %d)",
			(int)with.pixels[bottom * bpp]
		);
	};
}

<*
 Taking the line away puts the frame back exactly as it was.

 The other direction, and the one that catches an overlay that leaves its last
 glyphs in the display list: an empty label paints nothing, so the frame has to
 be identical to the one drawn before the layer existed at all.
*>
fn void clearing_the_line_restores_the_frame() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.20, 0.05, 0.05, 1.0 };

		image::Image bare = renderer.capture()!!;
		defer bare.free();

		set(renderer, "gone in a moment");
		image::Image with = renderer.capture()!!;
		defer with.free();
		test::@check(lit_pixels(&with) > lit_pixels(&bare), "nothing was drawn to take away");

		set(renderer, "");
		image::Image after = renderer.capture()!!;
		defer after.free();

		test::@check(
			lit_pixels(&after) == lit_pixels(&bare),
			"the frame did not come back: %d lit pixels against %d",
			lit_pixels(&after),
			lit_pixels(&bare)
		);
	};
}

// ============================================================================
// The line's lifetime
// ============================================================================

<*
 One line, this frame, gone the next.

 `expire_overlay` runs at the top of the script frame, so a line set during the
 frame that just ran survives one expiry and not two. A script writing the same
 string every frame is the case that has to keep working, and it is the first
 half of this.
*>
fn void the_line_lasts_exactly_one_frame() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.20, 0.05, 0.05, 1.0 };

		image::Image bare = renderer.capture()!!;
		defer bare.free();

		set(renderer, "hp 100");

		// The frame the line was set in.
		renderer.ui.expire_overlay();
		image::Image kept = renderer.capture()!!;
		defer kept.free();
		test::@check(lit_pixels(&kept) > lit_pixels(&bare), "the line was dropped by the frame that set it");

		// The next one, with nothing having written it again.
		renderer.ui.expire_overlay();
		image::Image dropped = renderer.capture()!!;
		defer dropped.free();
		test::@check(
			lit_pixels(&dropped) == lit_pixels(&bare),
			"the line outlived the frame it belonged to"
		);
	};
}

// ============================================================================
// Under the validation layer
// ============================================================================

<*
 Four frames with an interface on them, and the layer has nothing to say.

 Four rather than one because `CANVAS_SLOTS` is 2: a host that writes the copy a
 queued draw is still reading tears the display list, and the second time round
 the rotation is the first frame that could. The changing text is what makes each
 upload a real one — an unchanged canvas uploads nothing, which would leave the
 rotation untested.

 `render_offscreen` is here rather than assumed: it is the second of the three
 paths into `record_scene`, and "they all go through one function" is the claim
 being checked rather than repeated.
*>
fn void the_overlay_is_silent_under_validation() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		if (!renderer.gpu.validation) return;

		// One frame before the sink is armed, so anything the layer objects to
		// afterwards belongs to the overlay and not to the setup.
		image::Image warmup = renderer.capture()!!;
		warmup.free();

		renderer.gpu.begin_capture();

		set(renderer, "frame one");
		image::Image one = renderer.capture()!!;
		one.free();

		set(renderer, "frame two, a longer line");
		image::Image two = renderer.capture()!!;
		two.free();

		set(renderer, "3");
		renderer.render_offscreen()!!;

		set(renderer, "");
		image::Image bare = renderer.capture()!!;
		bare.free();

		String errors   = renderer.gpu.sink.errors.str_view();
		String warnings = renderer.gpu.sink.warnings.str_view();
		renderer.gpu.end_capture();

		test::@check(errors.len == 0, "the overlay produced validation errors: %s", errors);
		test::@check(warnings.len == 0, "and warnings: %s", warnings);
	};
}

<*
 The same, with a post chain running.

 The one ordering that is not exercised by any other check here: with a chain
 active it is the tonemap that leaves `target.color` in
 `COLOR_ATTACHMENT_OPTIMAL`, not the scene, and `begin_overlay` barriers from
 that layout on both paths. A wrong `oldLayout` is a validation error rather than
 a wrong picture, which is why this is a silence check and not a pixel one.
*>
fn void the_overlay_is_silent_over_a_post_chain() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		if (!renderer.gpu.validation) return;

		renderer.post.set(&renderer.gpu, &renderer.target, `float3 post(Post p) { return p.color.bgr; }`, {})!!;

		image::Image warmup = renderer.capture()!!;
		warmup.free();

		renderer.gpu.begin_capture();

		set(renderer, "over the chain");
		image::Image one = renderer.capture()!!;
		one.free();
		image::Image two = renderer.capture()!!;
		two.free();

		String errors   = renderer.gpu.sink.errors.str_view();
		String warnings = renderer.gpu.sink.warnings.str_view();
		renderer.gpu.end_capture();

		test::@check(errors.len == 0, "the overlay over a post chain produced validation errors: %s", errors);
		test::@check(warnings.len == 0, "and warnings: %s", warnings);
	};
}

// ============================================================================
// The snapshot
// ============================================================================

<*
 What a widget said, and which node said it.

 A listener rather than a JavaScript handler, because `render/ui.c3` is written
 to know nothing about QuickJS — which is exactly what makes the dispatch
 testable without an engine, a script or a window.
*>
struct Heard
{
	uint calls;
	uint node;
	three::UiEventKind kind;
	bool flag;
	float value;
	usz index;
}

fn void listen(void* host, uint node, three::UiEvent event)
{
	Heard* heard = (Heard*)host;
	heard.calls++;
	heard.node = node;
	heard.kind = event.kind;
	heard.flag = event.flag;
	heard.value = event.value;
	heard.index = event.index;
}

// A tree of one node, which is what most of these want.
fn uint one_node(three::Renderer* renderer, three::UiNodeSpec spec)
{
	renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
	uint at = renderer.ui.push_node(spec, -1)!!;
	renderer.ui.commit_tree();
	return at;
}

// One frame of pointer at a place in the image, with the left button as given.
// Two calls make a click: cui takes a press edge and a release edge, and a
// button fires on the release.
fn void point(three::Renderer* renderer, float x, float y, bool down)
{
	renderer.ui.feed({ .inside = true, .down = down, .x = x, .y = y }, {}, "", 16.0);
}

<*
 A tree appears, and taking it away puts the frame back exactly as it was.

 The same paired claim the overlay checks, for the other verb — and the one that
 catches a `commit_tree` that grafts the new subtree without unmounting the old,
 which draws correctly and leaks an element table that grows every call.
*>
fn void a_snapshot_draws_and_clearing_it_puts_the_frame_back() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.02, 0.02, 0.02, 1.0 };

		image::Image bare = renderer.capture()!!;
		defer bare.free();

		one_node(
			renderer,
			{ .kind = three::UiNodeKind.RECT, .size = { 60, 20 }, .color = { 1.0, 1.0, 1.0, 1.0 } }
		);
		image::Image with = renderer.capture()!!;
		defer with.free();
		test::@check(lit_pixels(&with) > lit_pixels(&bare) + 500, "the snapshot drew nothing");

		renderer.ui.clear_tree();
		image::Image after = renderer.capture()!!;
		defer after.free();
		test::@check(
			lit_pixels(&after) == lit_pixels(&bare),
			"the tree outlived the clear: %d lit pixels against %d",
			lit_pixels(&after),
			lit_pixels(&bare)
		);
	};
}

<*
 The debug line and a script's interface are two floors of one root.

 They have different owners and different lifetimes — the host wipes the line
 every frame and the tree stays until it is replaced — so a `set` that took the
 whole root would silently stop `three.debug.overlay` working, which is the one
 thing that has to work when nothing else does.
*>
fn void a_snapshot_does_not_take_the_debug_line_with_it() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.02, 0.02, 0.02, 1.0 };

		set(renderer, "still here");
		image::Image line_only = renderer.capture()!!;
		defer line_only.free();
		uint before = lit_pixels(&line_only);

		one_node(
			renderer,
			{
				.kind = three::UiNodeKind.RECT,
				.size = { 30, 8 },
				.color = { 1.0, 1.0, 1.0, 1.0 },
			}
		);
		image::Image both = renderer.capture()!!;
		defer both.free();

		test::@check(lit_pixels(&both) > before, "setting a tree took the debug line off the frame");
	};
}

<*
 A patch changes the value without rebuilding anything.

 The half that matters is the element identity: `patch` exists so a HUD can
 change a number sixty times a second without the rebuild a `set` performs, and
 an implementation that quietly rebuilt would pass a pixel check and fail this
 one.
*>
fn void a_patch_changes_a_value_without_rebuilding_the_node() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.02, 0.02, 0.02, 1.0 };

		one_node(
			renderer,
			{
				.kind = three::UiNodeKind.LABEL,
				.key = "fps",
				.text = "",
				.text_size = 16.0,
				.color = { 1.0, 1.0, 1.0, 1.0 },
				.has_text = true,
			}
		);
		image::Image empty = renderer.capture()!!;
		defer empty.free();

		uint at = renderer.ui.node_for("fps")!!;
		void* was = (void*)renderer.ui.nodes[at].element;

		renderer.ui.patch(at, { .has_text = true, .text = "144 fps" });
		image::Image patched = renderer.capture()!!;
		defer patched.free();

		test::@check(lit_pixels(&patched) > lit_pixels(&empty), "the patched label drew nothing");
		test::@check(
			(void*)renderer.ui.nodes[at].element == was,
			"the patch rebuilt the element instead of writing its field"
		);
	};
}

<*
 Patching a readout every frame does not grow anything.

 The verb a HUD calls sixty times a second, and a string a widget borrows has to
 outlive the element — so the tempting implementation keeps every copy and leaks
 an hour of play. One buffer per node is the answer, and this is the check under
 it.
*>
fn void patching_the_same_label_a_thousand_times_keeps_one_string() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		one_node(
			renderer,
			{ .kind = three::UiNodeKind.LABEL, .key = "fps", .text = "0", .text_size = 14.0, .has_text = true }
		);

		uint at = renderer.ui.node_for("fps")!!;
		sz held = renderer.ui.nodes[at].owned.len();

		for (int i = 0; i < 1000; i++)
		{
			renderer.ui.patch(at, { .has_text = true, .text = string::tformat("%d fps", i) });
		}

		test::@check(
			renderer.ui.nodes[at].owned.len() == held,
			"a thousand patches kept %d strings instead of %d",
			renderer.ui.nodes[at].owned.len(),
			held
		);
		String shown = renderer.ui.nodes[at].element.widget_as(cui::widgets::Label).text;
		test::@check(shown == "999 fps", "the last patch did not stick: '%s'", shown);
	};
}

<*
 A key that names nothing is a message rather than a silent no-op.

 A HUD whose `set` renamed a node would otherwise freeze with no symptom at all,
 which is the failure that costs an afternoon.
*>
fn void patching_a_key_that_names_nothing_is_a_fault() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		one_node(renderer, { .kind = three::UiNodeKind.LABEL, .key = "fps", .text = "x", .has_text = true });

		test::@check(@ok(renderer.ui.node_for("fps")), "a key something carries did not resolve");
		test::@check(!@ok(renderer.ui.node_for("nope")), "a key nothing carries resolved anyway");
	};
}

// ============================================================================
// Keys, and what a rebuild would otherwise destroy
// ============================================================================

<*
 The text under somebody's fingers survives the rebuild.

 `set` rebuilds the tree, which is what makes the API simple and what would make
 it unusable: a field that reset itself every time the panel around it changed
 could not be typed into. The snapshot here names no text on the second pass, so
 the carry-over is what has to answer.
*>
fn void a_keyed_field_keeps_what_was_typed_across_a_rebuild() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		one_node(
			renderer,
			{ .kind = three::UiNodeKind.TEXTFIELD, .key = "name", .text = "Ada", .has_text = true }
		);

		// The rebuild a panel makes when something else on it changed: same key,
		// same kind, and nothing said about the text.
		one_node(renderer, { .kind = three::UiNodeKind.TEXTFIELD, .key = "name" });

		uint at = renderer.ui.node_for("name")!!;
		String kept = renderer.ui.nodes[at].element.widget_as(cui::widgets::TextField).value();
		test::@check(kept == "Ada", "the field lost what was typed into it: '%s'", kept);

		// And a snapshot that DOES name the text wins, because that is the caller
		// saying so rather than the caller staying quiet.
		one_node(
			renderer,
			{ .kind = three::UiNodeKind.TEXTFIELD, .key = "name", .text = "Grace", .has_text = true }
		);
		at = renderer.ui.node_for("name")!!;
		kept = renderer.ui.nodes[at].element.widget_as(cui::widgets::TextField).value();
		test::@check(kept == "Grace", "a named text did not win over the carried one: '%s'", kept);
	};
}

<*
 The same rule for the value a drag left behind.

 A slider is the case where the two directions are both ordinary: a panel
 rebuilt around it must not snap the handle back, and a script that writes
 `value` means it.
*>
fn void a_keyed_slider_keeps_the_value_the_snapshot_left_unsaid() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		one_node(
			renderer,
			{ .kind = three::UiNodeKind.SLIDER, .key = "damp", .max = 1.0, .value = 0.75, .has_value = true }
		);

		uint at = renderer.ui.node_for("damp")!!;
		// What a drag would have left there.
		renderer.ui.nodes[at].element.widget_as(cui::widgets::Slider).value = 0.4f;

		one_node(renderer, { .kind = three::UiNodeKind.SLIDER, .key = "damp", .max = 1.0 });
		at = renderer.ui.node_for("damp")!!;
		float kept = renderer.ui.nodes[at].element.widget_as(cui::widgets::Slider).value;
		test::@check(kept == 0.4f, "the slider lost where the drag left it: %f", (double)kept);
	};
}

<*
 A key only carries across to the same kind.

 A `slider` renamed into a `checkbox` under one key is a different control, and
 handing it the old one's number would be a value appearing in a tick box.
*>
fn void a_key_does_not_carry_state_between_different_kinds() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		one_node(
			renderer,
			{ .kind = three::UiNodeKind.CHECKBOX, .key = "flag", .checked = true, .has_checked = true }
		);
		one_node(renderer, { .kind = three::UiNodeKind.SLIDER, .key = "flag", .max = 1.0 });

		uint at = renderer.ui.node_for("flag")!!;
		float value = renderer.ui.nodes[at].element.widget_as(cui::widgets::Slider).value;
		test::@check(value == 0.0f, "a checkbox's state was carried into a slider: %f", (double)value);
	};
}

<*
 A tree that fails to build leaves the live one exactly as it was.

 `begin_tree` builds into a table nothing is looking at, so a snapshot that turns
 out to be malformed halfway through costs the caller nothing — a panel that half
 disappeared because one colour was wrong is worse than one that did not change.
*>
fn void a_snapshot_that_fails_leaves_the_live_one_standing() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		one_node(renderer, { .kind = three::UiNodeKind.LABEL, .key = "kept", .text = "one", .has_text = true });
		void* was = (void*)renderer.ui.tree;

		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		renderer.ui.push_node({ .kind = three::UiNodeKind.COLUMN }, -1)!!;
		// A parent index naming a node this build does not have — what a malformed
		// child list arrives as.
		test::@check(
			!@ok(renderer.ui.push_node({ .kind = three::UiNodeKind.LABEL }, 7)),
			"a child under a parent that does not exist was accepted"
		);
		renderer.ui.abandon_tree();

		test::@check((void*)renderer.ui.tree == was, "the abandoned build replaced the live tree");
		test::@check(@ok(renderer.ui.node_for("kept")), "the live tree lost its keys");
	};
}

// ============================================================================
// The pointer, and who takes it
// ============================================================================

<*
 A click reaches the node that was pressed, and only that one.

 cui's widget callbacks are handed the `Ui` and nothing else — deliberately,
 because cui has no app type to name — so which button fired is recovered from
 the interactivity state rather than passed in. Two buttons is the smallest tree
 that can tell a working recovery from one that always answers with the first
 node it finds.
*>
fn void a_click_reaches_the_node_that_was_pressed() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		Heard heard;

		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint row = renderer.ui.push_node({ .kind = three::UiNodeKind.ROW, .gap = 10.0 }, -1)!!;
		uint first = renderer.ui.push_node(
			{ .kind = three::UiNodeKind.BUTTON, .size = { 40, 20 }, .on_click = true },
			(int)row
		)!!;
		uint second = renderer.ui.push_node(
			{ .kind = three::UiNodeKind.BUTTON, .size = { 40, 20 }, .on_click = true },
			(int)row
		)!!;
		renderer.ui.commit_tree();
		renderer.ui.on_event(&listen, &heard);

		// A frame first: hit testing reads the absolute origins the emit pass
		// stores, and nothing has been emitted until something has been drawn.
		image::Image shot = renderer.capture()!!;
		shot.free();

		// The second button starts at 50 across, because the row is 40 + a gap of
		// 10 — and the row is at the origin, because nothing positioned it.
		point(renderer, 60, 10, true);
		point(renderer, 60, 10, false);

		test::@check(heard.calls == 1, "a click on one of two buttons fired %d times", heard.calls);
		test::@check(heard.node == second, "the click was attributed to node %d rather than %d", heard.node, second);
		test::@check(heard.kind == three::UiEventKind.CLICK, "the event was not a click");
		test::@check(first != second, "the two buttons were the same node");
	};
}

<*
 The interface takes the pointer where a widget is, and nowhere else.

 This is `plan.md` §5's hard part in one assertion: a click on a button must not
 also shoot the gun, and a caption over the viewport must not become a dead zone.
 Both halves are the same flag read at two places on the frame.
*>
fn void the_interface_takes_the_pointer_only_where_a_widget_is() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		one_node(renderer, { .kind = three::UiNodeKind.BUTTON, .size = { 40, 20 }, .on_click = true });

		image::Image shot = renderer.capture()!!;
		shot.free();

		point(renderer, 10, 10, false);
		test::@check(renderer.ui.wants_pointer, "the pointer over a button did not reach the interface");

		point(renderer, 150, 100, false);
		test::@check(!renderer.ui.wants_pointer, "the pointer off every widget was still taken by the interface");
	};
}

<*
 Decoration is transparent, and a container that fills the frame is decoration.

 cui hit-tests the deepest rect containing the point whether or not its widget
 handles anything, so every one of these — the two floors of the fixed root, an
 `anchored`, a `label`, a `rect` — would turn the whole window into a dead zone
 if it were not opted out. A panel that genuinely wants to block says `solid`,
 and the last check is that saying so works.
*>
fn void a_full_frame_layer_of_decoration_lets_the_pointer_through() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint anchored = renderer.ui.push_node({ .kind = three::UiNodeKind.ANCHORED }, -1)!!;
		renderer.ui.push_node(
			{ .kind = three::UiNodeKind.LABEL, .text = "hp 100", .text_size = 16.0, .has_text = true },
			(int)anchored
		)!!;
		renderer.ui.commit_tree();

		image::Image shot = renderer.capture()!!;
		shot.free();

		point(renderer, 20, 14, false);
		test::@check(!renderer.ui.wants_pointer, "a caption over the viewport became a dead zone");

		// The modal scrim's way back in.
		one_node(
			renderer,
			{ .kind = three::UiNodeKind.RECT, .color = { 0.0, 0.0, 0.0, 0.5 }, .solid = true }
		);
		image::Image again = renderer.capture()!!;
		again.free();

		point(renderer, 20, 14, false);
		test::@check(renderer.ui.wants_pointer, "a solid layer did not block the pointer");
	};
}

<*
 A drag on the scene is not interrupted by passing over a panel.

 The half of the arbitration that lives in `main.c3` rather than here — the loop
 checks `controls.dragging` as well as `wants_pointer` — but the state it reads is
 this one, and a `captured` that did not survive the pointer leaving the widget
 would break the mirror-image case. So this checks the cui half: a press consumed
 by a widget keeps the widget while the pointer walks off it.
*>
fn void a_widget_keeps_a_drag_that_leaves_it() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		one_node(
			renderer,
			{ .kind = three::UiNodeKind.BUTTON, .size = { 60, 24 }, .on_click = true }
		);

		image::Image shot = renderer.capture()!!;
		shot.free();

		point(renderer, 30, 12, true);
		test::@check(renderer.ui.wants_pointer, "a press on the button was not taken");

		// Off the widget entirely, with the pointer still down. Nothing is hovered
		// now, so this is `captured` answering and nothing else.
		point(renderer, 180, 110, true);
		test::@check(renderer.ui.wants_pointer, "the drag was dropped when the pointer left the widget");

		point(renderer, 180, 110, false);
		test::@check(!renderer.ui.wants_pointer, "the capture outlived the release");
	};
}

<*
 Typing goes to a focused field and not to WASD.

 `wants_keys` is the whole of it, and it is what `drive_window` reads to decide
 whether the script's key latch sees this frame at all.
*>
fn void a_focused_field_takes_the_keyboard() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		one_node(renderer, { .kind = three::UiNodeKind.TEXTFIELD, .key = "name", .size = { 120, 0 } });

		image::Image shot = renderer.capture()!!;
		shot.free();

		test::@check(!renderer.ui.wants_keys, "the keyboard was taken before anything was focused");

		// A left press is what assigns focus, here as in every other toolkit.
		point(renderer, 40, 10, true);
		point(renderer, 40, 10, false);
		test::@check(renderer.ui.wants_keys, "a click on a text field did not take the keyboard");
	};
}

// ============================================================================
// The drawing ops
// ============================================================================

<*
 All seven primitives, drawn and silent.

 A pixel check on each one would be a check on the SDF rather than on the
 binding, and cui has those. What is worth asserting here is that every op
 reaches a `Painter` call with arguments it accepts — a negative size is a
 contract violation in `Painter.rect`, and any build but `--safe=no` turns a
 script's typo into a panic inside the renderer if the binding does not clamp
 first.
*>
fn void every_drawing_op_reaches_the_painter() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.02, 0.02, 0.02, 1.0 };

		image::Image bare = renderer.capture()!!;
		defer bare.free();

		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint node = renderer.ui.push_node({ .kind = three::UiNodeKind.DRAW }, -1)!!;
		Vec4 white = { 1.0, 1.0, 1.0, 1.0 };
		renderer.ui.push_op(node, { .kind = three::UiOpKind.RECT, .at = { 4, 4 }, .to = { 40, 10 }, .color = white });
		renderer.ui.push_op(node, { .kind = three::UiOpKind.CIRCLE, .at = { 60, 10 }, .radius = 6, .color = white });
		renderer.ui.push_op(
			node,
			{ .kind = three::UiOpKind.ELLIPSE, .at = { 90, 10 }, .to = { 10, 5 }, .color = white }
		);
		renderer.ui.push_op(
			node,
			{ .kind = three::UiOpKind.LINE, .at = { 110, 6 }, .to = { 140, 6 }, .thickness = 2, .color = white }
		);
		renderer.ui.push_op(
			node,
			{
				.kind = three::UiOpKind.ARC,
				.at = { 160, 12 },
				.radius = 8,
				.start = 0,
				.sweep = 3.0,
				.thickness = 3,
				.color = white,
			}
		);
		renderer.ui.push_op(
			node,
			{ .kind = three::UiOpKind.TEXT, .at = { 4, 20 }, .text = "ops", .size = 14, .color = white }
		);
		renderer.ui.push_op(
			node,
			{ .kind = three::UiOpKind.SHADOW, .at = { 60, 24 }, .to = { 30, 8 }, .blur = 6, .color = white }
		);
		// A negative size, which is what a script's arithmetic produces on the
		// frame a value goes through zero. Clamped rather than refused.
		renderer.ui.push_op(
			node,
			{ .kind = three::UiOpKind.RECT, .at = { 4, 34 }, .to = { -20, -5 }, .color = white }
		);
		renderer.ui.commit_tree();

		if (renderer.gpu.validation) renderer.gpu.begin_capture();
		image::Image drawn = renderer.capture()!!;
		defer drawn.free();

		test::@check(lit_pixels(&drawn) > lit_pixels(&bare) + 200, "the ops drew nothing");

		if (renderer.gpu.validation)
		{
			String errors = renderer.gpu.sink.errors.str_view();
			renderer.gpu.end_capture();
			test::@check(errors.len == 0, "the drawing ops produced validation errors: %s", errors);
		}
	};
}

<*
 A patched op list replaces the old one rather than appending to it.

 The verb a crosshair and a health bar use every time a value moves, so it must
 not grow: `reset_list` frees the strings only the list was holding, and the
 label the widget is still borrowing is in the other one.
*>
fn void patching_a_draw_list_replaces_it() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		renderer.clear = { 0.02, 0.02, 0.02, 1.0 };

		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint node = renderer.ui.push_node({ .kind = three::UiNodeKind.DRAW, .key = "hud" }, -1)!!;
		renderer.ui.push_op(
			node,
			{
				.kind = three::UiOpKind.RECT,
				.at = { 4, 4 },
				.to = { 100, 30 },
				.color = { 1.0, 1.0, 1.0, 1.0 },
			}
		);
		renderer.ui.commit_tree();

		image::Image wide = renderer.capture()!!;
		defer wide.free();

		uint at = renderer.ui.node_for("hud")!!;
		renderer.ui.reset_list(at);
		renderer.ui.push_op(
			at,
			{ .kind = three::UiOpKind.RECT, .at = { 4, 4 }, .to = { 10, 4 }, .color = { 1.0, 1.0, 1.0, 1.0 } }
		);
		renderer.ui.relist(at);

		image::Image narrow = renderer.capture()!!;
		defer narrow.free();

		test::@check(
			lit_pixels(&narrow) < lit_pixels(&wide),
			"the replaced draw list drew as much as the old one: %d against %d",
			lit_pixels(&narrow),
			lit_pixels(&wide)
		);
		test::@check(renderer.ui.nodes[at].ops.len() == 1, "the op list grew instead of being replaced");
	};
}

// ============================================================================
// The JavaScript binding
// ============================================================================

macro @with_ui_js(; @body(three::Renderer* renderer, three::JsRuntime* run))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	@body(&renderer, &runtime);
}

<*
 A tree written in JavaScript arrives as elements.

 The whole crossing in one check: `js/prelude/ui.js` normalises, `bind_ui.c3`
 walks it by name, and `render/ui.c3` builds it. Six nodes because the count is
 what catches a child list read as a single node or dropped entirely.
*>
fn void a_script_builds_a_tree() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			three.ui.set({
				type: 'anchored', h: 'start', v: 'start', margin: 12,
				child: { type: 'column', gap: 8, children: [
					{ key: 'fps', type: 'label', text: '60 fps', color: 0xffffff },
					{ type: 'row', gap: 6, children: [
						{ type: 'button', text: 'Reset', onClick: () => {} },
						{ type: 'checkbox', label: 'Wireframe', checked: true, onChange: () => {} },
					]},
				]},
			});
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::@check(renderer.ui.nodes.len() == 6, "the tree came over as %d nodes", renderer.ui.nodes.len());
		test::@check(@ok(renderer.ui.node_for("fps")), "the key did not cross");
	};
}

<*
 A type nobody has heard of is a message naming it.

 The reason the normalising is in JavaScript at all: the language that can
 enumerate a node's properties is the one that can say what was wrong with it,
 and a panel that quietly fails to appear is the alternative.
*>
fn void an_unknown_node_type_is_refused_by_name() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult result = run.run(`three.ui.set({ type: 'accordion' });`);
		defer result.free();

		test::@check(!result.ok, "a type that does not exist was accepted");
		test::@check(
			result.error.contains("accordion") && result.error.contains("checkbox"),
			"the message did not name the type and the alternatives: %s",
			result.error
		);
	};
}

<*
 A handler that is not a function, and an async one, are both refused.

 The async half matters more than it looks: a handler runs inside the frame and
 the frame does not wait, so an async one returns before it has done anything and
 the symptom is a button that appears to work and does not.
*>
fn void a_handler_has_to_be_a_synchronous_function() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult bad = run.run(`three.ui.set({ type: 'button', onClick: 'nope' });`);
		defer bad.free();
		test::@check(!bad.ok, "a string was accepted as a click handler");

		three::RunResult waited = run.run(`three.ui.set({ type: 'button', onClick: async () => {} });`);
		defer waited.free();
		test::@check(!waited.ok, "an async click handler was accepted");
		test::@check(
			waited.error.contains("synchronous"),
			"the message did not say why: %s",
			waited.error
		);
	};
}

<*
 `patch` writes one value, and a key that names nothing says so.
*>
fn void a_script_patches_by_key() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			three.ui.set({ key: 'fps', type: 'label', text: '60 fps', color: 0xffffff });
			three.ui.patch('fps', { text: '144 fps' });
		`);
		defer built.free();
		test::@check(built.ok, "the script ran: %s", built.error);

		uint at = renderer.ui.node_for("fps")!!;
		String text = renderer.ui.nodes[at].element.widget_as(cui::widgets::Label).text;
		test::@check(text == "144 fps", "the patch did not reach the label: '%s'", text);

		three::RunResult missing = run.run(`three.ui.patch('nope', { text: 'x' });`);
		defer missing.free();
		test::@check(!missing.ok, "patching a key nothing carries was accepted");
		test::@check(missing.error.contains("nope"), "the message did not name the key: %s", missing.error);
	};
}

<*
 `measure` answers two numbers a script can position with.
*>
fn void a_script_measures_text() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const [w, h] = three.ui.measure('hello', { size: 20 });
			return [w > 10, h > 10, w > h].join(',');
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::eq(result.value, `"true,true,true"`);
	};
}

<*
 `three.ui.draw(ops)` is one node filling the frame, and `clear` takes it away.
*>
fn void a_script_draws_a_screen_space_layer() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult drawn = run.run(`
			three.ui.draw([
				{ op: 'arc', center: [100, 60], radius: 40, start: -1.57, sweep: 3, thickness: 8, color: 0x33dd66 },
				{ op: 'text', at: [10, 10], text: 'hp', size: 16, color: 0xffffff },
			]);
		`);
		defer drawn.free();
		test::@check(drawn.ok, "the script ran: %s", drawn.error);
		test::@check(renderer.ui.nodes.len() == 1, "draw made %d nodes", renderer.ui.nodes.len());
		test::@check(renderer.ui.nodes[0].ops.len() == 2, "the ops did not cross");

		three::RunResult cleared = run.run(`three.ui.clear();`);
		defer cleared.free();
		test::@check(cleared.ok, "the clear ran: %s", cleared.error);
		test::@check(renderer.ui.nodes.len() == 0, "the interface survived a clear");
	};
}

<*
 A handler that rebuilds the interface is held until the dispatch is over.

 The one reentrancy rule cui states: a handler may unmount from its own subtree
 and must not restructure unrelated parts of the tree — and it is called from
 inside `process_input`, before the flush. So a `set` from a click is retained
 and applied by `flush_ui`, which the window loop calls the moment
 `UiLayer.feed` returns.

 Checked in three parts, because "it worked" and "it was deferred" are different
 claims and only the middle one would catch a guard that was never armed.
*>
fn void a_set_from_a_handler_waits_for_the_dispatch_to_end() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			three.ui.set({
				type: 'button', size: [60, 24], key: 'go',
				onClick: () => three.ui.set({ type: 'label', key: 'done', text: 'clicked', color: 0xffffff }),
			});
		`);
		defer built.free();
		test::@check(built.ok, "the script ran: %s", built.error);

		// Hit testing reads the origins the emit pass stores.
		image::Image shot = renderer.capture()!!;
		shot.free();

		point(renderer, 30, 12, true);
		point(renderer, 30, 12, false);

		test::@check(@ok(renderer.ui.node_for("go")), "the tree was rebuilt from inside the dispatch");
		test::@check(!@ok(renderer.ui.node_for("done")), "the new tree was installed while cui was walking the old one");

		run.flush_ui();

		test::@check(@ok(renderer.ui.node_for("done")), "the held tree was never applied");
		test::@check(!@ok(renderer.ui.node_for("go")), "the old tree was still standing after the flush");
	};
}

<*
 A widget callback reaches the script's own function.

 The end of the chain the C3 dispatch test starts: cui calls a shim in
 `render/ui.c3`, which finds the node, which is an index into the handler table
 `bind_ui.c3` holds, which is the JavaScript function the snapshot carried.
*>
fn void a_click_reaches_the_scripts_handler() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			globalThis.clicks = 0;
			three.ui.set({ type: 'button', size: [60, 24], onClick: () => { globalThis.clicks++; } });
		`);
		defer built.free();
		test::@check(built.ok, "the script ran: %s", built.error);

		image::Image shot = renderer.capture()!!;
		shot.free();

		point(renderer, 30, 12, true);
		point(renderer, 30, 12, false);
		// A press that lands off the button fires nothing.
		point(renderer, 180, 110, true);
		point(renderer, 180, 110, false);

		three::RunResult counted = run.run(`return globalThis.clicks;`);
		defer counted.free();
		test::eq(counted.value, "1");
	};
}

<*
 A reload leaves nothing pointing at the context that went.

 The layer belongs to the `Renderer` and outlives every `JsRuntime` built against
 it, so a context that closed while holding widget callbacks would leave the
 interface holding a listener into freed memory — and the first click after a
 reload would find it. `JsRuntime.close` takes the tree down and unbinds the
 listener; this is the click that would otherwise crash.
*>
fn void a_closed_context_leaves_no_interface_behind_it() @test
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, W, H)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime first;
	first.open(&renderer.pass, &renderer)!!;
	three::RunResult built = first.run(`
		three.ui.set({ type: 'button', size: [60, 24], onClick: () => {} });
	`);
	built.free();
	test::@check(renderer.ui.nodes.len() == 1, "the first context did not build a tree");

	// What `reload` does: the old context goes, a new one is opened against the
	// same renderer.
	first.close();
	test::@check(renderer.ui.nodes.len() == 0, "the interface outlived the context that built it");

	three::JsRuntime second;
	second.open(&renderer.pass, &renderer)!!;
	defer second.close();

	image::Image shot = renderer.capture()!!;
	shot.free();

	// Straight at where the button was. Nothing should be listening.
	point(&renderer, 30, 12, true);
	point(&renderer, 30, 12, false);

	three::RunResult after = second.run(`return 1;`);
	defer after.free();
	test::@check(after.ok, "the new context did not run: %s", after.error);
}

<*
 A tree replaced over and over stays a tree.

 The third rebuild is the interesting one: it is the first that draws elements
 off cui's free list, and a recycled element arrives with its child list zeroed.
 A zeroed List takes the TEMP allocator on its first push, so its children lived
 in memory the `@pool()` around `three.ui.set` handed back — a dangling child
 list that the next build walk read. Six rounds because two of them would pass
 either way.
*>
fn void a_tree_rebuilt_over_and_over_keeps_its_children() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		for (int i = 0; i < 6; i++)
		{
			three::RunResult result = run.run(`
				three.ui.set({
					type: 'anchored', h: 'center', v: 'center',
					child: { type: 'column', gap: 4, children: [
						{ type: 'label', text: 'one' },
						{ type: 'label', text: 'two' },
					]},
				});
			`);
			bool ok = result.ok;
			result.free();
			test::@check(ok, "rebuild %d did not run", i);

			// The flush is where it showed: the build walk reads the child list
			// the pool has already taken back.
			image::Image shot = renderer.capture()!!;
			shot.free();

			test::@check(
				renderer.ui.nodes.len() == 4,
				"rebuild %d left %d nodes",
				i,
				renderer.ui.nodes.len()
			);
		}
	};
}

<*
 A scroll with nothing in it yet is not a crash.

 cui's Scroll asserts that it has exactly one child, and "the list has not
 loaded" is an ordinary thing for a script to describe. So `ui.js` gives an
 empty one an empty stack to scroll — the alternative is a contract violation
 taking the process down, in every build but `--safe=no`, for a tree that is
 merely early.
*>
fn void a_scroll_with_nothing_in_it_is_not_a_panic() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult result = run.run(`three.ui.set({ type: 'scroll', size: [80, 40] });`);
		defer result.free();
		test::@check(result.ok, "the script ran: %s", result.error);

		image::Image shot = renderer.capture()!!;
		shot.free();

		// Two: the scroll, and the empty stack `ui.js` gave it to scroll.
		test::@check(renderer.ui.nodes.len() == 2, "the scroll came over as %d nodes", renderer.ui.nodes.len());
	};
}

// ============================================================================
// The class layer
// ============================================================================

<*
 A widget class becomes the interface, and the panel it describes hugs it.

 Three claims in one build, because they are one build. The tree arrives — a
 `Panel` is a wrapping stack, a background and a padded column, so the count is
 what says it expanded rather than crossing as a type nothing knows. The key a
 node carries is the WIDGET'S id and the name, which is what stops two widgets
 that both called something `card` from addressing each other's. And the card is
 shorter than the frame, which is the whole of `UiWrap`: a `Stack` fills, and a
 panel that filled would be the size of the window with two rows in the corner
 of it.
*>
fn void a_widget_class_becomes_the_interface() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const { Panel, Label, Button } = three.ui;
			class Hud extends three.Widget {
				constructor() { super(); this.score = 0; }
				render() {
					return new Panel({ key: 'card', at: 'top-left', margin: 12, width: 150 },
						new Label('score ' + this.score),
						new Button('reset', () => { this.score = 0; }),
					);
				}
			}
			Hud.mount();
			return three.Widget.count;
		`);
		defer result.free();

		test::@check(result.ok, "the script ran: %s", result.error);
		test::eq(result.value, `1`);

		image::Image shot = renderer.capture()!!;
		shot.free();

		// The root stack, the anchored, the card's own stack, its background,
		// its padding, its column, and the two rows.
		test::@check(renderer.ui.nodes.len() == 8, "the widget came over as %d nodes", renderer.ui.nodes.len());

		uint at = renderer.ui.node_for("0#card")!!;
		float height = renderer.ui.nodes[at].element.size.y;
		test::@check(height > 0 && height < (float)H, "the card is %f tall in a %d frame", height, H);
	};
}

<*
 A value changed is a patch; the shape changed is a rebuild.

 The reason the class layer exists: `render()` is written as though it ran every
 frame, and what reaches the host is the difference. So the check is element
 identity across a score going up — nothing may be rebuilt — and then the same
 check inverted across a row being added, because that one has to be.
*>
fn void a_widget_patches_what_changed_and_rebuilds_what_moved() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const { Panel, Label } = three.ui;
			class Hud extends three.Widget {
				constructor() { super(); this.score = 0; this.rows = ['a']; }
				render() {
					return new Panel({ at: 'top-left', margin: 8, width: 150 },
						new Label('score ' + this.score),
						...this.rows.map(r => new Label(r)),
					);
				}
			}
			globalThis.hud = Hud.mount();
		`);
		defer built.free();
		test::@check(built.ok, "the script ran: %s", built.error);

		sz count = renderer.ui.nodes.len();
		void*[8] was;
		for (sz i = 0; i < count && i < 8; i++) was[i] = (void*)renderer.ui.nodes[i].element;

		three::RunResult valued = run.run(`hud.score = 41; three.ui.flush();`);
		defer valued.free();
		test::@check(valued.ok, "the value change ran: %s", valued.error);

		test::@check(renderer.ui.nodes.len() == count, "a changed number changed the node count");
		bool rebuilt;
		for (sz i = 0; i < count && i < 8; i++)
		{
			if ((void*)renderer.ui.nodes[i].element != was[i]) rebuilt = true;
		}
		test::@check(!rebuilt, "a changed number rebuilt the tree instead of patching it");

		three::RunResult grown = run.run(`hud.rows.push('b'); hud.update(); three.ui.flush();`);
		defer grown.free();
		test::@check(grown.ok, "the structural change ran: %s", grown.error);

		test::@check(
			renderer.ui.nodes.len() == count + 1,
			"a new row left %d nodes where %d were expected",
			renderer.ui.nodes.len(),
			count + 1
		);
	};
}

<*
 Two widgets are two floors of one interface, and unmounting one leaves the other.

 What a HUD and a pause screen are: mounting the second does not restate the
 first, and taking it away does not take the first's labels with it — which is
 the failure the class layer was written to remove. `examples/range.js` pauses by
 rebuilding the whole tree by hand, and the bug that cost was a pause screen that
 forgot to carry the HUD's keys.
*>
fn void widgets_stack_and_come_apart_one_at_a_time() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const { Panel, Label } = three.ui;
			class Hud extends three.Widget {
				render() { return new Panel({ key: 'hud', at: 'top-left', margin: 8 }, new Label('hud')); }
			}
			class Pause extends three.Widget {
				static layer = 1;
				render() { return new Panel({ key: 'pause', at: 'center' }, new Label('paused')); }
			}
			Hud.mount();
			globalThis.pause = Pause.mount();
			return three.Widget.count;
		`);
		defer built.free();
		test::@check(built.ok, "the script ran: %s", built.error);
		test::eq(built.value, `2`);
		test::@check(@ok(renderer.ui.node_for("0#hud")), "the hud's key did not cross");
		test::@check(@ok(renderer.ui.node_for("1#pause")), "the pause screen's key did not cross");

		three::RunResult gone = run.run(`pause.unmount(); return three.Widget.count;`);
		defer gone.free();
		test::@check(gone.ok, "the unmount ran: %s", gone.error);
		test::eq(gone.value, `1`);

		test::@check(@ok(renderer.ui.node_for("0#hud")), "unmounting the pause screen took the hud with it");
		test::@check(!@ok(renderer.ui.node_for("1#pause")), "the pause screen is still in the tree");
	};
}

<*
 `three.ui.set` while a widget is mounted is refused by name.

 One interface and two doors onto it: the class layer rewrites the whole tree
 whenever anything changes, so a `set` beside it would be overwritten on the next
 frame and nothing would say so. The same reason a patch to a key nothing carries
 throws rather than doing nothing.
*>
fn void the_two_doors_onto_the_interface_are_exclusive() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			class Bare extends three.Widget {
				render() { return new three.ui.Label('here'); }
			}
			Bare.mount();
			three.ui.set({ type: 'label', text: 'and here' });
		`);
		defer result.free();

		test::@check(!result.ok, "a set beside a mounted widget was accepted");
		test::@check(
			result.error.contains("unmountAll"),
			"the message did not say how to have it both ways: %s",
			result.error
		);

		three::RunResult after = run.run(`
			three.Widget.unmountAll();
			three.ui.set({ type: 'label', text: 'and here' });
			return three.Widget.count;
		`);
		defer after.free();
		test::@check(after.ok, "the set was still refused after unmountAll: %s", after.error);
		test::eq(after.value, `0`);
	};
}

<*
 A click reaches a widget's method, and what it changed is a patch.

 The whole loop in one test: cui dispatches into the stable function the class
 layer registered, that finds the handler this render put there, `this` is the
 widget, the field it wrote marks it dirty, and the re-render writes one label
 without rebuilding the button that was just pressed. A dispatcher that was a
 fresh closure per render would make every click a rebuild, which is the failure
 this indirection exists to prevent and the reason the element identity is
 checked rather than only the text.
*>
fn void a_click_reaches_a_widget_and_lands_as_a_patch() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const { Column, Label, Button } = three.ui;
			class Counter extends three.Widget {
				constructor() { super(); this.n = 0; }
				bump() { this.n += 1; }
				render() {
					return new Column({ gap: 0 },
						new Button('go', () => this.bump(), { size: [60, 24] }),
						new Label(String(this.n), { key: 'n' }),
					);
				}
			}
			Counter.mount();
		`);
		defer built.free();
		test::@check(built.ok, "the script ran: %s", built.error);

		image::Image shot = renderer.capture()!!;
		shot.free();

		sz count = renderer.ui.nodes.len();
		void*[8] was;
		for (sz i = 0; i < count && i < 8; i++) was[i] = (void*)renderer.ui.nodes[i].element;

		point(renderer, 30, 12, true);
		point(renderer, 30, 12, false);

		three::RunResult after = run.run(`three.ui.flush();`);
		defer after.free();
		test::@check(after.ok, "the flush ran: %s", after.error);

		uint at = renderer.ui.node_for("0#n")!!;
		String text = renderer.ui.nodes[at].element.widget_as(cui::widgets::Label).text;
		test::@check(text == "1", "the click did not reach the widget: the label reads '%s'", text);

		bool rebuilt;
		for (sz i = 0; i < count && i < 8; i++)
		{
			if ((void*)renderer.ui.nodes[i].element != was[i]) rebuilt = true;
		}
		test::@check(!rebuilt, "the click rebuilt the tree instead of patching one label");
	};
}

<*
 Typing into a widget's field reaches the widget and is not written back at it.

 The one place a re-render could be actively harmful. `render()` names the text
 the field is to show, so the obvious implementation diffs what was typed against
 what the last render said and patches the difference back — and writing a text
 field's text moves the caret to the end of it, so a name edited in the middle
 would jump under somebody's fingers. The value the event carried is folded into
 the last render before the handler runs, so the diff finds nothing; the check is
 that the widget saw the text AND that nothing was rebuilt to show it.
*>
fn void typing_into_a_widget_is_not_echoed_back_at_it() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const { TextField } = three.ui;
			class Form extends three.Widget {
				constructor() { super(); this.name = ''; }
				render() {
					return new TextField({ key: 'name', size: [120, 0], text: this.name, onChange: t => { this.name = t; } });
				}
			}
			globalThis.form = Form.mount();
		`);
		defer built.free();
		test::@check(built.ok, "the script ran: %s", built.error);

		image::Image shot = renderer.capture()!!;
		shot.free();

		uint at = renderer.ui.node_for("0#name")!!;
		void* was = (void*)renderer.ui.nodes[at].element;

		point(renderer, 40, 10, true);
		point(renderer, 40, 10, false);
		renderer.ui.feed({ .inside = true, .x = 40, .y = 10 }, {}, "ada", 16.0);

		// The caret put back where somebody editing a name would have left it:
		// two in, not at the end. This is what a patch would destroy, and
		// nothing else here can see the difference.
		KeyBits back;
		back.set(c3w::EventKey.LEFT_ARROW);
		renderer.ui.feed({ .inside = true, .x = 40, .y = 10 }, back, "", 16.0);
		renderer.ui.feed({ .inside = true, .x = 40, .y = 10 }, {}, "", 16.0);

		three::RunResult typed = run.run(`three.ui.flush(); return form.name;`);
		defer typed.free();
		test::@check(typed.ok, "the flush ran: %s", typed.error);
		test::eq(typed.value, `"ada"`);

		usz caret = renderer.ui.nodes[at].element.widget_as(cui::widgets::TextField).caret;
		test::@check(caret == 2, "the re-render moved the caret to %d", caret);

		String text = renderer.ui.nodes[at].element.widget_as(cui::widgets::TextField).value();
		test::@check(text == "ada", "the field lost what was typed: '%s'", text);
		test::@check(
			(void*)renderer.ui.nodes[at].element == was,
			"typing rebuilt the field instead of leaving it alone"
		);
	};
}

<*
 An open dropdown covers what is under it, and takes the click.

 cui builds a popup as a child of the widget that owns it — there is no overlay
 layer in the core — so without `Element.raised` the list lands in the Select's
 slot in the paint order and every field BELOW it in the same form draws over it.
 The symptom is a dropdown that appears behind the text box under it and answers
 no clicks where they overlap, which is what a person reports as a z-index.

 Both halves are checked because they are two walks: `Ui.emit` decides what is
 drawn on top and `Ui.hit_test_element` decides what is clicked, and a fix to one
 of them alone is a list that looks right and cannot be used.
*>
fn void an_open_dropdown_paints_and_hits_over_what_is_under_it() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			const { Column, Select, Rect } = three.ui;
			class Form extends three.Widget {
				constructor() { super(); this.picked = -1; }
				render() {
					return new Column({ gap: 0 },
						new Select(['one', 'two', 'three'], 0, i => { this.picked = i; }),
						new Rect({ color: [1, 0, 0], size: [120, 60] }),
					);
				}
			}
			globalThis.form = Form.mount();
		`);
		defer built.free();
		test::@check(built.ok, "the script ran: %s", built.error);

		image::Image closed = renderer.capture()!!;
		defer closed.free();
		test::@check(red_at(&closed, 20, 40), "the rect under the dropdown is not where the test thinks");

		// The press is what opens it; the release is the other half of the click.
		point(renderer, 10, 13, true);
		point(renderer, 10, 13, false);

		image::Image open = renderer.capture()!!;
		defer open.free();
		test::@check(!red_at(&open, 20, 40), "the open list drew under the rect below it");

		// The same point, now that the list is over it.
		point(renderer, 20, 40, true);
		point(renderer, 20, 40, false);

		three::RunResult picked = run.run(`three.ui.flush(); return form.picked;`);
		defer picked.free();
		test::@check(picked.ok, "the flush ran: %s", picked.error);
		test::@check(
			picked.value != "-1",
			"the click reached the rect under the list instead of the list: picked %s",
			picked.value
		);
	};
}
