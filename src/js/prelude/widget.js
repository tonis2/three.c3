// three.c3 — `three.Widget`: the interface as classes, and the nodes it is
// composed out of.
//
// ## What this replaces, and the defect it fixes
//
// `three.ui.set(tree)` takes one object literal describing the whole interface,
// and `three.ui.patch(key, props)` writes one value into it afterwards. Both
// work, and everything below is built on them. The defect is that the SPLIT
// BETWEEN THEM IS THE SCRIPT'S JOB, and getting it right means holding three
// facts in your head at every call site:
//
//   * which of the two verbs this change is — structure or value,
//   * a string key for anything that will ever be patched, invented by hand and
//     unique across the whole interface,
//   * and that every tree the game can `set` still carries the keys the loop
//     patches, because `patch` on a key nothing carries THROWS, and a throw in
//     the animation loop stops it for good.
//
// `examples/range.js` got that last one wrong exactly once — a pause screen
// rebuilt without the HUD's labels in it — and the symptom was the whole game
// stopping on the first pause. That is not a mistake a careful person stops
// making; it is a bookkeeping job, and this file does it instead:
//
//     class Hud extends three.Widget {
//         constructor() {
//             super();
//             this.score = 0;
//         }
//
//         render() {
//             const { Panel, Label, Button } = three.ui;
//             return new Panel({ at: 'top-left', margin: 16, width: 190 },
//                 new Label(`Score ${this.score}`, { size: 22 }),
//                 new Button('Reset', () => { this.score = 0; }),
//             );
//         }
//     }
//
//     const hud = Hud.mount();
//     hud.score += 10;            // the label changes; nothing is rebuilt
//
// `render()` describes the interface as it is NOW. Assigning a field marks the
// widget for a re-render, the re-render is compared against the last one, and
// what comes out is a `patch` per changed value — or one `set` when the shape
// genuinely changed. Immediate mode to write, retained mode to run.
//
// ## The three pieces of machinery, and there are only three
//
// **A widget IS a Proxy.** `Widget`'s constructor returns one, and a derived
// constructor's `this` is whatever `super()` returned — so every write to every
// field of a widget, from the constructor onwards and through every reference
// anything ever captured, goes through one `set` trap that does nothing but
// mark the widget dirty. That is the whole of the invalidation. Its one blind
// spot is a field mutated rather than assigned — `this.items.push(x)` — and
// `update()` is the escape hatch for exactly that case.
//
// **Keys are paths.** Every node is keyed by its position in its widget's tree,
// so nothing has to be named by hand and there is no such thing as a key the
// interface does not carry. A `set` happens whenever the shape changed, so a
// path key is stable for exactly as long as it addresses the same node. Give a
// `key` by hand where a LIST REORDERS — the same reason React wants one — and
// the text under somebody's fingers follows the row rather than the position.
//
// **Handlers are indirected.** The function the host holds is a stable
// dispatcher per key, made once and reused, which looks up the current handler
// when it fires. Without that, every render would hand the host a fresh arrow
// function and every render would be a structural change — which is to say the
// whole design would collapse back into `set` sixty times a second.
//
// ## Nodes are objects, and a widget is one of them
//
// `new Column(...)`, `new Label(...)`, `new Button(...)` — the same `new` as
// `three.Mesh` and `three.BoxGeometry`, because they are the same kind of
// thing: a description handed to something that draws it. Arguments are read BY
// TYPE, so the common spellings need no property names at all: a string is the
// text, a function is the handler, a boolean is `checked`, a number is the
// value, an array is the options, and a plain object is the rest of the
// properties. Anything else is a child.
//
// A `Widget` may be a child of a node, which is what makes a bar, a row of
// stats or a dialog reusable: it renders itself and its state marks the widget
// that OWNS it dirty. Only a mounted widget is a root.
import { ui, composed, setTree, clearTree } from './ui.js';
import { systems } from './systems.js';

// Where the re-render runs: after everything a game registers, and after the
// entity write-back at `entity.js`'s LATE_ORDER, so a HUD reads the positions
// the frame is actually drawing. Before the compaction at Infinity, which has
// to stay last.
const RENDER_ORDER = 2e6;

