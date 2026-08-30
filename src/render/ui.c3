<*
 The interface layer: a cui canvas drawn over the finished frame.

 `c3c test --trust=full --test-noleak --test-filter three_tests::ui`

 ## Where it sits

 Fourth in `Renderer.record_scene`'s list, after the post chain and before
 `target.close`:

     prepare -> shadow -> scene -> [post chain] -> [UI] -> close

 After post, because an interface that gets bloomed and tonemapped is not an
 interface. Into `target.color`, because that is the image the blit reads, the
 readback copies and the MCP screenshot returns — so what an agent sees and what
 a person sees are the same picture, and neither needs a window.

 ## The one file that imports cui

 Everything in this project is `module three`, and cui has a `Cursor`, a `Camera`
 and a `Texture` of its own. Keeping the import here means one file has to
 qualify rather than every file having to. Nothing below leaks a `cui::` type
 into a signature the rest of the project calls.

 ## Nothing exists until something asks

 `Renderer.init` does not build this. A run with no interface allocates no
 buffers, parses no font and records no commands, so every existing frame is
 byte-identical to one from before this file — which is what makes the whole
 layer safe to carry in the headless tests. `set_overlay` is what brings it up.

 ## What it costs, and where that shows

 The overlay's GPU time lands inside `stats().presentMs` rather than a phase of
 its own: the marks in `gpu/timing.c3` are BEGIN..POST..END and this draws
 between the last two. Worth a `uiMs` of its own once the interface is more than
 a line of text.
*>
module three;

import std::collections::list;
import std::io;
import std::math;
import cui;
import cui::vulkan;
import cui::widgets;
import c3w;
import vk;

<*
 The font the interface draws with, in the binary rather than on disk.

 The same argument `js/runtime.c3` makes for the prelude: a renderer that needs
 a file beside it to draw a line of text is a renderer that draws nothing from a
 different working directory, and the headless tests and the MCP server both run
 from wherever they were started. DejaVu Sans, under its own permissive licence.
*>
const char[*] UI_FONT = $embed("fonts/DejaVuSans.ttf");

<*
 The UI, the pass that draws it, and the answer to "did the interface take that
 click".

 Hangs off `Renderer` beside `post`, and like `post` it is inert until something
 uses it — see `active`.
*>
struct UiLayer
{
	// Null until `ensure`. The whole of "is there an interface" — there is no
	// second enabled flag that could disagree with it.
	cui::Ui* ui;
	cui::vulkan::CanvasPass pass;
	cui::FontId font;

	// The one-line overlay: `three.debug.overlay` in pixels rather than in the
	// run's `debug` array. Owned here rather than built as a value widget,
	// because a `Label` borrows its string and this is the thing that keeps it
	// alive — see `set_overlay`.
	cui::widgets::Label overlay;
	DString overlay_text;
	// The label's own element, kept because invalidation is per element: cui
	// caches each element's paint output, so marking the root dirty relayouts
	// the tree and leaves the old glyphs exactly where they were.
	cui::Element* overlay_element;
	// Whether anything set the line since the last `expire_overlay`. What makes
	// the overlay *this frame's* — see there.
	bool overlay_fresh;

	// Whether the interface took this frame's pointer and keyboard. Recomputed
	// by `feed`, read by the window loop — the click that presses a button must
	// not also orbit the camera or reach a script.
	bool wants_pointer;
	bool wants_keys;

	// Held keys, rebuilt each `feed` from the window's bitset. A field so the
	// list's storage is reused instead of reallocated sixty times a second.
	List{cui::Key} held;
}

<*
 Whether there is an interface at all.

 The one question `record_scene` asks. False costs nothing: no upload, no
 rendering, no draw.
*>
fn bool UiLayer.active(&self) => self.ui != null;

<*
 Brings the layer up, once.

 @param gpu : `Borrowed by the pass — device, allocator and queue. Must outlive the layer, which it does: both are fields of Renderer.`
 @param target : `The interface's coordinate space. A Cursor already arrives in these pixels, so nothing converts.`
