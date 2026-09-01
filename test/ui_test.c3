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
import std::io::path;

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

<*
 How many pixels of two frames differ.

 `lit_pixels` counts a band in the top-left corner, which is where the overlay
 goes and is not where anything else does. This is the question to ask about a
 panel that lands in the middle of the frame and whose colours nobody wants to
 name: it drew, or the frame is the same frame.
*>
fn uint differing(image::Image* a, image::Image* b)
{
	sz bpp = a.bytes_per_pixel();
	uint count = 0;
	sz pixels = (sz)a.width * (sz)a.height;
	for (sz i = 0; i < pixels; i++)
	{
		if (a.pixels[i * bpp] != b.pixels[i * bpp]) count++;
	}
	return count;
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
	usz item;
	// The pointer half. Kept as two floats rather than a Vec2 so a failure
	// message can name the axis that was wrong.
	three::UiPointerPhase phase;
	// The last phase that was not a move. One `feed` dispatches the wheel, then
	// the button edges, then the move — in that order and all in the frame the
	// test called `point` for — so the edge a test is asking about is never the
	// last thing it heard.
	three::UiPointerPhase edge;
	float at_x;
	float at_y;
	uint buttons;
	uint modifiers;
	float wheel;
	// Counted apart from `calls`, because a pointer fires on every frame it is
	// over the node and the negative test is about this number being zero while
	// the interface as a whole is perfectly busy.
	uint pointers;
	// The event's text, copied. `UiEvent.text` is the widget's own buffer or a
	// temporary the frame's pool takes back, so a test that kept the view would
	// be reading whatever the next frame wrote there.
	char[256] spoken;
	usz spoken_len;
}

fn String Heard.said(&self) => (String)self.spoken[:self.spoken_len];

fn void listen(void* host, uint node, three::UiEvent event)
{
	Heard* heard = (Heard*)host;
	heard.calls++;
	heard.node = node;
	heard.kind = event.kind;
	heard.flag = event.flag;
	heard.value = event.value;
	heard.index = event.index;
	heard.item = event.item;
	heard.phase = event.phase;
	heard.at_x = event.at.x;
	heard.at_y = event.at.y;
	heard.buttons = event.buttons;
	heard.modifiers = event.modifiers;
	if (event.kind == three::UiEventKind.POINTER)
	{
		heard.pointers++;
		// The wheel travels with its own edge for the same reason `edge` exists:
		// the move that follows it in the same frame carries no delta.
		if (event.phase != three::UiPointerPhase.MOVE)
		{
			heard.edge = event.phase;
			heard.wheel = event.value;
		}
	}
	usz room = (usz)heard.spoken.len;
	heard.spoken_len = event.text.len < room ? event.text.len : room;
	if (heard.spoken_len > 0) heard.spoken[:heard.spoken_len] = event.text[:heard.spoken_len];
}

<*
 A window with room for cui's application widgets to lay out in.

 The 200x120 above is a HUD's worth of frame, and a centred `ConfirmDialog` is
 380 wide before its insets and a menu bar is as wide as its titles. Measured
 against a frame that small every one of them comes out clipped, and the test
 would be asserting things about the clipping rather than about the widget.
*>
macro @with_panel(; @body(three::Renderer* renderer))
{
	vk::Instance instance = three::create_instance(true, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 520, 400, validate: true)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	@body(&renderer);
}

// One frame, so the emit pass writes the absolute origins every hit test reads.
fn void frame(three::Renderer* renderer)
{
	image::Image shot = renderer.capture()!!;
	shot.free();
}

// A press and a release in the middle of an element cui has stamped with a name.
// `MenuBar` stamps every title and item, and `Dialog` stamps its close glyph,
// which is what lets these tests click what a person would click rather than a
// pair of numbers that stops being right the moment a font changes.
fn bool click_id(three::Renderer* renderer, String id)
{
	cui::Element*? found = renderer.ui.ui.find_id(id);
	if (catch found) return false;
	float x = found.absolute.x + found.size.x * 0.5f;
	float y = found.absolute.y + found.size.y * 0.5f;
	point(renderer, x, y, true);
	point(renderer, x, y, false);
	return true;
}

<*
 The last element of a subtree, walking down the last child each time.

 `ConfirmDialog` paints its two buttons with one widget, and that widget is
 `@local` to cui — there is no type to name and no id stamped on it. It is
 always the last thing built under the panel, though, which is the same fact
 the layout relies on: the answers are what a dialog ends with.
*>
fn cui::Element* last_leaf(cui::Element* from)
{
	cui::Element* walk = from;
	while (walk.children.len() > 0) walk = walk.children[walk.children.len() - 1];
	return walk;
}

// A tree of one node, which is what most of these want.
fn uint one_node(three::Renderer* renderer, three::UiNodeSpec spec)
{
	renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
	uint at = renderer.ui.push_node(spec, -1)!!;
	renderer.ui.commit_tree();
	return at;
}

// One frame of wheel at a place in the image, nothing pressed.
fn void wheel(three::Renderer* renderer, float x, float y, float delta)
{
	renderer.ui.feed({ .inside = true, .x = x, .y = y, .scroll = delta }, {}, "", 16.0);
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
// The pointer on a `draw` node
// ============================================================================

<*
 A painting is handed the whole pointer, in its own coordinates.

 The half of `plan.md` §1 that was still true: a script could paint anything and
 could not be told where the pointer was, so it polled `three.input.pointer` —
 which is the WINDOW's, in window coordinates, and knows nothing about panes,
 menus or modals. This is the same pointer delivered through the hit test, so
 the numbers are the node's own and the drag survives leaving it.

 The node is put under a `padding` on purpose. A local position that were
 secretly the window's would agree with it at the origin and nowhere else, and a
 test at the origin is a test that cannot fail.
*>
fn void a_draw_node_is_handed_the_pointer_in_its_own_coordinates() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		Heard heard;

		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint pad = renderer.ui.push_node(
			{ .kind = three::UiNodeKind.PADDING, .insets = { 40, 30, 0, 0 } },
			-1
		)!!;
		uint panel = renderer.ui.push_node(
			{ .kind = three::UiNodeKind.DRAW, .size = { 60, 40 }, .on_pointer = true },
			(int)pad
		)!!;
		renderer.ui.commit_tree();
		renderer.ui.on_event(&listen, &heard);
		frame(renderer);

		// Fifteen in and fifteen down from the node's own top-left corner.
		point(renderer, 55, 45, true);
		test::@check(heard.pointers > 0, "the pointer never reached the painting");
		test::@check(heard.node == panel, "the pointer was attributed to node %d rather than %d", heard.node, panel);
		test::@check(
			heard.edge == three::UiPointerPhase.DOWN,
			"the press arrived as %s",
			heard.edge
		);
		test::@check(
			heard.at_x == 15.0 && heard.at_y == 15.0,
			"the position came over as (%f, %f) rather than the node's own (15, 15)",
			heard.at_x,
			heard.at_y
		);
		test::@check(heard.buttons == 1, "the held buttons came over as %d rather than the left one", heard.buttons);
		test::@check(heard.index == 0, "the press named button %d rather than the left one", heard.index);

		// Dragged clean off the node. The press captured the pointer, so this
		// still arrives — and it arrives with a coordinate outside the box, which
		// is what a drag on a timeline needs and what a hit test alone would not
		// give: without the capture the move goes to whatever is under it now.
		renderer.ui.feed({ .inside = true, .down = true, .x = 150, .y = 100 }, {}, "", 16.0);
		test::@check(
			heard.phase == three::UiPointerPhase.MOVE,
			"the drag past the edge arrived as %s",
			heard.phase
		);
		test::@check(
			heard.at_x == 110.0 && heard.at_y == 70.0,
			"the dragged position came over as (%f, %f) rather than (110, 70)",
			heard.at_x,
			heard.at_y
		);
		test::@check(heard.buttons == 1, "the drag lost the button that started it");

		point(renderer, 150, 100, false);
		test::@check(heard.edge == three::UiPointerPhase.UP, "the release arrived as %s", heard.edge);
		test::@check(heard.buttons == 0, "the release still reported a held button");

		uint before = heard.pointers;
		wheel(renderer, 55, 45, 3.0);
		test::@check(heard.pointers > before, "the wheel over the painting reached nobody");
		test::@check(
			heard.edge == three::UiPointerPhase.WHEEL,
			"the wheel arrived as %s",
			heard.edge
		);
		test::@check(heard.wheel == 3.0, "the wheel delta came over as %f", heard.wheel);
	};
}

