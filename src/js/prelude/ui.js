// three.c3 — `three.ui`: the interface, described rather than drawn.
//
// Two verbs and a helper. `set(tree)` when the structure changes, `patch(key,
// props)` when a value does, and `draw(ops)` for the screen-space layer that is
// one `draw` node filling the frame. `measure(text)` is what makes drawing text
// by hand possible at all.
//
// ## Why the normalising happens here
//
// The host can read a property by name and cannot enumerate one — the same
// constraint post.js works under. So this file does the enumerating, the type
// names, the colour spellings and every error message, and hands `bind_ui.c3` a
// canonical object whose field names are fixed and whose numbers are numbers.
// A typo is a TypeError naming the node, not a panel that quietly fails to
// appear.
//
// ## It is retained, and that is the point
//
// cui caches paint output per element: a tree that did not change costs nothing
// on the next frame. So call `set` when the shape of the interface changed and
// `patch` when one value did — not both, every frame. An immediate-mode API
// would rebuild the same picture sixty times a second to show the same thing.
//
// ## Keys
//
// Give anything you type into, scroll, or open a `key`. A rebuild is what `set`
// does, and a key is how the text under somebody's fingers, the scroll position
// and the open popup survive it — along with the keyboard focus. Anything
// stateless never needs one; `patch` needs one, because a key is the address.

import { readColor } from './math.js';

const H = globalThis.__three;

// The node kinds, in the order `UiNodeKind` declares them. The host reads `k`
// and never a string: one integer crosses instead of a name to be matched, and
// the two lists cannot drift because a wrong number is a node the host refuses
// by index rather than one it silently builds as something else.
const KIND = {
	column: 0, row: 1, stack: 2, padding: 3, grid: 4, clip: 5, anchored: 6, scroll: 7,
	rect: 8, label: 9, draw: 10,
	button: 11, checkbox: 12, slider: 13, select: 14, tree: 15, textfield: 16,
};

// The seven Painter primitives, in the order `UiOpKind` declares them.
const OP = { rect: 0, circle: 1, ellipse: 2, line: 3, arc: 4, text: 5, shadow: 6 };

const MAIN = { start: 0, center: 1, centre: 1, end: 2, between: 3, 'space-between': 3, spaceBetween: 3 };
const CROSS = { start: 0, center: 1, centre: 1, end: 2, stretch: 0 };

const TYPES = Object.keys(KIND).join(', ');
const OPS = Object.keys(OP).join(', ');

function num(value, where, fallback = 0) {
	if (value === undefined || value === null) return fallback;
	const n = Number(value);
	if (!Number.isFinite(n)) throw new TypeError(`${where} wants a number, got ${JSON.stringify(value)}`);
	return n;
}

// A pair, from whichever of the three spellings a script reached for. `[w, h]`
// is the one this file emits and the only one the host reads.
function pair(value, where, fallback) {
	if (value === undefined || value === null) return fallback;
	if (typeof value === 'number') return [num(value, where), num(value, where)];
	if (Array.isArray(value)) return [num(value[0], where), num(value[1], where)];
	if (typeof value === 'object') {
		if ('x' in value || 'y' in value) return [num(value.x, where), num(value.y, where)];
		if ('width' in value || 'height' in value) return [num(value.width, where), num(value.height, where)];
	}
	throw new TypeError(`${where} wants [x, y], {x, y} or a single number`);
}

// Four numbers, CSS-style: one is every edge, two is {vertical, horizontal} for
// insets and {TL/BR, TR/BL} for radii, four is the lot. The order is the one cui
// uses — insets {left, top, right, bottom}, radii {TL, TR, BR, BL} — and it is
// worth being explicit about because the two are not the same order.
function quad(value, where, order) {
	if (value === undefined || value === null) return undefined;
	if (typeof value === 'number') { const n = num(value, where); return [n, n, n, n]; }
	if (Array.isArray(value)) {
		const v = value.map(n => num(n, where));
		if (v.length === 1) return [v[0], v[0], v[0], v[0]];
		if (v.length === 2) return order === 'insets' ? [v[1], v[0], v[1], v[0]] : [v[0], v[1], v[0], v[1]];
		if (v.length >= 4) return [v[0], v[1], v[2], v[3]];
		throw new TypeError(`${where} wants one, two or four numbers`);
	}
	if (typeof value === 'object') {
		if (order === 'insets') {
			return [num(value.left, where), num(value.top, where), num(value.right, where), num(value.bottom, where)];
		}
		return [num(value.tl, where), num(value.tr, where), num(value.br, where), num(value.bl, where)];
	}
	throw new TypeError(`${where} wants a number, an array of them, or an object naming the edges`);
}

