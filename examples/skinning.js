// skinning.js — the three ways a rigged character can be posed
//
// Run it:
//
//     ./build/three --script examples/skinning.js
//     ./build/three --script examples/skinning.js --mcp   # and attach an agent
//
// Once it is running: `space` pauses and resumes the clock, `1` `2` `3` isolate
// one row at a time and `0` shows all of them, `d` toggles the shadow map, and
// `s` prints the frame's cost.
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
// work, not less, and it is here so you can see that it is indistinguishable.
// It splits its own draw call, which `preskinnedInstances` counts.
//
// **Its payoff is the second pass, and there is one now.** `d` toggles the
// shadow map. With it on, every character is drawn twice — once into the depth
// map from the light and once into the frame — and the back row blends its
// vertices once for both while the other two rows blend twice. Press `s` with
// shadows on and off and watch `shadowDraws` rather than `drawCalls`, which
// counts the colour pass alone.
//
// The ground is here for the shadows to fall on. Everything opaque casts and
// everything shaded receives; there is no per-object switch, because two copies
// of one mesh disagreeing about casting would be two draw calls.
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
// Something for the shadows to land on.
// ---------------------------------------------------------------------------

const ground = new three.Mesh(
	new three.PlaneGeometry(COPIES * SPACING + 14, 16),
	new three.MeshLambertMaterial({ color: 0x9aa0a6 })
);
ground.rotation.x = -Math.PI / 2;
// A hair below zero, so the characters' feet are not coplanar with it — two
// surfaces at exactly the same depth is a speckle rather than a contact.
ground.position.y = -0.01;
scene.add(ground);

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

// On from the start, so the first frame shows what the back row is for. `d`
// turns it off, and turning it off is free — no pass is recorded, the draw list
// goes back to being camera-culled, and the map stays allocated for the next
// press.
three.light.shadow = true;

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
		+ `shadow draws ${s.shadowDraws} · `
		+ `poses ${(s.poseBytes / 1024).toFixed(1)} KiB · ${s.gpuMs.toFixed(2)} ms`
	);
}

three.onKeyDown('space', () => {
	// The clock rather than a flag of this scene's own, and the difference is
	// visible: a flag here would hold the procedural bone below and leave the
	// *clips* playing, because clips are advanced by the host. Zero holds both.
	three.clock.timeScale = three.clock.paused ? 1 : 0;
	console.log(three.clock.paused ? 'held' : 'running');
});
three.onKeyDown('0', () => show(-1));
three.onKeyDown('1', () => show(0));
three.onKeyDown('2', () => show(1));
three.onKeyDown('3', () => show(2));
three.onKeyDown('s', () => report());
three.onKeyDown('d', () => {
	three.light.shadow.enabled = !three.light.shadow.enabled;
	console.log(three.light.shadow.enabled ? 'shadows on' : 'shadows off');
});

console.log(`${COPIES} × 3 characters from ${PATH}`);
console.log('space pauses · 1/2/3 isolate a row · 0 shows all · d toggles shadows · s prints the cost');
report();

// The clock. The two clip-driven rows advance themselves — a player is per
// instance and the host steps them — so the only thing this callback does is
// the middle row, which has no clip and exists to be written to.
three.setAnimationLoop(() => {
	const t = three.clock.time;
	for (const h of heroes) {
		if (!h.bone) continue;
		// A procedural pose: the thing a baked table cannot express, because
		// nothing sampled it at load. Writing the bone moves the skin because
		// this character was instantiated with a skeleton.
		h.bone.rotation.z = Math.sin(t * 1.6 + h.phase) * 1.2;
	}
});