<*
 A modal over a painting takes the pointer, and the painting hears nothing.

 **This is the whole of item 8.** Painting already worked and the position was
 already reachable — through `three.input.pointer`, which is global and fires
 through an open menu, through a modal, through whatever the host drew on top.
 What was missing was not coordinates but the RIGHT to them, and the only way to
 tell the two apart is to put something over the panel and check that the panel
 goes quiet.

 Both of cui's ways of being on top are checked, because they are different
 mechanisms: a modal `Dialog` is a full-frame element that consumes, and an open
 `MenuBar` is a window-filling catcher on a raised subtree.
*>
fn void a_draw_node_under_a_modal_or_an_open_menu_never_sees_the_pointer() @test
{
	@with_panel(; three::Renderer* renderer)
	{
		Heard heard;

		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint stack = renderer.ui.push_node({ .kind = three::UiNodeKind.STACK }, -1)!!;
		uint panel = renderer.ui.push_node(
			{ .kind = three::UiNodeKind.DRAW, .on_pointer = true },
			(int)stack
		)!!;
		uint ask = renderer.ui.push_node(
			{
				.kind = three::UiNodeKind.CONFIRM_DIALOG,
				.key = "ask",
				.title = "Delete",
				.text = "Delete it?",
				.on_confirm = true,
			},
			(int)stack
		)!!;
		renderer.ui.commit_tree();
		renderer.ui.on_event(&listen, &heard);
		frame(renderer);

		// Closed, the dialog is zero-sized and the painting owns the frame. This
		// is the control: without it a test that passes because nothing works at
		// all looks exactly like a test that passes.
		point(renderer, 260, 200, true);
		point(renderer, 260, 200, false);
		test::@check(heard.pointers > 0, "the painting had no pointer to lose");

		renderer.ui.patch(ask, { .has_checked = true, .checked = true });
		frame(renderer);

		uint quiet = heard.pointers;
		point(renderer, 260, 200, true);
		point(renderer, 260, 200, false);
		point(renderer, 40, 380, true);
		point(renderer, 40, 380, false);
		test::@check(
			heard.pointers == quiet,
			"the painting under an open modal still took %d pointer events",
			heard.pointers - quiet
		);
		test::@check(renderer.ui.wants_pointer, "the modal did not take the pointer either");

		// Down again, and now an open menu over the same painting.
		renderer.ui.patch(ask, { .has_checked = true, .checked = false });
		frame(renderer);

		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		stack = renderer.ui.push_node({ .kind = three::UiNodeKind.STACK }, -1)!!;
		panel = renderer.ui.push_node(
			{ .kind = three::UiNodeKind.DRAW, .on_pointer = true },
			(int)stack
		)!!;
		uint bar = renderer.ui.push_node(
			{ .kind = three::UiNodeKind.MENU, .on_select = true },
			(int)stack
		)!!;
		renderer.ui.push_menu(bar, "File");
		renderer.ui.push_menu_item(bar, "New", "", false, false, false);
		renderer.ui.push_menu_item(bar, "Quit", "", false, false, false);
		renderer.ui.commit_tree();
		frame(renderer);

		test::@check(click_id(renderer, "File"), "the bar had no File title");
		frame(renderer);
		test::@check(
			renderer.ui.nodes[bar].element.widget_as(cui::widgets::MenuBar).open == 1,
			"the menu did not open"
		);

		// Well below the bar and well clear of the dropdown: the catcher's
		// territory, and the painting's if the menu were not open.
		quiet = heard.pointers;
		point(renderer, 400, 360, true);
		point(renderer, 400, 360, false);
		test::@check(
			heard.pointers == quiet,
			"the painting under an open menu still took %d pointer events",
			heard.pointers - quiet
		);
	};
}

// ============================================================================
// cui's application widgets
// ============================================================================

<*
 A confirmation crosses as one node, and whether the question is up survives a
 rebuild that does not mention it.

 The carry is the whole of what makes this usable from a panel that re-renders:
 a HUD that rebuilt for any other reason — a frame counter, a mode switch —
 would otherwise take the user's unanswered question off the screen, and the
 script would never find out that it had.