function colour(value, where) {
	if (value === undefined || value === null) return undefined;
	return readColor(value, where);
}

function enumOf(table, value, where) {
	if (value === undefined || value === null) return undefined;
	const key = String(value);
	if (!(key in table)) {
		throw new TypeError(`${where} does not know '${key}' — it is one of ${Object.keys(table).join(', ')}`);
	}
	return table[key];
}

function handler(value, where) {
	if (value === undefined || value === null) return undefined;
	if (typeof value !== 'function') throw new TypeError(`${where} wants a function`);
	if (value.constructor && value.constructor.name === 'AsyncFunction') {
		throw new TypeError(
			`${where} must be synchronous — an async handler returns before it has done anything, `
			+ 'and the frame does not wait. Do the awaiting in a run_script.'
		);
	}
	return value;
}

// Assign only what was actually given. The host tells "leave this alone" from
// "set this to zero" by whether the property is there at all, and that is what
// makes a keyed textfield keep what somebody typed and a keyed slider keep where
// the drag left it.
function put(out, name, value) {
	if (value !== undefined) out[name] = value;
}

// -----------------------------------------------------------------------
// Drawing

function normaliseOp(op, at) {
	if (op === null || typeof op !== 'object') {
		throw new TypeError(`three.ui op ${at} is not an object — each one is { op: '...', ... }`);
	}
	const name = String(op.op ?? op.type ?? '');
	if (!(name in OP)) {
		throw new TypeError(`three.ui op ${at} has no such op '${name}' — it is one of ${OPS}`);
	}
	const where = `three.ui op ${at} (${name})`;
	const out = { o: OP[name] };

	put(out, 'color', colour(op.color, `${where} color`));
	put(out, 'borderColor', colour(op.borderColor, `${where} borderColor`));
	put(out, 'bw', op.borderWidth === undefined ? undefined : num(op.borderWidth, `${where} borderWidth`));
	put(out, 'corners', quad(op.radius ?? op.borderRadius, `${where} radius`, 'radii'));
	put(out, 'font', op.font === undefined ? undefined : num(op.font, `${where} font`));

	switch (name) {
		case 'rect':
			out.at = pair(op.at ?? op.pos, `${where} at`, [0, 0]);
			out.to = pair(op.size, `${where} size`, [0, 0]);
			break;
		case 'circle':
			out.at = pair(op.center ?? op.centre ?? op.at, `${where} center`, [0, 0]);
			out.r = num(op.radius, `${where} radius`);
			// A circle's `radius` is its size, so it cannot double as the corner
			// rounding the shared reader above took it for.
			delete out.corners;
			break;
		case 'ellipse':
			out.at = pair(op.center ?? op.centre ?? op.at, `${where} center`, [0, 0]);
			out.to = pair(op.radii ?? op.size, `${where} radii`, [0, 0]);
			delete out.corners;
			break;
		case 'line':
			out.at = pair(op.from ?? op.at, `${where} from`, [0, 0]);
			out.to = pair(op.to, `${where} to`, [0, 0]);
			out.th = num(op.thickness ?? 1, `${where} thickness`);
			break;
		case 'arc':
			out.at = pair(op.center ?? op.centre ?? op.at, `${where} center`, [0, 0]);
			out.r = num(op.radius, `${where} radius`);
			out.s = num(op.start, `${where} start`);
			out.sw = num(op.sweep, `${where} sweep`);
			out.th = num(op.thickness ?? 1, `${where} thickness`);
			delete out.corners;
			break;
		case 'text':
			out.at = pair(op.at ?? op.pos, `${where} at`, [0, 0]);
			out.text = String(op.text ?? '');
			out.size = num(op.size, `${where} size`);
			delete out.corners;
			break;
		case 'shadow':
			out.at = pair(op.at ?? op.pos, `${where} at`, [0, 0]);
			out.to = pair(op.size, `${where} size`, [0, 0]);
			out.blur = num(op.blur, `${where} blur`);
			break;
	}
	return out;
}

