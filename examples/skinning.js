// skinning.js — the three ways a rigged character can be posed
//
// Run it:
//
//     ./build/three --script examples/skinning.js
//     ./build/three --script examples/skinning.js --mcp   # and attach an agent
//
// Once it is running: `space` pauses and resumes the clock, `1` `2` `3` isolate
// one row at a time and `0` shows all of them, and `s` prints the frame's cost.
//
// What it is here to show
// -----------------------
// **A crowd is one draw call, and that is the whole design.** The front row is
// twenty copies of one clip at twenty different phases. They disagree about one
// `uint` each — where in the baked pose table their current frame sits — and
// about nothing else, so they coalesce into a single `vkCmdDrawIndexed`. Nothing
// is uploaded per frame for them. Press `s` and watch `skinnedInstances` climb
// while `skinnedDraws` does not.
//
// **A clip is baked once, at load.** Every clip of every skin is sampled at 30
// fps into a device-local table the moment the file first draws, and every copy
// of the character in the scene reads that one table. `poseBytes` is what it
// cost; it does not grow when you add characters, which is the property that
// makes the front row affordable.
//
// **The middle row is posed by hand, with no clip playing at all.**
// `instantiate({ skeleton: true })` keeps the file's bones as objects and
// switches that character onto a palette computed from them every frame — so
// writing `bone.rotation.z` moves the skin. That is the half a baked table
// cannot do: aim, look-at, foot-on-a-slope, ragdoll. It costs per copy, which is
// why it is not the default.
//
// **The back row draws the same picture through a compute pass.** Same clip,
// same phases, same arithmetic — done in a dispatch before the frame's first
// draw instead of in the vertex shader. Under one render pass that is *more*
// work, not less, and it is here so you can see that it is indistinguishable:
// its payoff is drawing the same character in a second pass (a shadow map), and
// it splits its own draw call in the meantime. `preskinnedInstances` counts it.
//
// The model is the test fixture — a two-bone bar, deliberately tiny, whose bend
// is worked out by hand in test/fixtures/make_skinned.py. Point PATH at a real
// character and the rows fill with it instead.

const PATH = 'test/fixtures/skinned.glb';
const CLIP = 'Bend';

const scene = new three.Scene();
const asset = await three.load(PATH);

if (!asset.animations.includes(CLIP)) {
	throw new Error(
		`${PATH} has no clip called "${CLIP}" — it has: ${asset.animations.join(', ') || '(none)'}`
	);
}

const COPIES = 12;
const SPACING = 1.5;
const left = -((COPIES - 1) * SPACING) / 2;

// ---------------------------------------------------------------------------
// Row 1 — the crowd. Baked, phased, one draw call.
// ---------------------------------------------------------------------------

const crowd = [];
for (let i = 0; i < COPIES; i++) {
	const c = asset.instantiate();
	scene.add(c);
	c.position.set(left + i * SPACING, 0, 2.5);
	// The phase. One clip, twenty entry points into it — this is the argument
	// that makes a crowd look like a crowd rather than a chorus line.
	c.play(CLIP, { loop: true, time: (i / COPIES) * 2 });
	crowd.push(c);
}

// ---------------------------------------------------------------------------
// Row 2 — hand-posed. Live palette, no clip.
// ---------------------------------------------------------------------------

const heroes = [];
for (let i = 0; i < COPIES; i++) {
	const h = asset.instantiate(undefined, { skeleton: true });
	scene.add(h);
	h.position.set(left + i * SPACING, 0, 0);

	// The bones are real objects here, so find the one the clip would have
	// driven and drive it ourselves instead.
	let bone = null;
	h.traverse((o) => { if (o.name === 'Mid') bone = o; });
	heroes.push({ object: h, bone, phase: (i / COPIES) * Math.PI * 2 });
}

// ---------------------------------------------------------------------------
// Row 3 — the same clip, posed by the compute pass.
// ---------------------------------------------------------------------------

const computed = [];
for (let i = 0; i < COPIES; i++) {
	const c = asset.instantiate(undefined, { skinning: 'compute' });
	scene.add(c);
	c.position.set(left + i * SPACING, 0, -2.5);
	c.play(CLIP, { loop: true, time: (i / COPIES) * 2 });
	computed.push(c);
}

// **Angle first, then fit.** `frameAll` backs off far enough to see everything
// *from where the camera currently is*, so orbiting afterwards re-aims a
// distance that was chosen for a different view and crops the ends of the rows.
// `orbit` takes degrees and world units, positionally, and any argument may be
// left out.
three.camera.orbit(0, 20);
three.camera.frameAll();
// And a little further back than the tight fit, so the ends of the rows are
// inside the frame rather than on its edge.
three.camera.orbit(undefined, undefined, three.camera.toJSON().distance * 1.15);

// ---------------------------------------------------------------------------

const rows = [crowd, heroes.map((h) => h.object), computed];
const names = ['baked crowd', 'hand-posed (live palette)', 'compute pre-skinned'];

function show(which) {
	rows.forEach((row, i) => {
		const on = which < 0 || which === i;
		row.forEach((o) => { o.visible = on; });
	});
	console.log(which < 0 ? 'all three rows' : names[which]);
}

function report() {
	const s = three.stats();
	console.log(
		`draws ${s.drawCalls} (${s.skinnedDraws} skinned) · `
		+ `${s.skinnedInstances} characters, ${s.preskinnedInstances} through compute · `
		+ `poses ${(s.poseBytes / 1024).toFixed(1)} KiB · ${s.gpuMs.toFixed(2)} ms`
	);
}

let running = true;
three.onKeyDown('space', () => {
	running = !running;
	console.log(running ? 'running' : 'held');
});
three.onKeyDown('0', () => show(-1));
three.onKeyDown('1', () => show(0));
three.onKeyDown('2', () => show(1));
three.onKeyDown('3', () => show(2));
three.onKeyDown('s', () => report());

console.log(`${COPIES} × 3 characters from ${PATH}`);
console.log('space pauses · 1/2/3 isolate a row · 0 shows all · s prints the cost');
report();

// The clock. The two clip-driven rows advance themselves — a player is per
// instance and the host steps them — so the only thing this callback does is
// the middle row, which has no clip and exists to be written to.
three.setAnimationLoop((ms) => {
	if (!running) return;
	const t = ms / 1000;
	for (const h of heroes) {
		if (!h.bone) continue;
		// A procedural pose: the thing a baked table cannot express, because
		// nothing sampled it at load. Writing the bone moves the skin because
		// this character was instantiated with a skeleton.
		h.bone.rotation.z = Math.sin(t * 1.6 + h.phase) * 1.2;
	}
});