*>
fn void a_confirmation_keeps_its_question_across_a_rebuild() @test
{
	@with_panel(; three::Renderer* renderer)
	{
		one_node(
			renderer,
			{
				.kind = three::UiNodeKind.CONFIRM_DIALOG,
				.key = "ask",
				.title = "Delete",
				.text = "Delete 17 dots?",
				.confirm_label = "Delete",
				.decline_label = "Keep",
				.checked = true,
				.has_checked = true,
				.on_confirm = true,
				.on_dismiss = true,
			}
		);
		frame(renderer);

		uint at = renderer.ui.node_for("ask")!!;
		cui::Element* elem = renderer.ui.nodes[at].element;
		cui::widgets::ConfirmDialog* dialog = elem.widget_as(cui::widgets::ConfirmDialog);
		test::@check(dialog.asking(elem), "the question the snapshot opened was not up");
		test::@check(
			dialog.message.str_view() == "Delete 17 dots?",
			"the message did not cross: '%s'",
			dialog.message.str_view()
		);

		// The same node again with nothing said about `open`. A new element every
		// time — `push_node` builds rather than reuses — so this is the carry and
		// not the element surviving.
		one_node(
			renderer,
			{ .kind = three::UiNodeKind.CONFIRM_DIALOG, .key = "ask", .text = "Delete 17 dots?", .on_confirm = true }
		);
		frame(renderer);
		at = renderer.ui.node_for("ask")!!;
		elem = renderer.ui.nodes[at].element;
		test::@check(
			elem.widget_as(cui::widgets::ConfirmDialog).asking(elem),
			"a rebuild that said nothing about `open` took the question down"
		);

		// And a snapshot that DOES say it wins, which is the other half of the
		// same rule.
		one_node(
			renderer,
			{
				.kind = three::UiNodeKind.CONFIRM_DIALOG,
				.key = "ask",
				.text = "Delete 17 dots?",
				.has_checked = true,
				.on_confirm = true,
			}
		);
		frame(renderer);
		at = renderer.ui.node_for("ask")!!;
		elem = renderer.ui.nodes[at].element;
		test::@check(
			!elem.widget_as(cui::widgets::ConfirmDialog).asking(elem),
			"a snapshot that closed the question was overruled by the carry"
		);
	};
}

<*
 Both answers reach the listener, and they are two different events.

 A dialog whose Cancel could not be told from its OK is a dialog the caller has
 to guess about, and cui already treats every other way out — the close glyph,
 ESC — as declining. The close glyph is what this drives, because `Dialog` stamps
 it with an id and a test that clicked at computed coordinates would be asserting
 about the font.
*>
fn void a_confirmations_two_answers_are_two_events() @test
{
	@with_panel(; three::Renderer* renderer)
	{
		Heard heard;
		one_node(
			renderer,
			{
				.kind = three::UiNodeKind.CONFIRM_DIALOG,
				.key = "ask",
				.title = "Delete",
				.text = "Delete it?",
				.checked = true,
				.has_checked = true,
				.on_confirm = true,
				.on_dismiss = true,
			}
		);
		renderer.ui.on_event(&listen, &heard);
		frame(renderer);

		uint at = renderer.ui.node_for("ask")!!;

		// The two buttons are one widget and the last thing under the panel. The
		// confirming one is the right-hand half of it — the answer that does
		// something sits where the pointer ends up — and fifteen pixels in from
		// that edge is inside it whatever "OK" measures, since a button is its
		// label plus fourteen pixels of padding at each end.
		cui::Element* answers = last_leaf(renderer.ui.ui.find_id("cui-confirm-panel")!!);
		float y = answers.absolute.y + answers.size.y * 0.5f;
		float x = answers.absolute.x + answers.size.x - 15.0f;

		point(renderer, x, y, true);
		point(renderer, x, y, false);

		test::@check(heard.calls == 1, "the confirming button fired %d times", heard.calls);
		test::@check(
			heard.kind == three::UiEventKind.CONFIRM,
			"the confirming button reported %s",
			heard.kind
		);
		test::@check(heard.node == at, "the answer was attributed to node %d rather than %d", heard.node, at);

		cui::Element* elem = renderer.ui.nodes[at].element;
		test::@check(
			!elem.widget_as(cui::widgets::ConfirmDialog).asking(elem),
			"answering left the question up"
		);

		// Up again through `patch`, which is the verb a class uses — a `set`
		// would build a second dialog and the answer would go to the one that had
		// just been thrown away.
		renderer.ui.patch(at, { .has_checked = true, .checked = true });
		frame(renderer);
		test::@check(
			elem.widget_as(cui::widgets::ConfirmDialog).asking(elem),
			"patching `open` did not put the question back up"
		);

		heard = { };
		test::@check(click_id(renderer, "dialog-close"), "the dialog had no close glyph to click");
		test::@check(heard.calls == 1, "the close glyph fired %d times", heard.calls);
		test::@check(
			heard.kind == three::UiEventKind.DISMISS,
			"closing the panel reported %s rather than a dismissal",
			heard.kind
		);
	};
}

<*
 A menu bar reports which title and which entry, and a separator does not shift
 the count.

 Two coordinates rather than one, because a bar is a list of lists: a flat item
 ordinal would make the panel add up the length of every menu before the one that
 was clicked, and keep that sum in step with its own data. The separator is in
 the tree here on purpose — it is an entry cui builds an element for, so a
 recovery that counted only the selectable rows would be off by one from here on.
*>
fn void a_menu_bar_reports_which_title_and_which_entry() @test
{
	@with_panel(; three::Renderer* renderer)
	{
		Heard heard;

		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint bar = renderer.ui.push_node(
			{ .kind = three::UiNodeKind.MENU, .key = "bar", .on_select = true },
			-1
		)!!;
		renderer.ui.push_menu(bar, "File");
		renderer.ui.push_menu_item(bar, "New", "", false, false, false);
		renderer.ui.push_menu_item(bar, "", "", false, false, true);
		renderer.ui.push_menu_item(bar, "Quit", "Ctrl+Q", false, false, false);
		renderer.ui.push_menu(bar, "View");
		renderer.ui.push_menu_item(bar, "Wireframe", "", true, false, false);
		renderer.ui.commit_tree();
		renderer.ui.on_event(&listen, &heard);
		frame(renderer);

		cui::widgets::MenuBar* widget = renderer.ui.nodes[bar].element.widget_as(cui::widgets::MenuBar);
		test::@check(widget.menus.len == 2, "the bar took %d menus", widget.menus.len);
		test::@check(widget.menus[0].items.len == 3, "the first menu took %d entries", widget.menus[0].items.len);
		test::@check(widget.menus[1].items.len == 1, "the second menu took %d entries", widget.menus[1].items.len);
		test::@check(
			widget.menus[1].items[0].label == "Wireframe",
			"the second menu's entry came out as '%s' — the runs are crossed",
			widget.menus[1].items[0].label
		);

		test::@check(click_id(renderer, "View"), "the bar had no View title");
		// The dropdown does not exist until the bar rebuilds, and the rebuild is
		// deferred to the next frame — which is the same frame that gives its
		// rows the origins the click below is aimed at.
		frame(renderer);

		test::@check(click_id(renderer, "Wireframe"), "the open menu had no Wireframe entry");
		test::@check(heard.calls == 1, "the entry fired %d times", heard.calls);
		test::@check(heard.kind == three::UiEventKind.MENU_PICK, "the entry reported %s", heard.kind);
		test::@check(heard.node == bar, "the pick was attributed to node %d rather than %d", heard.node, bar);
		test::@check(heard.index == 1, "the pick named menu %d rather than 1", heard.index);
		test::@check(heard.item == 0, "the pick named entry %d rather than 0", heard.item);

		// And the far side of the separator, which is the entry an off-by-one
		// would get wrong.
		heard = { };
		test::@check(click_id(renderer, "File"), "the bar had no File title");
		frame(renderer);
		test::@check(click_id(renderer, "Quit"), "the open menu had no Quit entry");
		test::@check(heard.calls == 1, "the entry fired %d times", heard.calls);
		test::@check(heard.index == 0, "the pick named menu %d rather than 0", heard.index);
		test::@check(heard.item == 2, "the pick named entry %d rather than 2 — the separator was not counted", heard.item);
	};
}