*>
fn void? UiLayer.ensure(&self, Gpu* gpu, Target* target)
{
	if (self.ui != null) return;

	Vec2 size = { (float)target.extent.width, (float)target.extent.height };

	self.ui = cui::new_ui(size);
	// From here on a failure has to take the Ui down with it, or the next
	// `ensure` finds a half-built layer and returns happily.
	defer catch
	{
		self.ui.free();
		self.ui = null;
	}

	// The heap by name. A zeroed `DString` or `List` takes the *temp* allocator
	// on its first write, and both of these are written from a script callback
	// that runs inside a `@pool()` — the string a widget borrows would then point
	// into memory the frame gave back. `init(mem, 0)` names the allocator and
	// allocates nothing.
	self.overlay_text.init(mem, 0);
	self.held.init(mem, 0);

	self.font = self.ui.load_font_bytes(UI_FONT[..])!;

	// FORMAT_UNDEFINED because `begin_overlay` gives the rendering no depth
	// attachment: cui never tests or writes depth, and the pass is compiled
	// against the attachments it will be recorded into.
	self.pass = cui::vulkan::new_canvas_pass(
		gpu.handle,
		&gpu.allocator,
		gpu.graphics,
		target.color_format,
		FORMAT_UNDEFINED,
		size
	)!;

	// An empty label pinned to the top-left. It measures to nothing and paints
	// nothing until `set_overlay` gives it a string, so bringing the layer up
	// does not put a mark on the frame.
	self.overlay = { .font = self.font, .size = 16.0, .color = cui::WHITE };
	self.overlay_element = self.ui.@node(&self.overlay);
	self.ui.build(
		self.ui.@node(
			(cui::widgets::Anchored){
				.h = cui::widgets::CrossAlign.START,
				.v = cui::widgets::CrossAlign.START,
				.margin = { 12, 12 },
			},
			self.overlay_element
		)
	);
}

fn void UiLayer.free(&self)
{
	if (self.ui == null) return;
	self.pass.free();
	self.ui.free();
	self.ui = null;
	self.overlay_text.free();
	self.held.free();
}

<*
 One line over the frame, replaced whenever it changes.

 The string is copied. A `cui::widgets::Label` borrows its text and must outlive the
 element, and the caller's is a QuickJS string, a temp-allocated format or a
 stack buffer — so this owns the only copy the widget ever sees, and re-points
 the widget at it because a `DString` moves when it grows.

 Empty text on a layer nothing has brought up stays inert: a run that never asks
 for an overlay never pays for one.

 @param gpu : `Only used to bring the layer up on the first non-empty line.`
*>
fn void? UiLayer.set_overlay(&self, Gpu* gpu, Target* target, String text)
{
	if (self.ui == null)
	{
		if (text.len == 0) return;
		self.ensure(gpu, target)!;
	}

	self.overlay_fresh = true;
	if (self.overlay_text.str_view() == text) return;

	self.overlay_text.clear();
	self.overlay_text.append(text);
	self.overlay.text = self.overlay_text.str_view();

	// On the label, not on the root. The text decides the label's size, so this
	// is a relayout rather than a repaint — and `request_layout` marks the
	// ancestors on its way up, which is the half that makes it correct to ask the
	// child rather than the parent.
	self.overlay_element.request_layout();
}

<*
 Drops the line unless the frame that just ran set it again.

 `three.debug.overlay` is documented as *one line, this frame, gone the next*,
 and a retained tree keeps whatever it was last given — so something has to take
 it away. Called at the top of the script frame in `js/frame_loop.c3`: a line set
 during the previous frame is still standing when this runs and survives, and one
 set two frames ago does not.

 Cheap to call every frame and cheap to feed every frame: a script writing the
 same string sixty times a second re-points nothing and invalidates nothing,
 because `set_overlay` compares before it copies.
*>
fn void UiLayer.expire_overlay(&self)
{
	if (self.ui == null) return;

	if (!self.overlay_fresh && self.overlay_text.len() > 0)
	{
		self.overlay_text.clear();
		self.overlay.text = "";
		self.overlay_element.request_layout();
	}
	self.overlay_fresh = false;
}

<*
 One frame of input, and the two questions the rest of the loop asks afterwards.

 `Cursor` is already in the interface's coordinates — image pixels, top-left
 origin — because `WindowView.cursor` put it there for the raycast. The buttons
 are in `cui::MouseButton` order (LEFT, RIGHT, MIDDLE), which is the order
 `Cursor` already carries them in, and `cui::Key` values are the X11 codes
 `c3w::EventKey.code` already holds.

 Sets `wants_pointer` and `wants_keys`. `captured` is the half that matters for
 a drag — the pointer can leave the widget mid-gesture and the widget still owns
 it — and `focused` is the one that keeps typing in a text field out of WASD.

 @param cursor : `This frame's pointer, from WindowView.cursor.`
 @param keys : `What the window said about the keyboard.`
 @param text : `What was typed this frame. Borrowed for the call only.`
 @param dt_ms : `Milliseconds since the last frame.`