// The one system this file installs, named so `three.systems.report()` says
// where the time went. Installed on the first mount and removed on the last.
const SYSTEM = 'ui.widgets';

// The fields `three.ui.patch` accepts. A change to one of these is a patch; a
// change to anything else, or one of these APPEARING or DISAPPEARING, is a
// rebuild — because the host reads a value it was never given as absent rather
// than as zero, and that difference is what keyed carry-over turns on.
const VALUES = [
	'text', 'value', 'checked', 'open', 'selected', 'offset',
	'disabled', 'color', 'min', 'max', 'size', 'ops', 'options', 'rows', 'menus',
];
const VALUE = new Set(VALUES);

// Everything a node can attach a function to. Compared by PRESENCE and never by
// identity: the host binds a handler when the node is built, so gaining or
// losing one is structure, and the dispatcher standing in for it never changes.
const HANDLER = new Set([
	'onClick', 'onChange', 'onCommit', 'onSubmit', 'onSelect', 'onToggle', 'onHover',
	'onConfirm', 'onDismiss', 'onChoose', 'onPointer',
]);

// Not enumerable: a widget is a plain object a game puts its own fields on, and
// `JSON.stringify(hud)` should answer with those and not with this file's
// bookkeeping.
const STATE = Symbol('widget.state');

const EMPTY = [];

// ---------------------------------------------------------------------------
// Nodes
// ---------------------------------------------------------------------------

// What each kind reads out of an untyped argument. `text` is the string slot,
// `fn` the handler a positional function fills, `bool` the boolean, `number`
// the number and `list` the array — so `new Checkbox('Wireframe', true, fn)`
// and `new Select(['low', 'high'], 1, fn)` need no property names.
//
// A kind with no slot for a type refuses that argument by name rather than
// dropping it: a number handed to a Column is a mistake, and a Column that
// ignored it is a layout that silently did not happen.
//
// `text: true` is the ordinary answer and means the string fills `text`. A NAME
// is for the one kind whose string is not a caption: a file browser's is where
// the listing opens.
const SCHEMA = {
	column: { container: true },
	row: { container: true },
	stack: { container: true },
	padding: { container: true, number: 'insets' },
	grid: { container: true },
	clip: { container: true },
	anchored: { container: true },
	scroll: { container: true },
	panel: { container: true },
	rect: {},
	label: { text: true },
	draw: { list: 'ops', fn: 'onPointer' },
	button: { text: true, fn: 'onClick' },
	checkbox: { text: true, bool: 'checked', fn: 'onChange' },
	slider: { text: true, number: 'value', fn: 'onChange' },
	select: { list: 'options', number: 'selected', fn: 'onChange' },
	tree: { list: 'rows', number: 'selected', fn: 'onSelect' },
	textfield: { text: true, fn: 'onChange' },
	confirmDialog: { text: true, bool: 'open', fn: 'onConfirm' },
	menu: { list: 'menus', fn: 'onSelect' },
	fileBrowser: { text: 'start', list: 'mask', fn: 'onChoose' },
};

// The nine anchors, spelled the way a person says them. `'top-left'`,
// `'top left'` and `'left top'` are one thing, and so are `center`, `centre`
// and `middle` — this is a position being named, not an enum being matched.
const EDGE = {
	left: ['h', 'start'], right: ['h', 'end'],
	top: ['v', 'start'], bottom: ['v', 'end'],
};

function anchor(value, where) {
	const words = String(value).toLowerCase().split(/[\s\-_,]+/).filter(Boolean);
	const out = {};
	for (const word of words) {
		if (word === 'center' || word === 'centre' || word === 'middle') {
			if (out.h === undefined) out.h = 'center';
			if (out.v === undefined) out.v = 'center';
			continue;
		}
		const edge = EDGE[word];
		if (edge === undefined) {
			throw new TypeError(
				`${where} does not know '${word}' — an anchor is made of top, bottom, left, right and center`
			);
		}
		out[edge[0]] = edge[1];
	}
	if (out.h === undefined) out.h = 'center';
	if (out.v === undefined) out.v = 'center';
	return out;
}

function isProps(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value)
		&& !(value instanceof Node) && !(value instanceof Widget);
}

