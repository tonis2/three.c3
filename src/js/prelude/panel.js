// three.c3 — UiPanel: the interface on a quad in the scene.
//
// `three.ui` is drawn over the finished frame, which on a headset reads as
// infinitely far away and, with MSAA, has no finished frame to be drawn over. A
// panel is the same interface — the same tree, the same `patch`, the same
// `three.Widget` classes — drawn into an image of its own and worn by a quad, so
// it is in the world: at its distance in both eyes, behind a hand that is in
// front of it, in a screenshot, and on a wrist when it is added to a grip.
//
//   const menu = new three.UiPanel({ width: 512, height: 320, size: 0.4 });
//   menu.set({ type: 'column', gap: 8, children: [
//     { key: 'fps', type: 'label', text: '— fps' },
//     { type: 'button', text: 'Reset', onClick: () => reset() },
//   ]});
//   three.xr.left.grip.add(menu);
//   three.frame(() => menu.pointer(three.xr.right));
//
// The image is drawn only when the interface changed — cui is retained — so a
// panel nobody touches costs a quad.

import { Vector3, asTriple } from './math.js';
import { Mesh } from './mesh.js';
import { PlaneGeometry } from './geometry.js';
import { ShaderMaterial } from './shader.js';
import { Texture } from './texture.js';
import { FrontSide } from './material.js';
import { normaliseTree, patchFields } from './ui.js';
import { Surface } from './widget.js';
import { XrHand } from './xr.js';

const H = globalThis.__three;

// The material every panel wears: unlit, the image's colour exactly, and its
// alpha as the surface's.
//
// The image is premultiplied (cui blends over a clear image), which is what makes
// its mip levels and its bilinear taps right at the edge of a glyph; the body
// divides it back out because the blend multiplies by alpha again. v is turned
// over because the image's first row is the interface's top, and a plane's v
// runs up.
const PANEL_BODY = `
fn float4 panel_texel(Surface s)
{
	return s.textures.panel.Sample(float2(s.uv.x, 1.0 - s.uv.y));
}

fn float3 shade(Surface s)
{
	float4 t = panel_texel(s);
	return t.rgb / max(t.a, 0.0001);
}

fn float opacity(Surface s)
{
	return panel_texel(s).a;
}
`;

const OPTIONS = new Set(['width', 'height', 'size', 'pixelRatio']);

function positive(value, where) {
	const n = Number(value);
	if (!Number.isFinite(n) || n <= 0) throw new TypeError(`${where} wants a positive number, not ${value}`);
	return n;
}

export class UiPanel extends Mesh {
	constructor(options = {}) {
		if (options === null || typeof options !== 'object') {
			throw new TypeError('new three.UiPanel({ width, height, size, pixelRatio }) wants an options object');
		}
		for (const name of Object.keys(options)) {
			if (!OPTIONS.has(name)) {
				throw new TypeError(`new three.UiPanel has no option called '${name}' — it takes width, height, size and pixelRatio`);
			}
		}
		const width = options.width === undefined ? 512 : positive(options.width, 'UiPanel width');
		const height = options.height === undefined ? 512 : positive(options.height, 'UiPanel height');
		if (!Number.isInteger(width) || !Number.isInteger(height)) {
			throw new TypeError(`new three.UiPanel wants whole-number pixels, got ${width}x${height}`);
		}
		const across = options.size === undefined ? 0.5 : positive(options.size, 'UiPanel size');
		const ratio = options.pixelRatio === undefined ? 1 : positive(options.pixelRatio, 'UiPanel pixelRatio');
		const tall = across * height / width;

		const made = H.panelCreate(width, height, ratio, across, tall);
		const texture = new Texture([made.texture, made.width, made.height, made.levels]);
		let material;
		try {
			material = new ShaderMaterial({
				fragment: PANEL_BODY,
				textures: { panel: texture },
				transparent: true,
				side: FrontSide,
			});
		} catch (e) {
			// Nothing will hold the panel, so it goes now rather than at the next reload.
			H.panelDispose(made.id);
			texture.dispose();
			throw e;
		}
		material.castShadow = false;
		super(new PlaneGeometry(across, tall), material);

		this._panel = made.id;
		this._texture = texture;
		this._panelSize = [across, tall];
		this._pixels = [made.width, made.height];
		this._ratio = ratio;
		// Out of every query: a panel is pointed at with `pointer`, and a wrist
		// panel in a sweep would be a wall the player carries.
		this.collides = false;
		// What `three.Widget.mount(panel)` draws into: the panel's own two doors,
		// unguarded, because the class layer is the one writer allowed while
		// widgets are mounted.
		this._surface = new Surface(
			tree => H.panelSet(this._live('set'), normaliseTree(tree)),
			(key, fields) => H.panelPatch(this._live('patch'), String(key), patchFields(key, fields, 'panel')),
			() => { if (this._panel >= 0) H.panelSet(this._panel, null); },
		);
	}

