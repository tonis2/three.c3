// The release smoke test — **run by hand, on a real GPU, before shipping a
// tag**. It is not a CI step: no GitHub runner has hardware three.c3 is meant
// to draw on, so `.github/workflows/release.yml` checks only that a bundle
// loads and leaves this to a machine that can answer it. From inside an
// extracted zip, from a directory that is not the bundle:
//
//     cd /tmp && ~/Downloads/three-macos-arm64-1.2.3/three \
//       --headless --script <repo>/packaging/smoke.js \
//       --frames 6 --screenshot smoke.png
//
// It must print `SMOKE OK` and write a non-empty PNG. `SMOKE FAIL`, a
// `SHADER_NOT_FOUND` anywhere in the output, or no PNG means the zip is not
// shippable.
//
// It is deliberately not a pretty picture: it exercises
// the three things a bundle can be broken in ways a build cannot catch.
//
//   a shape and a material   -> the mesh/material module compiled, so libslang
//                               and shaders/ both resolved
//   three.light.shadow       -> the SHADOW module compiled too. This is the one
//                               that fails on its own, prints a warning and
//                               exits 0, so nothing but an assertion finds it
//   a written PNG            -> a device was found and a frame was presented
const scene = new three.Scene();
scene.background = 0x3050a0;

const ground = new three.Mesh(new three.BoxGeometry(20, 0.5, 20), new three.MeshLambertMaterial());
ground.color = 0x40a040;
scene.add(ground);

for (let i = 0; i < 3; i++) {
	const m = new three.Mesh(new three.SphereGeometry(1, 20, 14));
	m.position.set((i - 1) * 3, 2, 0);
	m.color = [0xff4040, 0xffd040, 0x40d0ff][i];
	scene.add(m);
}

three.light.set([0.4, 1.0, 0.5], 0.35);
three.light.shadow = true;
three.camera.frameAll();

// shadow.enabled reads back FALSE when the shadow shader did not build — the
// glslang library missing from the bundle is exactly that, and it is otherwise
// a warning on stdout and exit code 0.
// Read it on frame 3, not frame 1: shadow state settles after a pass has had a
// chance to run, and frame 1 reports "no pass yet" whether or not anything is
// wrong.
let frame = 0;
three.setAnimationLoop(() => {
	if (++frame !== 3) return;
	const st = three.stats();
	console.log('SMOKE drawCalls=' + st.drawCalls
		+ ' triangles=' + st.triangles
		+ ' shadowEnabled=' + three.light.shadow.enabled
		+ ' shadowDraws=' + st.shadowDraws);
	if (!three.light.shadow.enabled) console.log('SMOKE FAIL: the shadow shader did not build');
	else if (st.drawCalls < 2) console.log('SMOKE FAIL: nothing was drawn');
	else console.log('SMOKE OK');
});