// One node of the description. Everything below is this with a type and a
// handful of argument slots; nothing here talks to the host, and a tree of
// these is inert until a widget renders it.
export class Node {
	constructor(type, args) {
		this.type = type;
		this.props = {};
		this.children = [];
		const schema = SCHEMA[type];
		for (const arg of args) this._take(arg, schema, type);
	}

	_take(arg, schema, type) {
		if (arg === null || arg === undefined) return;
		if (arg instanceof Node || arg instanceof Widget) { this.children.push(arg); return; }

		if (Array.isArray(arg)) {
			if (schema.list !== undefined && this.props[schema.list] === undefined) {
				this.props[schema.list] = arg;
				return;
			}
			for (const item of arg) this._take(item, schema, type);
			return;
		}

		switch (typeof arg) {
			case 'string': {
				const slot = schema.text === true ? 'text' : schema.text;
				if (slot !== undefined && this.props[slot] === undefined) this.props[slot] = arg;
				// A bare string among a container's children is a caption, which
				// is what somebody writing one meant.
				else if (schema.container) this.children.push(new Label(arg));
				else throw new TypeError(`new ${this.constructor.name}: '${arg}' has nowhere to go`);
				return;
			}
			case 'number':
				if (schema.number !== undefined && this.props[schema.number] === undefined) {
					this.props[schema.number] = arg;
					return;
				}
				throw new TypeError(`new ${this.constructor.name}: ${arg} has nowhere to go — a size goes in { width, height }`);
			case 'boolean':
				if (schema.bool !== undefined && this.props[schema.bool] === undefined) {
					this.props[schema.bool] = arg;
					return;
				}
				// `cond && node` is how a conditional child is written, and a
				// kind with no boolean slot is where that lands.
				return;
			case 'function':
				if (schema.fn === undefined) {
					throw new TypeError(`new ${this.constructor.name}: nothing here calls a function — a ${type} has no handler`);
				}
				this.props[schema.fn] = arg;
				return;
			case 'object':
				Object.assign(this.props, arg);
				return;
		}
		throw new TypeError(`new ${this.constructor.name}: ${typeof arg} is not a node, a value or a property bag`);
	}

	// A key by hand, for a list that reorders. Returns the node, so it reads as
	// part of the expression that built it.
	keyed(key) {
		this.props.key = key;
		return this;
	}

	// What this node really is, for the composites. `null` means "already a
	// node the host knows about", which is every kind but `Panel`.
	expand() { return null; }
}

// The eight layout kinds, the three painted ones and the six interactive ones —
// `three.ui.set`'s own list, one class each. Children are the arguments after
// the property bag, so a tree is nesting rather than `children: [...]`.
export class Column extends Node { constructor(...args) { super('column', args); } }
export class Row extends Node { constructor(...args) { super('row', args); } }
export class Stack extends Node { constructor(...args) { super('stack', args); } }
export class Padding extends Node { constructor(...args) { super('padding', args); } }
export class Grid extends Node { constructor(...args) { super('grid', args); } }
export class Clip extends Node { constructor(...args) { super('clip', args); } }
export class Anchored extends Node { constructor(...args) { super('anchored', args); } }
export class Scroll extends Node { constructor(...args) { super('scroll', args); } }
export class Rect extends Node { constructor(...args) { super('rect', args); } }
export class Label extends Node { constructor(...args) { super('label', args); } }
export class Drawing extends Node { constructor(...args) { super('draw', args); } }
export class Button extends Node { constructor(...args) { super('button', args); } }
export class Checkbox extends Node { constructor(...args) { super('checkbox', args); } }
export class Slider extends Node { constructor(...args) { super('slider', args); } }
export class Select extends Node { constructor(...args) { super('select', args); } }
export class Tree extends Node { constructor(...args) { super('tree', args); } }
export class TextField extends Node { constructor(...args) { super('textfield', args); } }