<*
 A browser lists its root, hands paths back the way the script wrote them, and
 cannot be walked out of.

 The confinement is the point. cui's `FileBrowser` walks wherever its rows take
 it — `..` at any depth, up to the filesystem root — and it has no notion of a
 root to give it one, so the rule is applied from outside: a move that landed
 outside is sent straight back and told nobody. Without it a game's panel is a
 directory listing of somebody's home directory, one folder at a time.
*>
fn void a_file_browser_hands_back_relative_paths_and_cannot_be_walked_out_of() @test
{
	@with_panel(; three::Renderer* renderer)
	{
		Heard heard;

		Path here = path::cwd(mem)!!;
		defer here.free(mem);
		String root = string::tformat("%s/test/fixtures", (String)here);

		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint at = renderer.ui.push_node(
			{
				.kind = three::UiNodeKind.FILE_BROWSER,
				.key = "files",
				.root = root,
				.on_select = true,
				.on_choose = true,
				.on_change = true,
			},
			-1
		)!!;
		renderer.ui.push_option(at, "*.glb");
		renderer.ui.commit_tree();
		renderer.ui.on_event(&listen, &heard);
		frame(renderer);

		cui::Element* elem = renderer.ui.nodes[at].element;
		cui::widgets::FileBrowser* browser = elem.widget_as(cui::widgets::FileBrowser);
		test::@check(
			browser.directory.str_view() == root,
			"the browser opened at '%s' rather than at its root",
			browser.directory.str_view()
		);
		test::@check(browser.mask.len == 1, "the mask crossed as %d patterns", browser.mask.len);

		// Every row is one `row_height` tall and the list starts at the element's
		// own origin, so a row is arithmetic rather than a search.
		float step = cui::widgets::DEFAULT_FILE_BROWSER_STYLE.row_height;
		int model = browser.entry_at_name("hierarchy.glb");
		test::@check(model >= 0, "the mask hid the models it was written for");

		float y = elem.absolute.y + (float)model * step + step * 0.5f;
		float x = elem.absolute.x + 20.0f;
		point(renderer, x, y, true);
		point(renderer, x, y, false);

		test::@check(heard.kind == three::UiEventKind.FILE_SELECT, "the first click reported %s", heard.kind);
		test::@check(
			heard.said() == "hierarchy.glb",
			"the selection came back as '%s' rather than relative to the root",
			heard.said()
		);

		// The second click on the selected row is what activates it, which is the
		// same two-step every list in cui uses and what lets a browser be driven
		// by anything that cannot express a double click.
		heard = { };
		point(renderer, x, y, true);
		point(renderer, x, y, false);
		test::@check(heard.kind == three::UiEventKind.FILE_CHOOSE, "the second click reported %s", heard.kind);
		test::@check(heard.said() == "hierarchy.glb", "the choice came back as '%s'", heard.said());

		// `..` twice: selected, then activated. The move lands above the root, so
		// the browser is put straight back and the script is told nothing about
		// where it briefly was.
		test::@check(browser.has_parent, "the listing offered no way up to refuse");
		heard = { };
		float up = elem.absolute.y + step * 0.5f;
		point(renderer, x, up, true);
		point(renderer, x, up, false);
		point(renderer, x, up, true);
		point(renderer, x, up, false);

		test::@check(
			browser.directory.str_view() == root,
			"the browser walked out of its root to '%s'",
			browser.directory.str_view()
		);
		test::@check(
			heard.kind != three::UiEventKind.FILE_DIRECTORY || heard.said() == "",
			"a directory above the root was reported as '%s'",
			heard.said()
		);

		// A directory INSIDE the root is a perfectly good move, and it is
		// reported relative to the root like everything else.
		heard = { };
		int folder = browser.entry_at_name("game");
		test::@check(folder >= 0, "the listing hid its subdirectories");
		float into = elem.absolute.y + (float)folder * step + step * 0.5f;
		point(renderer, x, into, true);
		point(renderer, x, into, false);
		point(renderer, x, into, true);
		point(renderer, x, into, false);

		test::@check(
			heard.kind == three::UiEventKind.FILE_DIRECTORY,
			"walking into a folder reported %s",
			heard.kind
		);
		test::@check(heard.said() == "game", "the new directory came back as '%s'", heard.said());
	};
}


<*
 A `dialog`'s body is one subtree, built once and lent to cui — so closing the
 panel puts it away rather than throwing it out.

 This is the whole reason the kind was blocked until cui grew `Dialog.content`.
 `Dialog.body` is a `ViewBuilder` cui calls on every open and whose subtree it
 releases wholesale on close: a snapshot handed over that way would have cui free
 elements this layer still keeps `UiNode` records for, and the next open would
 hand the freed pointers back. So the claim under test is not "a dialog draws" —
 it is that the SAME elements come back, with what was typed into them still
 there.

 Checked in both directions, because either half alone passes on the other's bug:
 an interface where nothing ever opens keeps its pointers perfectly, and one
 where nothing ever closes never has the chance to lose them.