function normaliseOps(ops, where) {
	if (ops === undefined || ops === null) return undefined;
	if (!Array.isArray(ops)) throw new TypeError(`${where} wants an array of ops`);
	return ops.map((op, i) => normaliseOp(op, `${i} of ${where}`));
}

// -----------------------------------------------------------------------
// Nodes

function normalise(node, path) {
	if (node === null || node === undefined) return null;
	if (typeof node !== 'object') {
		throw new TypeError(`three.ui: ${path} is not a node — every node is an object with a type`);
	}

	const type = String(node.type ?? '');
	if (!(type in KIND)) {
		throw new TypeError(`three.ui: ${path} has no such type '${type}' — it is one of ${TYPES}`);
	}
	const where = `three.ui ${path} (${type})`;
	const out = { k: KIND[type] };

	if (node.key !== undefined && node.key !== null) out.key = String(node.key);

	// Layout, shared by everything that has it. A field a kind does not use is
	// simply not read on the far side, which is why one reader serves all
	// seventeen and there is no per-type table of allowed properties to keep in
	// step with cui.
	put(out, 'gap', node.gap === undefined ? undefined : num(node.gap, `${where} gap`));
	put(out, 'gapY', node.gapY === undefined ? undefined : num(node.gapY, `${where} gapY`));
	put(out, 'main', enumOf(MAIN, node.main ?? node.mainAlign, `${where} main`));
	put(out, 'cross', enumOf(CROSS, node.cross ?? node.crossAlign, `${where} cross`));
	put(out, 'insets', quad(node.insets ?? node.padding, `${where} insets`, 'insets'));
	put(out, 'radii', quad(node.radius ?? node.radii, `${where} radius`, 'radii'));
	put(out, 'margin', node.margin === undefined ? undefined : pair(node.margin, `${where} margin`, [0, 0]));
	put(out, 'cell', node.cell === undefined ? undefined : pair(node.cell, `${where} cell`, [0, 0]));
	put(out, 'ah', enumOf(CROSS, node.h ?? node.horizontal, `${where} h`));
	put(out, 'av', enumOf(CROSS, node.v ?? node.vertical, `${where} v`));
	if (node.solid) out.solid = true;

	// `size` is per axis and zero means "take what you are offered", which is
	// cui's own convention and the reason a panel with no size fills its parent.
	const size = node.size !== undefined ? pair(node.size, `${where} size`, [0, 0])
		: (node.width !== undefined || node.height !== undefined)
			? [num(node.width, `${where} width`), num(node.height, `${where} height`)]
			: undefined;
	put(out, 'size', size);

	put(out, 'color', colour(node.color, `${where} color`));
	put(out, 'borderColor', colour(node.borderColor, `${where} borderColor`));
	put(out, 'borderWidth', node.borderWidth === undefined ? undefined : num(node.borderWidth, `${where} borderWidth`));
	put(out, 'accent', colour(node.accent ?? node.checkedColor ?? node.fillColor, `${where} accent`));
	put(out, 'hoverColor', colour(node.hoverColor, `${where} hoverColor`));
	put(out, 'pressColor', colour(node.pressColor, `${where} pressColor`));
	put(out, 'textColor', colour(node.textColor, `${where} textColor`));
	put(out, 'font', node.font === undefined ? undefined : num(node.font, `${where} font`));
	put(out, 'textSize', node.textSize === undefined ? undefined : num(node.textSize, `${where} textSize`));

	// The caption, which every widget that has one spells differently in prose
	// and identically here. A textfield is the exception and is handled below:
	// its `text` is a value somebody typed, not a label.
	if (type !== 'textfield') {
		const caption = node.text ?? node.label;
		if (caption !== undefined && caption !== null) out.text = String(caption);
		else if (type === 'label') out.text = '';
	}

	switch (type) {
		case 'slider':
			if (node.suffix !== undefined) out.suffix = String(node.suffix);
			if (node.value !== undefined) out.value = num(node.value, `${where} value`);
			put(out, 'min', node.min === undefined ? undefined : num(node.min, `${where} min`));
			put(out, 'max', node.max === undefined ? undefined : num(node.max, `${where} max`));
			put(out, 'step', node.step === undefined ? undefined : num(node.step, `${where} step`));
			put(out, 'curve', node.curve === undefined ? undefined : num(node.curve, `${where} curve`));
			put(out, 'decimals', node.decimals === undefined ? undefined : num(node.decimals, `${where} decimals`));
			if (node.disabled) out.disabled = true;
			break;
		case 'checkbox':
			if (node.checked !== undefined) out.checked = !!node.checked;
			break;
		case 'select':
			out.options = (node.options ?? []).map(String);
			if (node.selected !== undefined) out.selected = num(node.selected, `${where} selected`);
			break;
		case 'tree':
			out.rows = normaliseRows(node.rows, `${where} rows`);
			if (node.selected !== undefined) out.selected = num(node.selected, `${where} selected`);
			break;
		case 'textfield':
			if (node.text !== undefined && node.text !== null) out.text = String(node.text);
			if (node.placeholder !== undefined) out.suffix = String(node.placeholder);
			break;
		case 'scroll':
			if (node.offset !== undefined) out.offset = num(node.offset, `${where} offset`);
			put(out, 'step', node.step === undefined ? undefined : num(node.step, `${where} step`));
			put(out, 'accent', colour(node.thumbColor, `${where} thumbColor`));
			break;
		case 'draw':
			out.ops = normaliseOps(node.ops, `${where} ops`) ?? [];
			break;
	}

	put(out, 'onClick', handler(node.onClick, `${where} onClick`));
	put(out, 'onChange', handler(node.onChange, `${where} onChange`));
	put(out, 'onCommit', handler(node.onCommit, `${where} onCommit`));
	put(out, 'onSubmit', handler(node.onSubmit, `${where} onSubmit`));
	put(out, 'onSelect', handler(node.onSelect, `${where} onSelect`));
	put(out, 'onToggle', handler(node.onToggle, `${where} onToggle`));
	put(out, 'onHover', handler(node.onHover, `${where} onHover`));

	// `child` and `children` are the same thing said two ways, because a Padding
	// with one child reads badly as an array of one and a Column with six reads
	// badly as six nested properties.
	const kids = node.children !== undefined ? node.children : (node.child !== undefined ? [node.child] : null);
	if (kids !== null && kids !== undefined) {
		if (!Array.isArray(kids)) throw new TypeError(`${where} children wants an array of nodes`);
		const built = [];
		kids.forEach((kid, i) => {
			// A falsy child is how a script writes a conditional row, so it is
			// skipped rather than refused: `cond && { type: 'label', ... }`.
			if (kid === null || kid === undefined || kid === false) return;
			built.push(normalise(kid, `${path}.children[${i}]`));
		});
		out.ch = built;
	}

	// cui's Scroll asserts that it has exactly one child, and a script writing
	// an empty one — a list that has not loaded yet — is not a mistake worth
	// stopping the process over. It gets an empty stack to scroll instead.
	if (type === 'scroll' && (out.ch === undefined || out.ch.length === 0)) out.ch = [{ k: KIND.stack }];

	return out;
}