// cui's application widgets, which are the three that are worth having a class
// for and not worth writing again: a question with two answers, an application
// menu bar, and a directory listing you can pick a file out of.
//
//     new ConfirmDialog('Delete 17 dots?', this.asking, () => this.del(),
//         { title: 'Delete', confirm: 'Delete', decline: 'Keep',
//           onDismiss: () => { this.asking = false; } });
//
//     new MenuBar([
//         { title: 'File', items: ['New', 'Open…', '-', { label: 'Quit', shortcut: 'Ctrl+Q' }] },
//         { title: 'View', items: [{ label: 'Wireframe', checked: this.wire }] },
//     ], (menu, item) => this.run(menu, item));
//
//     new FileBrowser('models', ['*.glb'], path => three.load(path));
//
// A MenuBar's handler takes TWO numbers — which title, then which entry —
// because a bar is a list of lists and a flat ordinal would make the panel
// count the length of every menu before the one that was clicked.
//
// A FileBrowser's paths are relative to the directory it was confined to, which
// is the assets root or the plugin's, so a path out of `onChoose` is a path
// `three.load` takes. It sizes itself to its content and wants a Scroll above
// it, cui's shape for every list.
export class ConfirmDialog extends Node { constructor(...args) { super('confirmDialog', args); } }
export class MenuBar extends Node { constructor(...args) { super('menu', args); } }
export class FileBrowser extends Node { constructor(...args) { super('fileBrowser', args); } }

// What a card is made of, since every interface here is made of cards: a
// background behind a padded column, sized to what is in it.
//
// **The sizing is the reason this exists.** A `Stack` fills, because that is
// what a scrim and a root want, so a panel written by hand has to be TOLD its
// height — measure a line, add up the rows, add the insets — and that number
// stops being true the moment a row is added. `{ wrap: true }` is a stack that
// hugs its last child instead, and this is that stack with the two children a
// card always has.
//
// Properties split by where they belong: `color`, `radius`, `borderColor` and
// `borderWidth` paint the background, `insets`/`padding` space the content,
// `gap`, `main` and `cross` lay it out, `width`/`height`/`size` fix an axis
// that should not hug, and `at`/`margin` anchor the whole card in the frame.
const PANEL_BACKGROUND = ['color', 'radius', 'radii', 'borderColor', 'borderWidth'];
const PANEL_COLUMN = ['gap', 'main', 'mainAlign', 'cross', 'crossAlign'];
const PANEL_BOX = ['size', 'width', 'height', 'key', 'solid'];

export class Panel extends Node {
	constructor(...args) { super('panel', args); }

	expand() {
		const p = this.props;
		const background = { color: [0.12, 0.13, 0.17, 0.92], radius: 12, borderColor: [1, 1, 1, 0.08], borderWidth: 1 };
		const column = { gap: 8 };
		const box = { wrap: true };
		for (const name of PANEL_BACKGROUND) if (p[name] !== undefined) background[name] = p[name];
		for (const name of PANEL_COLUMN) if (p[name] !== undefined) column[name] = p[name];
		for (const name of PANEL_BOX) if (p[name] !== undefined) box[name] = p[name];

		const insets = p.insets !== undefined ? p.insets : (p.padding !== undefined ? p.padding : 14);
		const card = new Stack(box,
			new Rect(background),
			new Padding({ insets }, new Column(column, ...this.children)),
		);
		if (p.at === undefined) return card;
		return new Anchored({ ...anchor(p.at, 'Panel at'), margin: p.margin }, card);
	}
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

// Every mounted widget, in the order they are drawn: `layer` first, then the
// order they were mounted in. A modal declares `static layer = 1` and lands
// over a HUD whenever it is mounted.
const mounted = [];
let nextId = 0;
let nextSeq = 0;
let installed = false;

// The set trap. It writes the field and marks the widget dirty, and that is all
// it does — no getters, no interception of reads, nothing that costs anything
// on the way out.
const TRAP = {
	set(target, name, value) {
		target[name] = value;
		if (typeof name !== 'symbol') {
			const record = target[STATE].owner;
			if (record !== null) record.dirty = true;
		}
		return true;
	},
};

// The base class. `class Hud extends three.Widget` and then `Hud.mount()`.
//
// `new Hud()` is allowed and builds an UNMOUNTED widget, which is the right
// thing for one that is going to be a child of another's `render()` — the same
// shape as `new three.Mesh(...)` before `scene.add`. `mount()` is what puts one
// on the screen.
export class Widget {
	constructor() {
		const state = { owner: null, record: null, proxy: null };
		this[STATE] = state;
		// The returned object becomes `this` in every derived constructor, so a
		// field written on the line after `super()` is already tracked.
		state.proxy = new Proxy(this, TRAP);
		return state.proxy;
	}

