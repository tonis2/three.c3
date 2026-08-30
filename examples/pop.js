// pop.js — a whole small game whose interface is a handful of classes.
//
// Nine cubes on a floor, one lit at a time, and thirty seconds to click as many
// as you can. Nothing is loaded from disk, so it runs on a clean checkout.
//
//   ./build/three --script examples/pop.js
//   ./build/three --headless --script examples/pop.js --screenshot menu.png
//
// ## Controls
//
//   click        pop the lit cube            drag    look
//   space        play / play again           p       pause
//   m            back to the menu            wheel   zoom
//
// ## What it is here to show
//
// This is the `three.Widget` example, and `examples/range.js` is the same game
// written against `three.ui.set` and `three.ui.patch` directly. Reading the two
// side by side is the point.
//
// **One method describes the interface.** `render()` says what the panel looks
// like NOW, out of the node classes on `three.ui`. There is no second place
// where a value is written into an existing tree, and no key invented by hand to
// address it. Assign a field and the widget re-renders; what crosses to the
// engine is the DIFFERENCE — a `patch` per changed value, and a rebuild only
// when the shape actually changed. So the clock below is `this.left = seconds`
// once a frame, and the cost of that is one number crossing.
//
// **Four screens are four classes, and they stack.** Pausing MOUNTS the pause
// screen over the HUD; it does not restate it. `static layer = 1` is what puts
// it on top, and unmounting it leaves the HUD exactly as it was — no rebuild, no
// keys to remember to carry, which is the bug this design removes. (Written by
// hand, the pause tree has to contain every key the loop patches, or the first
// patch after pausing throws and the animation loop stops for good.)
//
// **A `Panel` is sized by what is in it.** A background behind a padded column
// that hugs its content, so a card grows a row without anybody working out how
// tall it now is. `{ at: 'top-left', margin: 16 }` anchors it and `width` fixes
// the one axis that should not hug.
//
// **Arguments are read by type.** A string is the text, a function is the
// handler, a boolean is `checked`, a number is the value, an array is the
// options, a plain object is the rest of the properties, and anything else is a
// child. `new Button('Play', () => start())` needs no property names.
//
// **A widget is a class, so a piece of interface is reusable.** `Stat` below is
// constructed twice, holds its own state, and marks the HUD that owns it dirty
// when it changes. Only a mounted widget is a screen; the rest are parts.
//
// **Clicking a button is not a shot.** No flag arranges that: the host
// hit-tests the interface first, and a pointer over a widget never reaches
// `three.onClick`. The scrim behind a menu says `solid: true` to opt back in,
// which is why you cannot play through a paused game.

const { Panel, Stack, Row, Column, Label, Button, Select, TextField, Tree, Rect } = three.ui;

const DIM = [0.62, 0.66, 0.76];
const GOLD = [0.98, 0.72, 0.26];
const SCRIM = [0.02, 0.02, 0.04, 0.55];

const LEVELS = [
	{ name: 'Gentle', life: 1.5, gap: 0.5 },
	{ name: 'Brisk', life: 1.0, gap: 0.3 },
	{ name: 'Unkind', life: 0.6, gap: 0.15 },
];
const ROUND = 30;

// ---------------------------------------------------------------------------
// The scene
// ---------------------------------------------------------------------------

const scene = new three.Scene();
scene.background = 0x05070b;
three.light.set([-0.42, -1, -0.3], 0.55);

// A material carries no colour here — `mesh.color` does, per copy and for free
// — so one material and one geometry make nine cubes one instanced draw call
// and lighting one of them costs nothing.
const matte = new three.MeshLambertMaterial({});

const floor = new three.Mesh(new three.PlaneGeometry(26, 26), matte);
floor.rotation.x = -Math.PI / 2;
floor.color = [0.16, 0.18, 0.24];
scene.add(floor);

const cubeGeometry = new three.BoxGeometry(1.4, 1.4, 1.4);

const cubes = [];
for (let i = 0; i < 9; i++) {
	const cube = new three.Mesh(cubeGeometry, matte);
	cube.name = `cube_${i}`;
	cube.position.set((i % 3 - 1) * 2.6, 0.7, (Math.floor(i / 3) - 1) * 2.6);
	cube.color = [0.30, 0.33, 0.42];
	scene.add(cube);
	cubes.push(cube);
}

three.camera.lookAt(0, 0.6, 0);
three.camera.orbit(35, 30, 12);

// ---------------------------------------------------------------------------
// The game
// ---------------------------------------------------------------------------

const G = {
	mode: 'menu',
	level: 0,
	name: three.persist.name ?? 'you',
	score: 0,
	streak: 0,
	best: 0,
	lit: -1,
	litUntil: 0,
	nextAt: 0,
	endsAt: 0,
	pausedAt: 0,
};

// Survives `three.reload()`, so editing this file keeps the scoreboard.
three.persist.board = three.persist.board ?? [];

function level() { return LEVELS[G.level]; }

function light(index) {
	if (G.lit >= 0) {
		cubes[G.lit].color = [0.30, 0.33, 0.42];
		cubes[G.lit].position.y = 0.7;
	}
	G.lit = index;
	if (index >= 0) {
		cubes[index].color = GOLD;
		cubes[index].position.y = 1.1;
		G.litUntil = three.clock.time + level().life;
	}
}

function start() {
	G.score = 0;
	G.streak = 0;
	G.endsAt = three.clock.time + ROUND;
	G.nextAt = three.clock.time + 0.4;
	light(-1);
	show('playing');
}

function finish() {
	light(-1);
	G.best = Math.max(G.best, G.score);
	three.persist.name = G.name;
	three.persist.board = [...three.persist.board, { name: G.name, score: G.score, level: level().name }]
		.sort((a, b) => b.score - a.score)
		.slice(0, 8);
	show('over');
}