*>
fn void UiLayer.feed(&self, Cursor cursor, KeyBits keys, String text, float dt_ms)
{
	if (self.ui == null) return;

	self.held.clear();
	foreach (key : c3w::EventKey::values)
	{
		if (keys.has(key)) self.held.push((cui::Key)key.code);
	}

	cui::InputFrame frame = {
		.mouse = { cursor.x, cursor.y },
		.buttons = { cursor.down, cursor.right, cursor.middle },
		.scroll = cursor.scroll,
		.scroll_x = cursor.scroll_x,
		.text = text,
		.keys_down = self.held.array_view(),
	};
	self.ui.process_input(frame, dt_ms / 1000.0f);

	self.wants_pointer = self.ui.hovered != null || self.ui.captured != null;
	self.wants_keys    = self.ui.focused != null;
}

<*
 The pointer shape the interface is asking for, or ARROW when it has no opinion.

 Resolved by `process_input` from the hovered chain, so a handle that closes its
 hand on the press beginning a drag is right on the same frame. Read only while
 `wants_pointer` — off the interface, `cursor_shape` in `main.c3` still answers.
*>
fn c3w::CursorShape UiLayer.cursor_shape(&self)
{
	if (self.ui == null) return c3w::CursorShape.ARROW;
	switch (self.ui.cursor)
	{
		case cui::Cursor.POINTING_HAND: return c3w::CursorShape.POINTING_HAND;
		case cui::Cursor.IBEAM: return c3w::CursorShape.IBEAM;
		case cui::Cursor.CROSSHAIR: return c3w::CursorShape.CROSSHAIR;
		case cui::Cursor.OPEN_HAND: return c3w::CursorShape.OPEN_HAND;
		case cui::Cursor.CLOSED_HAND: return c3w::CursorShape.CLOSED_HAND;
		case cui::Cursor.RESIZE_H: return c3w::CursorShape.RESIZE_H;
		case cui::Cursor.RESIZE_V: return c3w::CursorShape.RESIZE_V;
		default: return c3w::CursorShape.ARROW;
	}
}

<*
 Whether the loop may sleep as far as the interface is concerned.

 cui sets `frame_requested` on every invalidation — paint, layout, transform,
 mount, unmount — and a running animation re-arms it every frame the way a
 Flutter `Ticker` does. Reading clears it, because the answer is about the frame
 that just went out.
*>
fn bool UiLayer.idle(&self)
{
	if (self.ui == null) return true;
	bool wanted = self.ui.frame_requested;
	self.ui.frame_requested = false;
	return !wanted;
}

<*
 Everything that has to happen outside a render pass: the flush, the glyph
 atlas, and the buffers the shader reads by address.

 `upload` bakes glyphs, may grow a buffer — which idles the GPU — and may
 rebuild the pipeline when the texture count changed, so it cannot be inside a
 rendering. It also calls `ui.flush()` between the two glyph-atlas syncs it has
 to sit between; that ordering is the classic embedding bug and cui deliberately
 does not leave it to the host.

 Its concurrency contract is *one upload per submitted frame, having waited for
 the frame `CANVAS_SLOTS` submissions back*. `CANVAS_SLOTS` is 2, which is
 `MAX_FRAMES_IN_FLIGHT`, and every path into `record_scene` opens with that
 fence wait — `frame()`, `capture()` and `render_offscreen()` alike. A fourth
 path has to keep it.
*>
fn void? UiLayer.upload(&self, Target* target)
{
	if (self.ui == null) return;
	self.pass.upload(self.ui, { (float)target.extent.width, (float)target.extent.height })!;
}

<*
 The draw, inside a rendering `Target.begin_overlay` opened.

 One instanced draw call, whatever the interface contains. A frame with nothing
 to draw records nothing.
*>
fn void? UiLayer.record(&self, vk::CommandBuffer cmd, Target* target)
{
	if (self.ui == null) return;
	self.pass.record(cmd, target.extent)!;
}