	// What the interface looks like now. Return a node, a widget, an array of
	// them, or null for nothing at all.
	render() {
		throw new Error(`${this.constructor.name} has no render() — a widget is a class with one method, and that is the method`);
	}

	// Draw this widget. Answers with the widget, so `Hud.mount()` and
	// `new Hud().mount()` are the same expression.
	mount() {
		const state = this[STATE];
		if (state.record !== null) return state.proxy;

		const Class = this.constructor;
		const record = {
			widget: state.proxy,
			Class,
			id: nextId++,
			layer: Number(Class.layer) || 0,
			seq: nextSeq++,
			tree: null,
			next: null,
			dirty: true,
			handlers: new Map(),
			dispatch: new Map(),
			// The live tree by key, so a handler can fold the value the engine
			// already has into what the last render said.
			byKey: new Map(),
			nextByKey: new Map(),
		};
		state.owner = record;
		state.record = record;
		mounted.push(record);
		mounted.sort((a, b) => (a.layer - b.layer) || (a.seq - b.seq));

		if (!installed) {
			systems.frame(SYSTEM, flush, { order: RENDER_ORDER });
			installed = true;
		}
		if (typeof this.onMount === 'function') this.onMount();
		flush();
		return state.proxy;
	}

	// Take it off the screen. The instance survives and can be mounted again;
	// what it was showing is gone on this call rather than at the next frame,
	// the same way `entity.remove()` is immediate.
	unmount() {
		const state = this[STATE];
		const record = state.record;
		if (record === null) return false;
		const at = mounted.indexOf(record);
		if (at >= 0) mounted.splice(at, 1);
		state.record = null;
		state.owner = null;
		if (typeof this.onUnmount === 'function') this.onUnmount();
		rebuild();
		return true;
	}

	// Mark this widget for a re-render. Only needed for a change the `set` trap
	// cannot see — `this.rows.push(row)` mutates an array without writing a
	// field — and harmless when it was not.
	update() {
		const record = this[STATE].owner;
		if (record !== null) record.dirty = true;
		return this;
	}

	get isMounted() { return this[STATE].record !== null; }

	static mount(...args) { return new this(...args).mount(); }

	// On a subclass, that class's widgets; on `three.Widget` itself, every
	// widget there is — which is the reading somebody asking the base class for
	// a count means.
	static all() {
		return (this === Widget ? mounted : mounted.filter(r => r.Class === this)).map(r => r.widget);
	}

	static get count() {
		return this === Widget ? mounted.length : mounted.reduce((n, r) => n + (r.Class === this ? 1 : 0), 0);
	}
	static [Symbol.iterator]() { return this.all()[Symbol.iterator](); }