function normaliseRows(rows, where) {
	if (rows === undefined || rows === null) return [];
	if (!Array.isArray(rows)) throw new TypeError(`${where} wants an array of rows`);
	return rows.map((row, i) => {
		if (typeof row === 'string') return { label: row, depth: 0 };
		if (row === null || typeof row !== 'object') {
			throw new TypeError(`${where}[${i}] is a string or { label, trailing, depth, expandable, expanded }`);
		}
		return {
			label: String(row.label ?? ''),
			trailing: row.trailing === undefined ? '' : String(row.trailing),
			depth: num(row.depth, `${where}[${i}] depth`),
			expandable: !!row.expandable,
			expanded: !!row.expanded,
		};
	});
}

// -----------------------------------------------------------------------
// The namespace

export const ui = {
	// The whole interface, as one description. Call it when the SHAPE changed —
	// a panel opened, a list gained a row, a mode switched. Call `patch` when a
	// number changed.
	//
	//   three.ui.set({
	//     type: 'anchored', h: 'start', v: 'start', margin: 16,
	//     child: { type: 'column', gap: 8, children: [
	//       { key: 'fps', type: 'label', text: '60 fps', color: 0xffffff },
	//       { type: 'button', text: 'Reset', onClick: () => reset() },
	//     ]},
	//   });
	//
	// `null` takes it down. Everything a widget owns — the text in a field, the
	// scroll offset, the open popup, the keyboard focus — survives this call for
	// any node that carried a `key` and is still the same type.
	set(tree) {
		if (tree === null || tree === undefined) { H.uiClear(); return; }
		H.uiSet(normalise(tree, 'root'));
	},

	// The screen-space layer: a list of drawings positioned in frame pixels,
	// which is what a crosshair, a health bar, a damage flash and a minimap all
	// are. The same seven primitives every built-in widget paints with.
	//
	//   three.ui.draw([
	//     { op: 'arc', center: [110, 110], radius: 90, start: -1.57,
	//       sweep: hp * 6.28, thickness: 10, color: [0.2, 0.9, 0.4, 1] },
	//     { op: 'text', at: [92, 100], text: `${(hp * 100) | 0}%`, size: 18,
	//       color: 0xffffff },
	//   ]);
	//
	// It IS `set` — one `draw` node filling the frame — so it replaces whatever
	// the interface was showing. To put drawings beside widgets, use a `draw`
	// node inside the tree; the coordinates are then the node's own.
	//
	// Coordinates are the same top-left image pixels `three.input.pointer`
	// arrives in, so a reticle at the cursor needs no conversion.
	draw(ops) {
		if (ops === null || ops === undefined) { H.uiClear(); return; }
		if (!Array.isArray(ops)) throw new TypeError('three.ui.draw(ops) wants an array of ops');
		H.uiSet(normalise({ type: 'draw', ops }, 'root'));
	},

	// Takes the interface down. The debug overlay is not part of it and stays.
	clear() { H.uiClear(); },

	// One keyed node, one or more of its values. This is the verb a HUD uses:
	//
	//   three.frame(() => three.ui.patch('fps', { text: `${fps | 0} fps` }));
	//
	// The fields it accepts are the ones that are values rather than structure —
	// text, value, checked, selected, offset, disabled, color, min, max, size —
	// plus `ops`, `options` and `rows`, which replace a list wholesale. Anything
	// that would change the shape of the tree is a `set`.
	patch(key, props) {
		if (key === null || key === undefined) throw new TypeError('three.ui.patch(key, props) wants a key');
		if (props === null || typeof props !== 'object') {
			throw new TypeError('three.ui.patch(key, props) wants an object of fields to write');
		}
		const out = {};
		const where = `three.ui.patch('${key}')`;
		if ('text' in props) out.text = String(props.text);
		if ('value' in props) out.value = num(props.value, `${where} value`);
		if ('checked' in props) out.checked = !!props.checked;
		if ('selected' in props) out.selected = num(props.selected, `${where} selected`);
		if ('offset' in props) out.offset = num(props.offset, `${where} offset`);
		if ('disabled' in props) out.disabled = !!props.disabled;
		if ('color' in props) out.color = colour(props.color, `${where} color`);
		if ('min' in props) out.min = num(props.min, `${where} min`);
		if ('max' in props) out.max = num(props.max, `${where} max`);
		if ('size' in props) out.size = pair(props.size, `${where} size`, [0, 0]);
		if ('ops' in props) out.ops = normaliseOps(props.ops, `${where} ops`);
		if ('options' in props) out.options = (props.options ?? []).map(String);
		if ('rows' in props) out.rows = normaliseRows(props.rows, `${where} rows`);
		H.uiPatch(String(key), out);
	},

	// What a string will take, as [width, height] in pixels.
	//
	// Drawing text by hand is arithmetic without it — centring a readout inside
	// an arc is a measured width — and this is the same measurement cui makes
	// when it lays the glyphs down, so positioning by it lands where they go.
	measure(text, options) {
		const opts = options ?? {};
		return H.uiMeasure(String(text ?? ''), num(opts.font, 'three.ui.measure font'), num(opts.size, 'three.ui.measure size'));
	},
};