*>
fn void a_dialogs_body_is_borrowed_and_comes_back_whole() @test
{
	@with_panel(; three::Renderer* renderer)
	{
		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint panel = renderer.ui.push_node(
			{
				.kind = three::UiNodeKind.DIALOG,
				.key = "panel",
				.title = "Preferences",
				.gap = 6,
				.checked = true,
				.has_checked = true,
				// Not modal, deliberately: a modal's scrim covers the whole frame
				// and would answer the pixel check below on its own, whether or
				// not the panel it is standing in for ever drew.
				.on_dismiss = true,
			},
			-1
		)!!;
		uint caption = renderer.ui.push_node(
			{ .kind = three::UiNodeKind.LABEL, .key = "caption", .text = "Name" },
			(int)panel
		)!!;
		uint field = renderer.ui.push_node(
			{ .kind = three::UiNodeKind.TEXTFIELD, .key = "name", .size = { 160, 0 }, .on_change = true },
			(int)panel
		)!!;
		renderer.ui.commit_tree();
		frame(renderer);

		cui::Element* body = renderer.ui.nodes[panel].content;
		test::@check(body != null, "the dialog was built without a body to lend");

		// Both children of the body are in the tree and have been laid out, which
		// is the "it renders" half — a dialog whose children never reached cui
		// would answer every pointer question below exactly as a working one does.
		cui::Element* written = renderer.ui.nodes[caption].element;
		cui::Element* typed = renderer.ui.nodes[field].element;
		test::@check(renderer.ui.attached(written), "the body's label never reached the tree");
		test::@check(renderer.ui.attached(typed), "the body's field never reached the tree");
		test::@check(written.size.x > 0 && written.size.y > 0, "the body's label was never laid out");
		// And it landed inside the window. cui places a dialog's panel against
		// the element's absolute from the PREVIOUS emit, so a dialog whose parent
		// moves it puts its panel exactly that far wrong and the layout cache
		// means there is no second pass to correct it — which is why a `dialog`
		// belongs in a `stack`, and why every check above passes on a panel
		// nobody can see.
		test::@check(
			written.absolute.x >= 0 && written.absolute.y >= 0
				&& written.absolute.x < 520 && written.absolute.y < 400,
			"the body was placed at %f,%f, which is off the frame",
			written.absolute.x,
			written.absolute.y
		);

		// State the snapshot never named, so nothing about a rebuild could put it
		// back: this is the thing that has to survive the close.
		renderer.ui.patch(field, { .has_text = true, .text = "Ada" });
		frame(renderer);
		test::@check(
			typed.widget_as(cui::widgets::TextField).value() == "Ada",
			"the field would not take the text: '%s'",
			typed.widget_as(cui::widgets::TextField).value()
		);

		// The pixels, which are the only check here that a panel actually drew:
		// every pointer above is just as true of a dialog placed off the frame.
		image::Image up = renderer.capture()!!;
		defer up.free();

		renderer.ui.patch(panel, { .has_checked = true, .checked = false });
		frame(renderer);

		image::Image down = renderer.capture()!!;
		defer down.free();
		test::@check(
			differing(&up, &down) > 2000,
			"the open panel and the closed one are the same frame to within %d pixels",
			differing(&up, &down)
		);

		cui::widgets::Dialog* widget = renderer.ui.nodes[panel].element.widget_as(cui::widgets::Dialog);
		test::@check(!widget.open, "patching `open` false left the panel up");
		test::@check(!renderer.ui.attached(body), "closing the panel left its body hanging in the tree");
		test::@check(renderer.ui.nodes[panel].content == body, "closing the panel swapped the body element");
		test::@check(renderer.ui.nodes[field].element == typed, "closing the panel rebuilt the field");

		// A patch aimed INTO the closed body, which is a script keeping a hidden
		// panel up to date. It reaches a detached element and has to survive
		// being re-attached, so it is checked after the re-open rather than here.
		renderer.ui.patch(field, { .has_text = true, .text = "Grace" });

		renderer.ui.patch(panel, { .has_checked = true, .checked = true });
		frame(renderer);

		test::@check(widget.open, "patching `open` true did not put the panel back");
		test::@check(renderer.ui.attached(typed), "re-opening did not attach the body it had detached");
		test::@check(renderer.ui.nodes[field].element == typed, "re-opening built a new field");
		test::@check(
			typed.widget_as(cui::widgets::TextField).value() == "Grace",
			"the field came back holding '%s'",
			typed.widget_as(cui::widgets::TextField).value()
		);
	};
}

<*
 Every way the USER puts a dialog away is one event, and the script closing it
 itself is not one.

 The two halves are one test on purpose. `Dialog.set_open` runs `on_close` for
 every dismissal there is — cui's wording is "whoever asked for the close" —
 which is right for a widget and wrong for a binding, so this layer drops the one
 case the script already knows about. A test for the drop alone would pass on a
 binding that reported nothing at all, which is why the close glyph and the
 backdrop are checked first: they are the control on the silence.
*>
fn void a_dialog_the_user_dismissed_is_an_event_and_one_the_script_closed_is_not() @test
{
	@with_panel(; three::Renderer* renderer)
	{
		Heard heard;
		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint root = renderer.ui.push_node({ .kind = three::UiNodeKind.STACK }, -1)!!;
		uint panel = renderer.ui.push_node(
			{
				.kind = three::UiNodeKind.DIALOG,
				.key = "panel",
				.title = "About",
				.checked = true,
				.has_checked = true,
				.modal = true,
				.close_outside = true,
				.on_dismiss = true,
			},
			(int)root
		)!!;
		renderer.ui.push_node({ .kind = three::UiNodeKind.LABEL, .text = "three.c3 0.1.0" }, (int)panel)!!;
		// A full-frame `solid` rect built AFTER the modal, which is the whole
		// case `Element.raised` exists for: the hit test runs in reverse paint
		// order, so without the raise this sibling would take every press the
		// backdrop is there to swallow — and a modal that a later sibling can
		// steal the pointer from is not a modal.
		renderer.ui.push_node(
			{ .kind = three::UiNodeKind.RECT, .solid = true, .color = { 0.1, 0.1, 0.1, 0.5 } },
			(int)root
		)!!;
		renderer.ui.commit_tree();
		renderer.ui.on_event(&listen, &heard);
		frame(renderer);

		cui::widgets::Dialog* widget = renderer.ui.nodes[panel].element.widget_as(cui::widgets::Dialog);
		test::@check(widget.open, "the snapshot did not open the panel");

		// The close glyph, which `Dialog` stamps with an id for exactly this.
		test::@check(click_id(renderer, "dialog-close"), "the panel had no close glyph to click");
		test::@check(heard.calls == 1, "the close glyph fired %d times", heard.calls);
		test::@check(
			heard.kind == three::UiEventKind.DIALOG_DISMISS,
			"the close glyph reported %s",
			heard.kind
		);
		test::@check(heard.node == panel, "the dismissal was attributed to node %d rather than %d", heard.node, panel);
		frame(renderer);
		test::@check(!widget.open, "the close glyph left the panel up");

		// A press on the backdrop of a modal that closes outside. It also says the
		// backdrop is there and takes the pointer: a press that had fallen through
		// to whatever is behind would report nothing at all.
		renderer.ui.patch(panel, { .has_checked = true, .checked = true });
		frame(renderer);
		heard = { };
		point(renderer, 6, 6, true);
		point(renderer, 6, 6, false);
		frame(renderer);
		test::@check(heard.calls == 1, "a press on the backdrop fired %d times", heard.calls);
		test::@check(
			heard.kind == three::UiEventKind.DIALOG_DISMISS,
			"the backdrop reported %s",
			heard.kind
		);
		test::@check(!widget.open, "the backdrop press left the panel up");

		// And the script's own close, which is not news to the script.
		renderer.ui.patch(panel, { .has_checked = true, .checked = true });
		frame(renderer);
		heard = { };
		renderer.ui.patch(panel, { .has_checked = true, .checked = false });
		frame(renderer);
		test::@check(!widget.open, "the script's own patch did not close the panel");
		test::@check(
			heard.calls == 0,
			"closing the panel from the script reported %s back to the script",
			heard.kind
		);
	};
}