	// Every widget of this class, or — on `three.Widget` itself — every widget
	// there is, which is what a scene transition wants.
	static unmountAll() {
		const doomed = this === Widget ? [...mounted] : mounted.filter(r => r.Class === this);
		for (const record of doomed) record.widget.unmount();
		return doomed.length;
	}
}

// ---------------------------------------------------------------------------
// Compiling a widget into the description the host takes
// ---------------------------------------------------------------------------

// The events that carry a value the WIDGET IS ALREADY SHOWING: what somebody
// typed, dragged or picked. The engine has it before the handler does, so the
// re-render that follows would otherwise diff the old value against the new one
// and patch a field back to what it already says.
//
// **That patch is not merely wasted.** Writing a text field's text moves the
// caret to the end of it, so a name typed into the middle of a word would jump —
// and a slider written mid-drag fights the drag. So the value is folded into the
// last render before the handler runs: the diff then sees no change, and a
// handler that TRANSFORMS what it was given still patches, because the transform
// is a difference.
const ECHO = { onChange: true, onCommit: true, onSubmit: true, onSelect: true };

function echo(record, key, node_value) {
	const node = record.byKey.get(key);
	if (node === undefined) return;
	let field = null;
	switch (typeof node_value) {
		case 'string': field = 'text'; break;
		case 'boolean': field = 'checked'; break;
		case 'number': field = (node.type === 'select' || node.type === 'tree') ? 'selected' : 'value'; break;
		default: return;
	}
	if (node[field] !== undefined) node[field] = node_value;
}

// The stable function the host holds for one node and one event. Made once per
// key and kept, so a render that changes what a button does changes a Map entry
// and not the tree — which is the difference between a patch and a rebuild.
function dispatcher(record, key, name) {
	const id = `${key}|${name}`;
	let fn = record.dispatch.get(id);
	if (fn === undefined) {
		fn = (...args) => {
			const handler = record.handlers.get(id);
			if (handler === undefined) return undefined;
			if (ECHO[name] === true && args.length > 0) echo(record, key, args[0]);
			const answer = handler.apply(record.widget, args);
			// A handler that mutated rather than assigned still gets its
			// re-render: this is the one place where a change is certain.
			record.dirty = true;
			return answer;
		};
		record.dispatch.set(id, fn);
	}
	return fn;
}

// Whatever `render()` answered with, as one node or null.
function asNode(value) {
	if (value === null || value === undefined || value === false) return null;
	if (value instanceof Node || value instanceof Widget) return value;
	if (Array.isArray(value)) {
		const kids = value.filter(v => v !== null && v !== undefined && v !== false);
		return kids.length === 0 ? null : new Stack({}, ...kids);
	}
	if (typeof value === 'string') return new Label(value);
	throw new TypeError('render() answers with a node, a widget, an array of them, or null');
}

// One node into the plain object `three.ui.set` reads, keyed by its path.
//
// The key carries the widget's id, because two widgets are two subtrees of one
// interface and a key is the address across the whole of it.
function build(node, record, path) {
	if (node instanceof Widget) {
		// A child widget renders itself and marks its OWNER dirty, so its state
		// is its own and its redraw is the owner's.
		const state = node[STATE];
		if (state.record !== null && state.record !== record) {
			throw new Error(
				`${node.constructor.name} is mounted and cannot also be a child — it would be drawn twice, `
				+ 'and a click would reach whichever copy cui hit-tested first. unmount() it first.'
			);
		}
		state.owner = record;
		const produced = asNode(node.render());
		return produced === null ? null : build(produced, record, path);
	}

	const expanded = node.expand();
	if (expanded !== null) return build(expanded, record, path);

	const props = node.props;
	const key = props.key !== undefined ? `${record.id}#${props.key}` : `${record.id}.${path}`;
	const out = { type: node.type, key };
	record.nextByKey.set(key, out);

	for (const name in props) {
		if (name === 'key') continue;
		const value = props[name];
		if (value === undefined) continue;
		if (HANDLER.has(name)) {
			record.handlers.set(`${key}|${name}`, value);
			out[name] = dispatcher(record, key, name);
			continue;
		}
		out[name] = value;
	}

	if (node.children.length > 0) {
		const kids = [];
		node.children.forEach((child, i) => {
			const built = build(child, record, `${path}.${i}`);
			if (built !== null) kids.push(built);
		});
		if (kids.length > 0) out.children = kids;
	}
	return out;
}

function compile(record) {
	record.handlers = new Map();
	record.nextByKey = new Map();
	const produced = asNode(record.widget.render());
	return produced === null ? null : build(produced, record, 'r');
}

// ---------------------------------------------------------------------------
// The diff
// ---------------------------------------------------------------------------

function same(a, b) {
	if (a === b) return true;
	if (Array.isArray(a)) {
		if (!Array.isArray(b) || a.length !== b.length) return false;
		for (let i = 0; i < a.length; i++) if (!same(a[i], b[i])) return false;
		return true;
	}
	if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false;
	for (const k in a) if (!same(a[k], b[k])) return false;
	for (const k in b) if (!(k in a)) return false;
	return true;
}

// Whether these two describe the same TREE, ignoring the values a patch can
// write. Everything else — a gap, an inset, a child appearing, a handler
// arriving — is structure, and structure is a `set`.
function sameShape(a, b) {
	if (a === null || b === null) return a === b;
	if (a.type !== b.type || a.key !== b.key) return false;

	for (const name in a) {
		if (name === 'type' || name === 'key' || name === 'children') continue;
		if (HANDLER.has(name)) { if (b[name] === undefined) return false; continue; }
		// A value that appeared or vanished is structure; one that merely
		// changed is not.
		if (VALUE.has(name)) { if ((b[name] === undefined) !== (a[name] === undefined)) return false; continue; }
		if (!same(a[name], b[name])) return false;
	}
	for (const name in b) {
		if (name === 'type' || name === 'key' || name === 'children') continue;
		if (a[name] === undefined) return false;
	}

	const ac = a.children ?? EMPTY;
	const bc = b.children ?? EMPTY;
	if (ac.length !== bc.length) return false;
	for (let i = 0; i < ac.length; i++) if (!sameShape(ac[i], bc[i])) return false;
	return true;
}

// What changed, as the `patch` calls that write it. Only reached when the two
// trees have the same shape, so walking them in step is safe.
function changes(a, b, out) {
	let fields = null;
	for (const name of VALUES) {
		const next = b[name];
		if (next === undefined) continue;
		if (same(a[name], next)) continue;
		if (fields === null) fields = {};
		fields[name] = next;
	}
	if (fields !== null) out.push([b.key, fields]);

	const ac = a.children ?? EMPTY;
	const bc = b.children ?? EMPTY;
	for (let i = 0; i < ac.length; i++) changes(ac[i], bc[i], out);
}

// ---------------------------------------------------------------------------
// Sending it
// ---------------------------------------------------------------------------

// Every mounted widget's tree under one root. A `Stack` because the widgets are
// FLOORS of one interface — a modal over a HUD over a crosshair — and cui
// paints a stack's children in order.
function root() {
	const kids = mounted.map(r => r.tree).filter(t => t !== null);
	return { type: 'stack', children: kids };
}

function rebuild() {
	if (mounted.length === 0) {
		if (installed) { systems.remove(SYSTEM); installed = false; }
		clearTree();
		return;
	}
	setTree(root());
}

// Re-render what is dirty and send the difference. One `set` if any widget's
// shape changed, and a `patch` per changed value otherwise.
//
// The two are exclusive on purpose: a `set` replaces the whole interface, so a
// patch computed against the tree it replaced would be writing into a node that
// no longer exists.
function flush() {
	if (mounted.length === 0) return;

	const dirty = [];
	let structural = false;
	for (const record of mounted) {
		if (!record.dirty) continue;
		record.dirty = false;
		record.next = compile(record);
		if (!sameShape(record.tree, record.next)) structural = true;
		dirty.push(record);
	}
	if (dirty.length === 0) return;

	if (structural) {
		for (const record of dirty) {
			record.tree = record.next;
			record.byKey = record.nextByKey;
			// A dispatcher for a key the new tree does not carry is dead
			// weight; a surviving key keeps its function, which is the point.
			for (const id of record.dispatch.keys()) {
				if (!record.handlers.has(id)) record.dispatch.delete(id);
			}
		}
		setTree(root());
	} else {
		const out = [];
		for (const record of dirty) {
			changes(record.tree, record.next, out);
			record.tree = record.next;
			record.byKey = record.nextByKey;
		}
		for (const [key, fields] of out) ui.patch(key, fields);
	}
	for (const record of dirty) record.next = null;
}

// `three.ui` asks these three things and knows nothing else about this file, so
// the dependency runs one way and there is no cycle to unpick.
composed.count = () => mounted.length;
composed.flush = flush;
composed.clear = () => Widget.unmountAll();

// `three.reset()`, and the context teardown behind it.
export function unmountAll() { return Widget.unmountAll(); }

// What `three.ui` publishes beside its own verbs.
export const nodes = {
	Node, Widget,
	Column, Row, Stack, Padding, Grid, Clip, Anchored, Scroll, Panel,
	Rect, Label, Drawing,
	Button, Checkbox, Slider, Select, Tree, TextField,
	ConfirmDialog, MenuBar, FileBrowser,
};
