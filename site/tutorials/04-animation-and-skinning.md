---
title: Animation and skinning
order: 4
summary: Playing the clips that came in the file, crossfades, sockets, and what a hundred of the same character costs.
---

# Animation and skinning

There is no `AnimationMixer`. A rigged glTF plays **one clip at a time plus a
crossfade**, and the whole of it lives on the `Group` that `instantiate()`
answered with — because a glTF clip drives a subtree, so its root is where it
is played.

```bash
./three --assets ./assets --script 04-animation-and-skinning.js
```

```js
const scene = new three.Scene();
three.light.set([-0.4, -1, -0.45], 0.34);

const ground = new three.Mesh(new three.PlaneGeometry(60, 60));
ground.rotation.x = -Math.PI / 2;
ground.color = [0.2, 0.22, 0.25, 1];
scene.add(ground);

// Any rigged .glb will do. `skins` and `animations` come out of the JSON
// chunk, so this picks a character without loading a byte of geometry.
const rigged = three.inventory().find(file => file.skins > 0 && file.animations.length > 0);

if (!rigged) {
	three.debug.write({
		note: 'No rigged, animated .glb in the assets folder.',
		hint: 'Start three with --assets <folder>. A Mixamo or Quaternius character works.',
	});
}
```

## One character

```js
const asset = rigged ? three.load(rigged.path) : null;
const hero = asset ? asset.instantiate() : null;

if (hero) {
	scene.add(hero);
	three.debug.write({ clips: hero.animations, bones: asset.bones.length });
	hero.play(hero.animations[0], { loop: true });
}
```

`hero.animations` is the clip names the file carried. `play(name, options)`
takes `loop`, `speed`, `time` and `fade`:

- **`fade` is seconds to blend out of whatever is playing.** Asking to fade
  into the clip already playing does nothing, which is exactly what makes
  `play(state.clip, { fade: 0.2 })` safe to call from a state machine every
  frame.
- **Restarting a clip outright is `play()` with no fade.**
- **`time` is where in the clip to start**, and it is the knob a crowd needs.

## A hundred of them

By default `instantiate()` **leaves the skeleton out**. The character is posed
from a table baked once at load, so a hundred copies is a hundred nodes, one
draw call and one `uint` per copy per frame.

```js
const crowd = new three.Group();
scene.add(crowd);

if (asset) {
	const clip = asset.animations[0];
	for (let i = 0; i < 100; i++) {
		const extra = asset.instantiate();
		extra.position.set(three.randFloatSpread(40), 0, three.randFloatSpread(40));
		extra.rotation.y = three.randFloat(0, Math.PI * 2);
		crowd.add(extra);
		// A phase each, or a hundred characters march in lockstep.
		extra.play(clip, { loop: true, time: three.randFloat(0, 2), speed: three.randFloat(0.9, 1.1) });
	}
}
```

Read what that cost:

```js
three.debug.write({
	skinnedDraws: three.stats().skinnedDraws,
	skinnedInstances: three.stats().skinnedInstances,
	poseBytes: three.stats().poseBytes,
});
```

`skinnedInstances` at a hundred with `skinnedDraws` at 1 is the crowd working as
intended. `poseBytes` is what a rigged file costs that an unrigged one does not
— uploaded once per file and shared by every copy, which is why there is no
per-frame palette upload behind a baked character and why a hundred of them is
affordable.

## When you need the bones

Three options, and the default is the first:

| option | what it does | what it costs |
|---|---|---|
| *(default)* | posed from a baked table | one node per copy, one draw call |
| `{ skeleton: true }` | bones stay as objects; writing `bone.rotation` moves the skin | per copy — this is the hero-character option |
| `{ skinning: 'compute' }` | poses vertices in a compute pass | its own draw call and a posed copy of the mesh per frame in flight |

`{ skeleton: true }` is what a look-at, an aim or a foot planted on a slope
needs, because those are the cases where the script has to write a bone
directly. `{ skinning: 'compute' }` only pays off when the same character is
drawn more than once a frame.

## Put the sword in the hand

```js
if (hero && asset.bones.length > 0) {
	const handName = asset.bones.find(b => /hand/i.test(b)) || asset.bones[0];
	const hand = hero.socket(handName);

	const blade = new three.Mesh(new three.BoxGeometry(0.06, 0.9, 0.14));
	blade.position.y = 0.45;
	blade.color = [0.75, 0.78, 0.85, 1];
	hand.add(blade);

	three.debug.write({ socket: handName });
}
```

`asset.bones` is the list of names to pass, and it **has to be**: a rig calls
its hand `mixamorig:RightHand` or `hand.R` or `Bone.014` depending on who
exported it, and the names are not guessable. Asking for a bone the rig does
not have throws with the list of the ones it does.

A baked character has no bone objects at all — dropping them is what makes a
hundred of them cheap — so `socket()` makes a holder and the engine keeps it on
the bone, reading the transform out of the same pose table the character is
drawn from. With `{ skeleton: true }` you get the bone itself. Either way what
comes back is something you can `add()` to.

## Blend shapes

A glTF morph target is a displacement of every vertex, and `mesh.weights` is how
much of each one **this copy** wears.

```js
if (hero) {
	hero.traverse(node => {
		if (node.morphs > 0) {
			node.weights[0] = 0.6;         // one expression, on this copy only
			three.debug.write({ morphMesh: node.name, targets: node.morphs });
		}
	});
}
```

Weights are addressed **by index**, not by name — glTF puts target names in
`mesh.extras.targetNames`, which is a convention rather than a required field.
They are per copy and free, like `color` and `variant`, so two faces built from
one head mesh wear different expressions and stay one draw call. An all-zero
vector takes the copy off the morph path entirely. And a file that *animates*
its weights just works: `play()` drives them like any other channel, and a
crossfade blends them.

```js
three.camera.frameAll();
three.camera.orbit(20, 14, 26);
three.debug.write(scene.stats());
```

Next: [Input and systems](05-input-and-systems.html) — turning key presses into
movement, and turning one big animation loop into a frame you can read.