<*
 A rebuild keeps a dialog up, and keeps it where it was dragged to.

 The same carry a confirmation gets and for the same reason — a panel that
 re-renders because a frame counter moved must not take a dialog off the screen
 — with the panel's position beside it, because cui centres a dialog nobody has
 moved and a rebuild that dropped `placed` would jump it back to the middle
 under the pointer that was dragging it.

 The element being a NEW one each time is what makes this a test of the carry
 rather than of an element surviving; it is checked rather than assumed.
*>
fn void a_dialog_carries_its_state_across_a_rebuild() @test
{
	@with_panel(; three::Renderer* renderer)
	{
		three::UiNodeSpec spec = {
			.kind = three::UiNodeKind.DIALOG,
			.key = "panel",
			.title = "Preferences",
			.checked = true,
			.has_checked = true,
			.on_dismiss = true,
		};

		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		uint panel = renderer.ui.push_node(spec, -1)!!;
		renderer.ui.push_node({ .kind = three::UiNodeKind.LABEL, .text = "Volume" }, (int)panel)!!;
		renderer.ui.commit_tree();
		frame(renderer);

		cui::Element* first = renderer.ui.nodes[panel].element;
		cui::Element* first_body = renderer.ui.nodes[panel].content;
		// What a drag on the title bar leaves behind, without a drag: the bar
		// writes exactly these two fields and nothing else about a move is state.
		cui::widgets::Dialog* moved = first.widget_as(cui::widgets::Dialog);
		moved.at = { 40, 30 };
		moved.placed = true;

		// The same tree again, saying nothing about `open`.
		spec.checked = false;
		spec.has_checked = false;
		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		panel = renderer.ui.push_node(spec, -1)!!;
		renderer.ui.push_node({ .kind = three::UiNodeKind.LABEL, .text = "Volume" }, (int)panel)!!;
		renderer.ui.commit_tree();
		frame(renderer);

		cui::Element* second = renderer.ui.nodes[panel].element;
		test::@check(second != first, "the rebuild reused the element, so this proves nothing");
		test::@check(
			renderer.ui.nodes[panel].content != first_body,
			"the rebuild reused the body, so this proves nothing"
		);

		cui::widgets::Dialog* again = second.widget_as(cui::widgets::Dialog);
		test::@check(again.open, "a rebuild that said nothing about `open` closed the panel");
		test::@check(again.placed, "the rebuild forgot that the panel had been moved");
		test::@check(
			again.at.x == 40 && again.at.y == 30,
			"the panel came back at %f,%f rather than where it was left",
			again.at.x,
			again.at.y
		);

		// And a snapshot that DOES name `open` wins, which is the other half of
		// the same rule.
		spec.has_checked = true;
		renderer.ui.begin_tree(&renderer.gpu, &renderer.target)!!;
		panel = renderer.ui.push_node(spec, -1)!!;
		renderer.ui.push_node({ .kind = three::UiNodeKind.LABEL, .text = "Volume" }, (int)panel)!!;
		renderer.ui.commit_tree();
		frame(renderer);
		test::@check(
			!renderer.ui.nodes[panel].element.widget_as(cui::widgets::Dialog).open,
			"a snapshot that closed the panel was overruled by the carry"
		);
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
 cui's application widgets cross from JavaScript, as classes.

 The whole of item 7 in one script: three classes on `three.ui`, a widget's
 `render()` describing them, the normaliser in `ui.js` turning the shorthands —
 a bare string for a menu entry, `'-'` for a divider, an array for a mask — into
 the canonical shape, and `bind_ui.c3` pushing two nested levels of it.
*>
fn void a_script_builds_cuis_application_widgets() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const { Column, ConfirmDialog, MenuBar, FileBrowser } = three.ui;
			class Shell extends three.Widget {
				render() {
					return new Column({ gap: 0 },
						new MenuBar([
							{ title: 'File', items: ['New', '-', { label: 'Quit', shortcut: 'Ctrl+Q' }] },
							{ title: 'View', items: [{ label: 'Wireframe', checked: true }] },
						], (menu, item) => { this.picked = [menu, item]; }),
						new FileBrowser('models', ['*.glb', '*.gltf'], path => { this.opened = path; }),
						new ConfirmDialog('Delete it?', true, () => {}, {
							title: 'Delete', confirm: 'Delete', decline: 'Keep', onDismiss: () => {},
						}),
					);
				}
			}
			Shell.mount();
		`);
		defer result.free();
		test::@check(result.ok, "the script ran: %s", result.error);

		// stack (the widget layer's root) > column > the three of them.
		test::@check(renderer.ui.nodes.len() == 5, "the tree came over as %d nodes", renderer.ui.nodes.len());

		int bar = -1;
		int files = -1;
		int ask = -1;
		foreach (i, node : renderer.ui.nodes)
		{
			switch (node.kind)
			{
				case three::UiNodeKind.MENU: bar = (int)i;
				case three::UiNodeKind.FILE_BROWSER: files = (int)i;
				case three::UiNodeKind.CONFIRM_DIALOG: ask = (int)i;
				default: break;
			}
		}
		test::@check(bar >= 0 && files >= 0 && ask >= 0, "one of the three kinds did not cross");

		cui::widgets::MenuBar* menus = renderer.ui.nodes[bar].element.widget_as(cui::widgets::MenuBar);
		test::@check(menus.menus.len == 2, "the bar took %d titles", menus.menus.len);
		test::@check(menus.menus[0].items.len == 3, "File took %d entries", menus.menus[0].items.len);
		test::@check(menus.menus[0].items[0].label == "New", "the bare string was not read as a label");
		test::@check(menus.menus[0].items[1].separator, "'-' did not become a divider");
		test::@check(menus.menus[0].items[2].shortcut == "Ctrl+Q", "the shortcut did not cross");
		test::@check(menus.menus[1].items[0].checked, "the checked flag did not cross");

		cui::widgets::FileBrowser* browser =
			renderer.ui.nodes[files].element.widget_as(cui::widgets::FileBrowser);
		test::@check(browser.mask.len == 2, "the mask crossed as %d patterns", browser.mask.len);
		test::@check(browser.mask[1] == "*.gltf", "the mask came over as '%s'", browser.mask[1]);

		cui::Element* dialog = renderer.ui.nodes[ask].element;
		cui::widgets::ConfirmDialog* question = dialog.widget_as(cui::widgets::ConfirmDialog);
		test::@check(question.title == "Delete", "the title came over as '%s'", question.title);
		test::@check(question.confirm_text() == "Delete", "the confirming label came over as '%s'", question.confirm_text());
		test::@check(question.decline_text() == "Keep", "the declining label came over as '%s'", question.decline_text());
		test::@check(
			question.message.str_view() == "Delete it?",
			"the message came over as '%s'",
			question.message.str_view()
		);
		test::@check(question.asking(dialog), "the positional boolean did not open the question");
	};
}

<*
 A `Dialog` written in JavaScript, and the one thing about it the class layer has
 to get right.

 The crossing itself is the easy half — a class, a normaliser and a kind, the
 same three pieces the other application widgets needed. The half worth a test is
 that `open` is a VALUE and not a shape: `widget.js` compares two renders and
 sends either a `patch` per changed field or one `set` for the whole interface,
 and a `set` here would build a second panel and throw the first one's body away.
 So the check is that a field write closes the dialog and leaves the SAME element
 standing — which is the borrowed body reached the only way a game would reach
 it.
*>
fn void a_script_builds_a_dialog_and_closes_it_without_a_rebuild() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const { Column, Dialog, Label, TextField } = three.ui;
			class Shell extends three.Widget {
				constructor() { super(); this.open = true; }
				render() {
					return new Column({ gap: 0 },
						new Label('behind the panel'),
						new Dialog({ title: 'Preferences', open: this.open, modal: true,
									 scrim: [0, 0, 0, 0.7],
									 onDismiss: () => { this.open = false; } },
							new TextField({ key: 'name', placeholder: 'name' }),
						),
					);
				}
			}
			globalThis.shell = Shell.mount();
		`);
		defer result.free();
		test::@check(result.ok, "the script ran: %s", result.error);

		// stack (the widget layer's root) > column > label + dialog > textfield.
		test::@check(renderer.ui.nodes.len() == 5, "the tree came over as %d nodes", renderer.ui.nodes.len());

		int at = -1;
		int typed = -1;
		foreach (i, node : renderer.ui.nodes)
		{
			switch (node.kind)
			{
				case three::UiNodeKind.DIALOG: at = (int)i;
				case three::UiNodeKind.TEXTFIELD: typed = (int)i;
				default: break;
			}
		}
		test::@check(at >= 0 && typed >= 0, "the dialog or its body did not cross");

		cui::Element* element = renderer.ui.nodes[at].element;
		cui::widgets::Dialog* panel = element.widget_as(cui::widgets::Dialog);
		test::@check(panel.title == "Preferences", "the title came over as '%s'", panel.title);
		test::@check(panel.open, "the panel did not come over open");
		test::@check(panel.modal, "`modal` did not cross");
		test::@check(panel.style.scrim_color.a > 0.6, "`scrim` did not cross: alpha %f", panel.style.scrim_color.a);
		test::@check(
			renderer.ui.nodes[at].content != null && renderer.ui.nodes[typed].element.parent == renderer.ui.nodes[at].content,
			"the body's field did not land in the element the dialog borrows"
		);

		frame(renderer);
		cui::Element* field = renderer.ui.nodes[typed].element;
		test::@check(renderer.ui.attached(field), "the body never reached the tree");

		three::RunResult closed = run.run(`
			globalThis.shell.open = false;
			three.ui.flush();
		`);
		defer closed.free();
		test::@check(closed.ok, "the close ran: %s", closed.error);
		frame(renderer);

		test::@check(!panel.open, "writing the field did not close the panel");
		test::@check(
			renderer.ui.nodes[at].element == element,
			"closing the panel rebuilt the interface — `open` is being read as shape rather than as a value"
		);
		test::@check(renderer.ui.nodes[typed].element == field, "closing the panel rebuilt the body");
		test::@check(!renderer.ui.attached(field), "closing the panel left the body in the tree");
	};
}