	_live(where) {
		if (this._panel < 0) throw new TypeError(`panel.${where}(): this UiPanel was disposed — make a new one`);
		return this._panel;
	}

	// The interface, as one description — `three.ui.set`'s tree. `null` takes
	// it down. Refused while widgets are mounted on this panel, for the reason
	// `three.ui.set` is: the class layer would overwrite it on the next frame.
	set(tree) {
		const id = this._live('set');
		const n = this._surface.mounted.length;
		if (n > 0) {
			throw new Error(
				`panel.set() cannot run while ${n} widget${n === 1 ? ' is' : 's are'} mounted on this panel — `
				+ 'put it in a widget\'s render(), or unmount them first');
		}
		H.panelSet(id, tree === null || tree === undefined ? null : normaliseTree(tree));
	}

	// One keyed node, one or more of its values — `three.ui.patch`'s fields.
	patch(key, props) {
		H.panelPatch(this._live('patch'), String(key), patchFields(key, props, 'panel'));
	}

	// Takes the interface down, this panel's widgets included.
	clear() {
		const id = this._live('clear');
		for (const record of [...this._surface.mounted]) record.widget.unmount();
		H.panelSet(id, null);
	}

	// Draws a `three.Widget` on this panel. Answers with the widget.
	mount(widget) {
		if (widget === null || typeof widget !== 'object' || typeof widget.mount !== 'function') {
			throw new TypeError('panel.mount(widget) wants a three.Widget — new Hud(), not Hud');
		}
		this._live('mount');
		return widget.mount(this);
	}

	// One frame of pointer: a ray in the world and whether its button is held.
	// `pointer(three.xr.right)` is the hand's aim and its trigger. Answers where
	// the ray meets the front of the panel — `{ x, y, distance, point, onWidget }`,
	// `x` and `y` in the interface's own coordinates — or null for a miss.
	//
	// Widget handlers run inside this call. Call it every frame the panel is to
	// be used, hit or not: a miss is what ends a hover, and a drag that left the
	// panel goes on until the button is let go.
	pointer(origin, direction, down = false, scroll = 0) {
		const id = this._live('pointer');
		if (origin instanceof XrHand) {
			// A hand that is not there points nowhere, which still ends a hover.
			const hand = origin;
			const there = hand.connected;
			origin = there ? hand.aim.position : [0, 0, 0];
			direction = there ? hand.aim.direction : [0, 0, 0];
			down = there && hand.isDown('trigger');
		}
		if (this._h === null) return null;
		const o = asTriple(origin, 'panel.pointer origin');
		const d = asTriple(direction, 'panel.pointer direction');
		const wheel = Number(scroll);
		const r = H.panelPointer(id, this._h, o[0], o[1], o[2], d[0], d[1], d[2], !!down,
			Number.isFinite(wheel) ? wheel : 0);
		if (!r.hit) return null;
		const t = r.distance;
		return {
			x: r.x,
			y: r.y,
			distance: t,
			point: new Vector3(null, o[0] + d[0] * t, o[1] + d[1] * t, o[2] + d[2] * t),
			onWidget: r.onWidget,
		};
	}

	// The image the quad wears, for another material or a `save()`.
	get texture() { return this._texture; }
	get width() { return this._pixels[0]; }
	get height() { return this._pixels[1]; }
	// Image pixels per interface point: the tree is laid out in width / pixelRatio.
	get pixelRatio() { return this._ratio; }
	// `[width, height]` in metres; the height follows the image's aspect.
	get size() { return [...this._panelSize]; }
	// How many times the image has been drawn — a still panel's stays put.
	get redraws() { return this._panel < 0 ? 0 : H.panelRedraws(this._panel); }
	get alive() { return this._panel >= 0; }

	// The interface goes. The quad keeps the last picture it drew until it is
	// removed from the scene. Disposing twice does nothing.
	dispose() {
		if (this._panel < 0) return;
		for (const record of [...this._surface.mounted]) record.widget.unmount();
		H.panelDispose(this._panel);
		this._panel = -1;
		this._texture.dispose();
		if (this.material) this.material.dispose();
	}
}
