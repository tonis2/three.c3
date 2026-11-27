<*
 `three.UiPanel` — an interface drawn into an image of its own and worn by a quad
 in the scene: `render/ui_panel.c3`, `js/bind_panel.c3`, `js/prelude/panel.js`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::panel`

 The claims are the ones a headset depends on and a screenshot of the right
 picture would not catch: the image is drawn when the interface changed and at
 no other time, the quad is in the world (behind what stands in front of it),
 and a ray presses a button with the same handlers `three.ui` calls. The drawing
 tests run under validation, so a barrier the mip chain gets wrong fails here.
*>
module three_tests::panel;

import three;
import three_tests::device;
import image;
import std::core::test;

const uint W = 160;
const uint H = 120;

macro @with_js(; @body(three::JsRuntime* run, three::Renderer* renderer))
{
	three::Renderer* renderer = device::borrow(W, H, validate: true);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime, renderer);
}

// Runs a script that must succeed, and answers what it returned, as JSON.
macro String @ran(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	test::@check(result.ok, "the script failed: %s", result.error);
	String value = result.value.tcopy();
	result.free();
	return value;
}

// One frame drawn, which is when a panel that changed is drawn too.
fn void frame(three::Renderer* renderer)
{
	image::Image shot = renderer.capture()!!;
	shot.free();
}

// One pixel of the frame, as [r, g, b].
fn char[3] pixel(three::Renderer* renderer, uint x, uint y)
{
	image::Image shot = renderer.capture()!!;
	defer shot.free();
	sz at = ((sz)y * (sz)shot.width + (sz)x) * shot.bytes_per_pixel();
	return { shot.pixels[at], shot.pixels[at + 1], shot.pixels[at + 2] };
}

<*
 The tree lands in the panel's own image, premultiplied over clear, and the
 image is drawn once for it.

 Read back off the texture rather than the frame: the frame is what the quad
 makes of the image, and this is the image.
*>
fn void a_panel_draws_its_tree_into_its_own_image() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ran(run, `
			globalThis.panel = new three.UiPanel({ width: 64, height: 32, size: 1 });
			panel.set({ type: 'row', children: [{ type: 'rect', size: [32, 32], color: [1, 0, 0, 1] }] });
		`);
		test::@check(renderer.panels.len() == 1, "the renderer has %d panels", renderer.panels.len());
		test::@check(renderer.panels[0].redraws == 0, "the image was drawn before any frame");

		frame(renderer);
		String read = @ran(run, `
			const px = panel.texture.read();
			const at = (x, y) => (y * 64 + x) * 4;
			return [px[at(8, 16)], px[at(8, 16) + 1], px[at(8, 16) + 3], px[at(48, 16) + 3], panel.redraws, panel.texture.levels];
		`);
		test::eq(read, "[255,0,255,0,1,7]");
	};
}

<*
 A panel nothing touched is not drawn again, and a change draws it once.

 The one thing that makes a panel affordable on a headset: the image is redrawn
 when cui asks for a picture and never on a frame of its own. A label patched
 with the text it already shows is not a change; a new text is.
*>
fn void a_still_panel_is_not_drawn_again() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ran(run, `
			globalThis.panel = new three.UiPanel({ width: 128, height: 64 });
			panel.set({ type: 'label', key: 'fps', text: '72 fps', color: 0xffffff });
		`);
		frame(renderer);
		uint epoch = renderer.panel_epoch;
		frame(renderer);
		frame(renderer);
		test::@check(renderer.panels[0].redraws == 1, "a still panel was drawn %d times", renderer.panels[0].redraws);
		test::@check(renderer.panel_epoch == epoch, "a still panel moved the picture key");

		@ran(run, `panel.patch('fps', { text: '72 fps' });`);
		frame(renderer);
		test::@check(renderer.panels[0].redraws == 1, "the same text drew the panel again");

		@ran(run, `panel.patch('fps', { text: '90 fps' });`);
		frame(renderer);
		frame(renderer);
		test::@check(renderer.panels[0].redraws == 2, "a new text drew the panel %d times", renderer.panels[0].redraws);
		test::@check(renderer.panel_epoch == epoch + 1, "the redraw did not move the picture key");
	};
}

<*
 The quad is in the world: it shows where it is, and what stands in front of it
 hides it.

 The whole argument for a panel over the overlay. A box between the camera and the
 left half of the panel has to cover it there, and the panel's colour has to be
 there on the right.
*>
fn void the_panel_is_in_the_scene_behind_what_stands_in_front() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ran(run, `
			const scene = new three.Scene();
			scene.background = 0x000000;
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 2);
			const panel = new three.UiPanel({ width: 64, height: 64, size: 1.5 });
			panel.set({ type: 'rect', color: [0, 1, 0, 1] });
			scene.add(panel);
			const box = new three.Mesh(new three.BoxGeometry(0.5, 0.5, 0.1),
				new three.ShaderMaterial({ fragment: 'return float3(1.0, 0.0, 0.0);' }));
			box.position.set(-0.4, 0, 0.5);
			scene.add(box);
		`);
		frame(renderer);
		char[3] covered = pixel(renderer, W / 2 - 34, H / 2);
		char[3] shown = pixel(renderer, W / 2 + 34, H / 2);
		test::@check(covered[0] > 200 && covered[1] < 40, "the box in front did not hide the panel: %s", covered);
		test::@check(shown[1] > 200 && shown[0] < 40, "the panel is not in the frame: %s", shown);
	};
}

<*
 A ray presses a button: the handler is the one the tree carried, the answer is
 where the ray met the panel, and a ray that misses or comes from behind meets
 nothing.
*>
fn void a_ray_presses_a_panels_button() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ran(run, `
			const scene = new three.Scene();
			globalThis.panel = new three.UiPanel({ width: 200, height: 100, size: 2 });
			globalThis.clicks = 0;
			panel.set({ type: 'stack', children: [
				{ type: 'button', text: 'Go', size: [100, 50], onClick: () => { clicks++; } },
			]});
			scene.add(panel);
		`);
		// The layout, which every hit test reads.
		frame(renderer);
		String hit = @ran(run, `
			// The button's middle is (50, 25) of 200x100 points over a 2 x 1 metre plane.
			const ray = (down) => panel.pointer([-0.5, 0.25, 3], [0, 0, -1], down);
			const first = ray(false);
			ray(true);
			ray(false);
			const behind = panel.pointer([-0.5, 0.25, -3], [0, 0, 1], false);
			const beside = panel.pointer([5, 0, 3], [0, 0, -1], false);
			return [clicks, Math.round(first.x), Math.round(first.y), first.distance, first.onWidget, behind, beside];
		`);
		test::eq(hit, "[1,50,25,3,true,null,null]");
	};
}

<*
 At a `pixelRatio` the tree is laid out in fewer points than the image has
 pixels, and the pointer lands in points: the same world spot presses the same
 button, and reads as half the coordinates. A hand that is not connected points
 at nothing.
*>
fn void a_pointer_lands_in_the_interfaces_own_points() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ran(run, `
			const scene = new three.Scene();
			globalThis.panel = new three.UiPanel({ width: 200, height: 100, size: 2, pixelRatio: 2 });
			globalThis.clicks = 0;
			panel.set({ type: 'stack', children: [
				{ type: 'button', text: 'Go', size: [50, 25], onClick: () => { clicks++; } },
			]});
			scene.add(panel);
		`);
		frame(renderer);
		String hit = @ran(run, `
			const ray = (down) => panel.pointer([-0.5, 0.25, 3], [0, 0, -1], down);
			const first = ray(false);
			ray(true);
			ray(false);
			return [clicks, first.x, first.y, panel.pointer(three.xr.right)];
		`);
		test::eq(hit, "[1,25,12.5,null]");
	};
}

<*
 A handler that rebuilds the panel is held while cui is dispatching, and is in
 place by the time `pointer` returns.
*>
fn void a_set_from_a_panels_handler_is_in_place_when_pointer_returns() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ran(run, `
			const scene = new three.Scene();
			globalThis.panel = new three.UiPanel({ width: 100, height: 100, size: 1 });
			panel.set({ type: 'button', key: 'go', text: 'Go', size: [100, 100],
				onClick: () => panel.set({ type: 'label', key: 'done', text: 'done' }) });
			scene.add(panel);
		`);
		frame(renderer);
		@ran(run, `
			panel.pointer([0, 0, 1], [0, 0, -1], true);
			panel.pointer([0, 0, 1], [0, 0, -1], false);
		`);
		test::@check(@ok(renderer.panels[0].layer.node_for("done")), "the handler's tree was not applied");
		test::@check(!@ok(renderer.panels[0].layer.node_for("go")), "the old tree outlived the handler's set");
	};
}

<*
 A `three.Widget` mounts on a panel the way it mounts over the frame, and the two
 interfaces stay apart: the overlay is untouched, `three.ui.set` is still free,
 and the panel's own `set` is refused while the class layer owns it.
*>
fn void a_widget_mounts_on_a_panel_and_leaves_the_overlay_alone() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		String said = @ran(run, `
			const { Column, Label, Button } = three.ui;
			class Menu extends three.Widget {
				constructor() { super(); this.fps = 72; }
				render() { return new Column(new Label(this.fps + ' fps'), new Button('Reset', () => {})); }
			}
			globalThis.panel = new three.UiPanel({ width: 256, height: 128 });
			globalThis.menu = panel.mount(new Menu());
			let refused = false;
			try { panel.set(null); } catch (e) { refused = true; }
			three.ui.set({ type: 'label', key: 'hud', text: 'hud' });
			return [menu.isMounted, three.Widget.count, refused];
		`);
		test::eq(said, "[true,1,true]");
		test::@check(renderer.panels[0].layer.nodes.len() == 4, "the panel took %d nodes", renderer.panels[0].layer.nodes.len());
		test::@check(@ok(renderer.ui.node_for("hud")), "the overlay's own tree did not stand beside the panel's widgets");

		@ran(run, `menu.fps = 90; three.ui.flush();`);
		frame(renderer);
		String count = @ran(run, `three.Widget.unmountAll(); return panel.redraws;`);
		test::eq(count, "1");
		test::@check(renderer.panels[0].layer.nodes.len() == 0, "unmounting left the panel's tree standing");
	};
}

<*
 A disposed panel is gone from the renderer, and a context that closes takes its
 panels with it — a reload must not leave the old script's panels drawing.
*>
fn void a_panel_goes_with_dispose_and_with_its_context() @test
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	@ran(&runtime, `
		const gone = new three.UiPanel({ width: 32, height: 32 });
		gone.dispose();
		gone.dispose();
		globalThis.kept = new three.UiPanel({ width: 32, height: 32 });
	`);
	test::@check(renderer.panels.len() == 1, "dispose left %d panels", renderer.panels.len());
	three::RunResult late = runtime.run(`kept.dispose(); new three.UiPanel({ width: 32, height: 32 }).set(null); return 1;`);
	test::@check(late.ok, "a second panel could not be made: %s", late.error);
	late.free();
	runtime.close();
	test::@check(renderer.panels.len() == 0, "closing the context left %d panels", renderer.panels.len());
}

<*
 A blended body's `opacity` decides how much of it shows, per pixel; a body that
 writes none shows whole. The third hole of the material template, which is what
 a panel's alpha goes through.
*>
fn void a_blended_body_says_how_much_of_it_shows() @test
{
	@with_js(; three::JsRuntime* run, three::Renderer* renderer)
	{
		@ran(run, `
			const scene = new three.Scene();
			scene.background = 0x000000;
			three.camera.lookAt(0, 0, 0);
			three.camera.orbit(0, 0, 2);
			const shown = new three.ShaderMaterial({ transparent: true,
				fragment: 'fn float3 shade(Surface s) { return float3(1.0, 1.0, 1.0); }' });
			const hidden = new three.ShaderMaterial({ transparent: true,
				fragment: 'fn float3 shade(Surface s) { return float3(1.0, 1.0, 1.0); }\nfn float opacity(Surface s) { return 0.0; }' });
			const left = new three.Mesh(new three.PlaneGeometry(0.6, 0.6), shown);
			const right = new three.Mesh(new three.PlaneGeometry(0.6, 0.6), hidden);
			left.position.set(-0.4, 0, 0);
			right.position.set(0.4, 0, 0);
			scene.add(left, right);
		`);
		frame(renderer);
		char[3] whole = pixel(renderer, W / 2 - 25, H / 2);
		char[3] none = pixel(renderer, W / 2 + 25, H / 2);
		test::@check(whole[0] > 200, "a body without opacity did not show: %s", whole);
		test::@check(none[0] < 20, "opacity 0 still showed: %s", none);
	};
}