<*
 A script reads the pointer off a `draw` node as one named object.

 Nine positional arguments would be the alternative and nobody would remember
 the order. A panel reads two or three fields of this and ignores the rest, which
 is what a bag is for — and `shift` is spelled out rather than left as a bit,
 because `if (e.shift)` is the line somebody writes.
*>
fn void a_script_reads_the_pointer_off_a_draw_node() @test
{
	@with_ui_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult built = run.run(`
			globalThis.seen = [];
			three.ui.set({ type: 'padding', insets: [40, 30, 0, 0], child: {
				type: 'draw', width: 60, height: 40,
				ops: [{ op: 'rect', at: [0, 0], size: [60, 40], color: 0x224466 }],
				onPointer: e => { globalThis.seen.push(e); },
			}});
		`);
		defer built.free();
		test::@check(built.ok, "the script ran: %s", built.error);

		frame(renderer);
		point(renderer, 55, 45, true);
		point(renderer, 55, 45, false);

		three::RunResult read = run.run(`
			const seen = globalThis.seen;
			const down = seen.find(e => e.phase === 'down');
			if (!down) return 'never went down: ' + seen.map(e => e.phase).join('/');
			return [down.x, down.y, down.buttons, down.button, down.shift, down.ctrl,
				seen.some(e => e.phase === 'up')].join(',');
		`);
		defer read.free();
		test::@check(read.ok, "the read-back ran: %s", read.error);
		test::eq(read.value, `"15,15,1,0,false,false,true"`);
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

// ============================================================================
// The slot: a plugin's tree and a script's, composed
// ============================================================================

// A plugin's tree: a full-frame stack with one element inside it that the
// plugin means to hand over. The shape crig has — a workspace with a pane in it.
fn cui::Element* app_tree(three::Renderer* renderer, cui::Element** inner)
{
	cui::Ui* ui = (cui::Ui*)renderer.ui.context(&renderer.gpu, &renderer.target);
	*inner = ui.@node((cui::widgets::Stack){ });
	return ui.@node((cui::widgets::Stack){ }, *inner);
}

<*
 With a slot the two doors compose instead of evicting each other.

 The whole point of `set_slot`, and the one claim worth a test: before it, a
 `three.ui.set` under a native plugin took the floor and blanked the application,
 so an editor written in cui could host no scripted panel at all. After it both
 are mounted and the snapshot hangs from the element the plugin named — not from
 `content`, which is what would make it an overlay rather than a pane.
*>
fn void a_slot_lets_a_plugin_and_a_script_share_the_interface() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		cui::Element* inner;
		cui::Element* root = app_tree(renderer, &inner);
		renderer.ui.set_root(root);
		renderer.ui.set_slot(inner);

		one_node(
			renderer,
			{ .kind = three::UiNodeKind.RECT, .size = { 60, 20 }, .color = { 1.0, 1.0, 1.0, 1.0 } }
		);

		test::@check(renderer.ui.foreign == root, "the script's set evicted the plugin's tree");
		test::@check(renderer.ui.tree != null, "the snapshot was not built");
		test::@check(
			renderer.ui.tree.parent == inner,
			"the snapshot hung from the floor rather than from the slot"
		);
	};
}

<*
 Without a slot they are exclusive, exactly as they were.

 The other half of the same change: `commit_tree` learned a branch, and the
 branch it did not take has to behave the way `set_root` has always
 documented — last writer holds the floor.