three.onClick((hit) => {
	if (G.mode !== 'playing') return;
	const index = hit && hit.name.startsWith('cube_') ? +hit.name.slice(5) : -1;
	if (index < 0 || index !== G.lit) {
		G.streak = 0;
		hud.streak = 0;
		return;
	}
	G.streak += 1;
	G.score += 10 + Math.min(G.streak - 1, 9) * 5;
	hud.score = G.score;
	hud.streak = G.streak;
	light(-1);
	G.nextAt = three.clock.time + level().gap;
});

three.systems.frame('pop', () => {
	if (G.mode !== 'playing') return;
	const now = three.clock.time;

	// The HUD is a field assignment. It re-renders, the re-render is compared
	// against the last one, and one label crosses.
	hud.left = Math.max(G.endsAt - now, 0);

	if (now >= G.endsAt) { finish(); return; }
	if (G.lit >= 0 && now >= G.litUntil) {
		G.streak = 0;
		hud.streak = 0;
		light(-1);
		G.nextAt = now + level().gap;
	}
	if (G.lit < 0 && now >= G.nextAt) light(Math.floor(Math.random() * cubes.length));
});

// ---------------------------------------------------------------------------
// The interface
// ---------------------------------------------------------------------------

// A part rather than a screen: constructed with `new`, never mounted, and it
// keeps its own state. Writing a field on one marks the widget that OWNS it for
// a re-render, so the HUD does not have to know that this changed.
class Stat extends three.Widget {
	constructor(caption, value) {
		super();
		this.caption = caption;
		this.value = value;
	}

	render() {
		return new Row({ gap: 8, main: 'space-between' },
			new Label(this.caption, { color: DIM, size: 13 }),
			new Label(String(this.value), { size: 20 }),
		);
	}
}

class Menu extends three.Widget {
	constructor() {
		super();
		this.level = G.level;
		this.name = G.name;
	}

	render() {
		return new Stack({},
			new Rect({ color: SCRIM, solid: true }),
			new Panel({ at: 'center', width: 340, gap: 12 },
				new Label('Pop', { size: 36 }),
				new Label('Click the lit cube before it goes out.', { color: DIM, size: 13 }),
				new Select(LEVELS.map(l => l.name), this.level, i => { this.level = i; G.level = i; }),
				new TextField({ key: 'name', text: this.name, placeholder: 'your name', onChange: t => { this.name = t; G.name = t; } }),
				new Button('Play', () => start()),
				new Label('space to start · p to pause · m for this menu', { color: DIM, size: 12 }),
			),
		);
	}
}

class Hud extends three.Widget {
	constructor() {
		super();
		this.score = 0;
		this.streak = 0;
		this.left = ROUND;
		this.best = new Stat('best', 0);
	}

	render() {
		return new Stack({},
			new Panel({ at: 'top-left', margin: 16, width: 190, gap: 4 },
				new Stat('score', this.score),
				new Stat('streak', `x${this.streak}`),
				this.best,
			),
			new Panel({ at: 'top-right', margin: 16 },
				new Label(this.left.toFixed(1), { size: 24, color: this.left < 5 ? GOLD : undefined }),
			),
		);
	}
}

// Over the HUD rather than instead of it: mounting this leaves everything below
// standing, and unmounting it puts the game back with nothing rebuilt.
class Pause extends three.Widget {
	static layer = 1;

	render() {
		return new Stack({},
			new Rect({ color: SCRIM, solid: true }),
			new Panel({ at: 'center', width: 240 },
				new Label('Paused', { size: 26 }),
				new Button('Resume', () => show('playing')),
				new Button('Give up', () => finish()),
			),
		);
	}
}

class Over extends three.Widget {
	static layer = 1;

	render() {
		const board = three.persist.board;
		return new Stack({},
			new Rect({ color: SCRIM, solid: true }),
			new Panel({ at: 'center', width: 340, gap: 10 },
				new Label('Time', { size: 32 }),
				new Label(`${G.name} scored ${G.score} on ${level().name}`, { color: DIM, size: 13 }),
				board.length > 0 && new Tree(
					board.map(row => ({ label: row.name, trailing: `${row.score}` })),
					board.length,
				),
				new Row({ gap: 8 },
					new Button('Again', () => start()),
					new Button('Menu', () => show('menu')),
				),
			),
		);
	}
}

const hud = new Hud();
const screens = { menu: new Menu(), pause: new Pause(), over: new Over() };

// Which widgets are on screen for each mode. Mounting is idempotent and
// unmounting keeps the instance, so a screen carries its own state across a
// visit — the name box remembers what was typed into it.
function show(mode) {
	G.mode = mode;
	const wanted = {
		menu: [screens.menu],
		playing: [hud],
		paused: [hud, screens.pause],
		over: [hud, screens.over],
	}[mode];

	for (const widget of three.Widget.all()) {
		if (!wanted.includes(widget)) widget.unmount();
	}
	for (const widget of wanted) widget.mount();

	if (mode === 'playing') {
		hud.score = G.score;
		hud.streak = G.streak;
		hud.best.value = Math.max(G.best, G.score);
	}
	three.clock.timeScale = mode === 'paused' ? 0 : 1;
}

three.onKeyDown('space', () => { if (G.mode === 'menu' || G.mode === 'over') start(); });
three.onKeyDown('p', () => {
	if (G.mode === 'playing') show('paused');
	else if (G.mode === 'paused') show('playing');
});
three.onKeyDown('m', () => { if (G.mode !== 'menu') { light(-1); show('menu'); } });

show('menu');
