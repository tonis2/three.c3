// A landscape built from a description rather than from tiles — plan.md §18.4.
//
// Everything the village did by hand is a call here:
//
//   the ground        one three.Field, filled with noise and stamped
//   the river         carve() along a polyline
//   the road          carve() along another, shallower
//   the building pads flatten(), levelled to the mean under the rect
//   where things go   terrain.heightAt / normalAt, the SAME grid the mesh is
//   the trees         three.scatter(), keeping out of both corridors
//
// Three draw calls: the terrain is one asset however many segments it has, and
// the trees and the buildings are one bucket each.
//
//   ./build/three --headless --script examples/terrain_valley.js --screenshot out.png

const scene = new three.Scene();
scene.background = 0x0b1020;
const lambert = new three.MeshLambertMaterial();

const W = 240, SEG = 160;
// One polyline: the river. Carved into the height field and stroked into the mask.
const river = [[-120, -70], [-60, -40], [-10, 10], [30, 55], [90, 100]];
const road  = [[-110, 40], [-40, 20], [20, 25], [80, 5], [118, -20]];

const heights = new three.Field({ width: W, depth: W, segments: SEG })
  .fill((x, z) => Math.sin(x * 0.035) * 7 + Math.cos(z * 0.028) * 6 + Math.sin((x - z) * 0.017) * 4)
  .carve(river, 16, 7, 10)
  .carve(road, 9, 0.8, 4)
  .flatten({ x: -50, z: 60, width: 34, depth: 26 }, undefined, 6)
  .flatten({ x: 55, z: -55, width: 28, depth: 28 }, undefined, 6);

const g = new three.TerrainGeometry({ width: W, depth: W, segments: SEG, skirt: 6, heights });
const ground = new three.Mesh(g, lambert);
ground.color = 0x59813f;
scene.add(ground);

// The pads carry buildings, placed with heightAt — no hand-written ground().
const box = new three.BoxGeometry(1, 1, 1);
for (const [x, z, w, h, d] of [[-50, 60, 16, 9, 12], [-50, 52, 10, 7, 8], [55, -55, 14, 10, 14]]) {
  const m = new three.Mesh(box, lambert);
  m.scale.set(w, h, d);
  m.position.set(x, g.heightAt(x, z) + h / 2, z);
  m.color = 0xbdbaae;
  scene.add(m);
}
// Trees: three.scatter does the LCG, the rejection, the keep-outs and the slope.
const cone = new three.ConeGeometry(2.2, 9, 8);
const spots = three.scatter({
  count: 300, seed: 7, onTerrain: g, spacing: 6, minHeight: 1.5, maxSlope: 21,
  avoid: [{ path: river, width: 26 }, { path: road, width: 16 },
          { x: -50, z: 60, radius: 26 }, { x: 55, z: -55, radius: 24 }],
});
for (const p of spots) {
  const t = new three.Mesh(cone, lambert);
  t.position.set(p.x, p.y + 4.5, p.z);
  t.color = 0x2c5a24;
  scene.add(t);
}
const planted = spots.length;
three.light.set([0.55, 0.6, 0.55], 0.33);
three.light.shadow = { enabled: true, size: 2048, distance: 220 };
three.camera.lookAt(0, 0, 0);
three.camera.orbit(30, 24, 235);
three.render(scene, three.camera);
const s = three.stats();
console.log('valley: ' + JSON.stringify({ trees: planted, draws: s.drawCalls, triangles: s.triangles, gpuMs: +s.gpuMs.toFixed(3), shadowMs: +s.shadowMs.toFixed(3) }));