*>
fn void with_no_slot_the_plugin_still_loses_the_floor() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		cui::Element* inner;
		renderer.ui.set_root(app_tree(renderer, &inner));

		one_node(renderer, { .kind = three::UiNodeKind.RECT, .size = { 60, 20 } });

		test::@check(renderer.ui.foreign == null, "the plugin's tree survived a set it should not have");
		test::@check(renderer.ui.tree != null, "the snapshot was not built");
		test::@check(
			renderer.ui.tree.parent == renderer.ui.content,
			"the snapshot did not land on the content floor"
		);
	};
}

<*
 Withdrawing the offer takes the panel with it, and says so.

 There is no re-homing: cui has no detach that keeps an element alive, so a
 snapshot moved out of a slot is a rebuild either way. The generation is the
 whole of how a script finds out — a pane that was tabbed away from is gone, and
 a panel that never heard about it would never draw again.
*>
fn void withdrawing_a_slot_clears_the_panel_and_moves_the_generation() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		cui::Element* inner;
		renderer.ui.set_root(app_tree(renderer, &inner));
		renderer.ui.set_slot(inner);
		one_node(renderer, { .kind = three::UiNodeKind.RECT, .size = { 60, 20 } });

		uint before = renderer.ui.slot_generation;
		renderer.ui.set_slot(null);

		test::@check(renderer.ui.slot == null, "the offer stood after it was withdrawn");
		test::@check(renderer.ui.tree == null, "the snapshot outlived the slot it was in");
		test::eq(renderer.ui.nodes.len(), 0);
		test::@check(
			renderer.ui.slot_generation != before,
			"the generation did not move, so no script would ever redraw"
		);
		test::@check(renderer.ui.foreign != null, "withdrawing took the plugin's tree with it");
	};
}

<*
 A slot cui recycled under the layer's feet is dropped, not grafted into.

 The failure this exists for: cui releases a subtree children-first, so a pane
 that rebuilt took the snapshot with it and the plugin's `unmount` hook heard
 about it one step too late. A layer that trusted its pointer would then append
 the next snapshot to an element on the free-list — a corruption with no symptom
 until something unrelated draws in the wrong place.

 Here nobody withdraws at all, which is the worst version of it, and the next
 `set` has to notice on its own and fall back to the floor.
*>
fn void a_recycled_slot_is_noticed_by_the_next_snapshot() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		cui::Element* inner;
		cui::Element* root = app_tree(renderer, &inner);
		renderer.ui.set_root(root);
		renderer.ui.set_slot(inner);
		one_node(renderer, { .kind = three::UiNodeKind.RECT, .size = { 60, 20 } });

		// The pane rebuild, without the withdrawal that should have gone with it.
		// Takes the snapshot underneath along with the slot, exactly as cui would.
		renderer.ui.ui.unmount(inner);
		uint before = renderer.ui.slot_generation;

		one_node(renderer, { .kind = three::UiNodeKind.RECT, .size = { 40, 10 } });

		test::@check(renderer.ui.slot == null, "the recycled slot was still being grafted into");
		test::@check(
			renderer.ui.slot_generation != before,
			"a slot that went away did not move the generation"
		);
		test::@check(renderer.ui.tree != null, "the fallback snapshot was not built");
		test::@check(
			renderer.ui.tree.parent == renderer.ui.content,
			"the snapshot did not fall back to the content floor"
		);
	};
}

<*
 Replacing a plugin's whole tree withdraws the offer inside it.

 The withdrawal a plugin that rebuilds wholesale does not have to make, and the
 ordering that makes it sound: the slot pointer goes first, so the snapshot under
 it is released while it is still attached to something, and only then does the
 tree that held it come off the floor.
*>
fn void a_new_plugin_root_withdraws_the_slot_in_the_old_one() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		cui::Element* inner;
		renderer.ui.set_root(app_tree(renderer, &inner));
		renderer.ui.set_slot(inner);
		one_node(renderer, { .kind = three::UiNodeKind.RECT, .size = { 60, 20 } });

		cui::Element* second;
		renderer.ui.set_root(app_tree(renderer, &second));

		test::@check(renderer.ui.slot == null, "the old tree's slot was still on offer");
		test::@check(renderer.ui.tree == null, "the snapshot survived the tree it was grafted into");
		test::eq(renderer.ui.nodes.len(), 0);

		// And the new tree is usable: the offer is made again and takes.
		renderer.ui.set_slot(second);
		one_node(renderer, { .kind = three::UiNodeKind.RECT, .size = { 30, 30 } });
		test::@check(renderer.ui.tree != null, "nothing drew into the new tree's slot");
		test::@check(renderer.ui.tree.parent == second, "the snapshot missed the new slot");
	};
}

<*
 A slot reports where it is, not only how big it is.

 `three.input.pointer` is the window's and knows nothing about panes, so a script
 drawing its own controls into a slot has only one way to turn a pointer reading
 into a position inside its panel: subtract the slot's corner. That is the whole
 job of `slot_origin`, and the check is that it is the *inset* corner rather than
 the plugin root's — a padding of 24 is a panel that starts 24 in.

 A frame first, because `absolute` is written by the emit pass: the same reason
 the click tests above draw before they point.
*>
fn void a_slot_reports_its_corner_and_not_just_its_size() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		cui::Ui* ui = (cui::Ui*)renderer.ui.context(&renderer.gpu, &renderer.target);
		cui::Element* inner = ui.@node((cui::widgets::Stack){ });
		cui::Element* root = ui.@node(
			(cui::widgets::Padding){ .insets = { 24, 24, 24, 24 } },
			inner
		);

		renderer.ui.set_root(root);
		renderer.ui.set_slot(inner);

		one_node(
			renderer,
			{ .kind = three::UiNodeKind.RECT, .size = { 60, 20 }, .color = { 1.0, 1.0, 1.0, 1.0 } }
		);

		image::Image shot = renderer.capture()!!;
		shot.free();

		Vec2 origin = renderer.ui.slot_origin();
		test::@check(origin.x == 24.0 && origin.y == 24.0,
			"the slot's corner came back as %f, %f rather than the padding's 24, 24",
			origin.x, origin.y);
		test::@check(renderer.ui.slot_size().x > 0, "and the size still answers beside it");
	};
}

<*
 With nothing offered the corner is the origin rather than a stale reading.

 `three.ui.slot` reports `present: false` in the same breath, so a script never
 has to tell "no slot" from "a slot at 0, 0" — but the numbers still have to be
 zero, because a panel that ignored `present` would otherwise hit-test against
 wherever the last slot happened to be.
*>
fn void no_slot_reports_no_corner() @test
{
	@with_renderer(; three::Renderer* renderer)
	{
		one_node(
			renderer,
			{ .kind = three::UiNodeKind.RECT, .size = { 60, 20 }, .color = { 1.0, 1.0, 1.0, 1.0 } }
		);

		Vec2 origin = renderer.ui.slot_origin();
		test::@check(origin.x == 0.0 && origin.y == 0.0,
			"an unoffered slot answered %f, %f", origin.x, origin.y);
	};
}

