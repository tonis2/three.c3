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
// Click the lit cube; drag to look, wheel to zoom. The keys are the
// `@three.key` methods on `Game` below, and the menu's help line is made from
// them, so they are written down once.

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

// Survives `three.reload()`, so editing this file keeps the scoreboard.
three.persist.board = three.persist.board ?? [];

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

// The menu shows the game's own level and name rather than a copy of them:
// a handler firing marks the widget for a re-render, so writing `game.level`
// from the Select is all it takes for the menu to show it.
class Menu extends three.Widget {
	render() {
		const help = Object.entries(three.keys()).map(([key, what]) => `${key} ${what}`).join(' · ');
		return new Stack({},
			new Rect({ color: SCRIM, solid: true }),
			new Panel({ at: 'center', width: 340, gap: 12 },
				new Label('Pop', { size: 36 }),
				new Label('Click the lit cube before it goes out.', { color: DIM, size: 13 }),
				new Select(LEVELS.map(l => l.name), game.level, i => { game.level = i; }),
				new TextField({ key: 'name', text: game.name, placeholder: 'your name', onChange: t => { game.name = t; } }),
				new Button('Play', () => game.start()),
				new Label(help, { color: DIM, size: 12 }),
			),
		);
	}
}

// The scoreboard IS the score: the game adds to `hud.score` and nothing else
// holds a copy, so there is nothing to keep in step. A field assignment
// re-renders it, and assigning the number it already holds does not.
class Hud extends three.Widget {
	score = 0;
	streak = 0;
	left = ROUND;
	best = new Stat('best', 0);

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
				new Button('Resume', () => game.show('playing')),
				new Button('Give up', () => game.finish()),
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
				new Label(`${game.name} scored ${hud.score} on ${game.difficulty.name}`, { color: DIM, size: 13 }),
				board.length > 0 && new Tree(
					board.map(row => ({ label: row.name, trailing: `${row.score}` })),
					board.length,
				),
				new Row({ gap: 8 },
					new Button('Again', () => game.start()),
					new Button('Menu', () => game.show('menu')),
				),
			),
		);
	}
}

const hud = new Hud();
const screens = { menu: new Menu(), pause: new Pause(), over: new Over() };

// ---------------------------------------------------------------------------
// The game
// ---------------------------------------------------------------------------

class Game {
	mode = 'menu';
	level = 0;
	name = three.persist.name ?? 'you';
	lit = -1;          // the cube that is lit, or -1
	litUntil = 0;      // clock times: the timers stop with the clock on pause
	nextAt = 0;
	endsAt = 0;

	// Which widgets are on screen for each mode. Mounting is idempotent and
	// unmounting keeps the instance, so a screen carries its own state across a
	// visit — the name box remembers what was typed into it.
	modes = {
		menu: [screens.menu],
		playing: [hud],
		paused: [hud, screens.pause],
		over: [hud, screens.over],
	};

	constructor() {
		three.onClick(hit => this.click(hit));
	}

	get difficulty() { return LEVELS[this.level]; }

	show(mode) {
		this.mode = mode;
		const wanted = this.modes[mode];
		for (const widget of three.Widget.all()) {
			if (!wanted.includes(widget)) widget.unmount();
		}
		for (const widget of wanted) widget.mount();
		three.clock.timeScale = mode === 'paused' ? 0 : 1;
	}

	light(index) {
		if (this.lit >= 0) {
			cubes[this.lit].color = [0.30, 0.33, 0.42];
			cubes[this.lit].position.y = 0.7;
		}
		this.lit = index;
		if (index >= 0) {
			cubes[index].color = GOLD;
			cubes[index].position.y = 1.1;
			this.litUntil = three.clock.time + this.difficulty.life;
		}
	}

	// The lit cube goes dark, and the next one lights after the level's gap.
	darken() {
		this.light(-1);
		this.nextAt = three.clock.time + this.difficulty.gap;
	}

	start() {
		hud.score = 0;
		hud.streak = 0;
		this.endsAt = three.clock.time + ROUND;
		this.nextAt = three.clock.time + 0.4;
		this.light(-1);
		this.show('playing');
	}

	finish() {
		this.light(-1);
		hud.best.value = Math.max(hud.best.value, hud.score);
		three.persist.name = this.name;
		three.persist.board = [...three.persist.board, { name: this.name, score: hud.score, level: this.difficulty.name }]
			.sort((a, b) => b.score - a.score)
			.slice(0, 8);
		this.show('over');
	}

	click(hit) {
		if (this.mode !== 'playing') return;
		const index = hit && hit.name.startsWith('cube_') ? +hit.name.slice(5) : -1;
		if (index < 0 || index !== this.lit) {
			hud.streak = 0;
			return;
		}
		hud.streak += 1;
		hud.score += 10 + Math.min(hud.streak - 1, 9) * 5;
		this.darken();
	}

	@three.systems.frame({ when: () => game.mode === 'playing' })
	tick() {
		const now = three.clock.time;
		hud.left = Math.max(this.endsAt - now, 0);

		if (now >= this.endsAt) { this.finish(); return; }
		if (this.lit >= 0 && now >= this.litUntil) {
			hud.streak = 0;
			this.darken();
		}
		if (this.lit < 0 && now >= this.nextAt) this.light(Math.floor(Math.random() * cubes.length));
	}

	@three.key('space', 'to start')
	play() { if (this.mode === 'menu' || this.mode === 'over') this.start(); }

	@three.key('p', 'to pause')
	pause() {
		if (this.mode === 'playing') this.show('paused');
		else if (this.mode === 'paused') this.show('playing');
	}

	@three.key('m', 'for this menu')
	menu() { if (this.mode !== 'menu') { this.light(-1); this.show('menu'); } }
}

const game = new Game();
game.show('menu');
