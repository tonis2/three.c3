// A RuneScape-shaped village: the river, the bridge, the road down the middle,
// the two-storey house on the west, the sheep pen, the castle on its flagstones.
//
// Greybox massing on six shared geometries — four thousand placed objects in
// six draw calls — with a texture pass laid over it afterwards, in place. See
// dress() at the bottom for why that pass projects from world space instead of
// reading the meshes' own uvs; it is the thing that lets one unit box, scaled,
// be every building in the village and still take a stone wall.
//
// P.textured = false goes back to flat colour.
//
// Run it:  ./build/three --script examples/lumbridge.js
// or from the MCP:  V.build({ ... })  to re-site anything and rebuild.

globalThis.V = {
  P: {
    tile: 4, N: 28, amp: 3.2, jitter: 0.008, rim: 0,
    riverHalf: 5.5, waterY: -0.55, bedY: -2.4,
    ambient: 0.46, sun: [0.42, 0.86, 0.30], shadow: 2048,
    trees: 78, forest: 150, sky: 0x090c12, textured: true,
    cam: { look: [2, 2, -8], yaw: 0, pitch: 33, dist: 80 },
  },
  C: {
    dirt: 0x6f5c45, dirt2: 0x6a5741, cobble: 0x8c8b84, cobble2: 0x86857e,
    mud: 0x6f6349, stone: 0x8b8a84, stone2: 0x76756f, roof: 0x8a4634,
    wood: 0x6a4c31, water: 0x3f6288, bed: 0x554e3c,
    trunk: 0x54402c, leaf: 0x3a5a2a, leaf2: 0x2e4a22,
  },
  // x, z, footprint w, footprint d. The ground is levelled under each one.
  SITES: {
    front: [-1, 27, 17, 14], west: [-27, -3, 17, 12], westWing: [-27, -14, 11, 9],
    mid: [7, -17, 12, 9.5], n1: [-15, -47, 10, 8], n2: [7, -57, 9, 7],
    n3: [-35, -41, 11, 8], n4: [-46, -12, 10, 8], e1: [42, -30, 12, 9],
    e2: [58, -54, 10, 8], e3: [48, 16, 11, 9], s1: [-30, 56, 10, 8],
    mill: [-4, -76, 9, 9], castle: [-58, 34, 30, 30],
  },
  COURT: [-74, 12, -40, 56],
  ROADS: [
    { pts: [[-4, 86], [-7, 40], [-10, 4], [-8, -34], [-2, -66], [-4, -86]], w: 3.2 },
    { pts: [[-9, -8], [4, -9], [16, -8]], w: 3.0 },
    { pts: [[-8, 22], [-24, 25], [-42, 27]], w: 3.0 },
    { pts: [[34, -72], [33, -30], [35, 4], [40, 40]], w: 2.6 },
  ],
  FENCES: [
    [[[-2, -30], [15, -31], [16, -47], [-1, -46]], true],   // sheep pen
    [[[38, -14], [66, -16], [64, -46], [36, -44]], true],   // cow field, east bank
    [[[1, -23], [14, -23], [15, -12]], false],              // the yard by the centre house
    [[[-19, 8], [-19, 20], [-4, 21]], false],
    [[[-42, -22], [-42, -4], [-36, -2]], false],
  ],

  build(over) {
    const P = Object.assign({}, this.P, over || {});
    if (over && over.cam) P.cam = Object.assign({}, this.P.cam, over.cam);
    const C = this.C, SITES = this.SITES, COURT = this.COURT;

    const S = new three.Scene();
    S.background = P.sky;
    three.light.set(P.sun, P.ambient);
    three.light.shadow = { enabled: true, size: P.shadow };

    const G = {
      box: new three.BoxGeometry(1, 1, 1),
      cyl: new three.CylinderGeometry(0.5, 0.5, 1, 10),
      cone: new three.ConeGeometry(0.5, 1, 10),
      sph: new three.SphereGeometry(0.5, 10, 7),
      pyr: new three.ConeGeometry(0.5, 1, 4),
      // The river is NOT a tile like the rest. A box's top face has four
      // corners four units apart, and a vertex body can only move those four:
      // sin(x * 0.85) sampled that coarsely is undersampled into nothing, and
      // the water sits dead flat however hard the shader waves at it.
      water: new three.PlaneGeometry(P.tile, P.tile, 6, 6),
      // a gabled roof as a solid: four eaves corners and a two-point ridge along X
      gable: new three.ConvexGeometry([
        [-0.5, 0, -0.5], [0.5, 0, -0.5], [-0.5, 0, 0.5], [0.5, 0, 0.5],
        [-0.5, 1, 0], [0.5, 1, 0],
      ]),
    };
    const slab = (p, x, z, w, h, d, base, color, ry) => {
      const o = new three.Mesh(G.box);
      o.scale.set(w, h, d); o.position.set(x, base + h / 2, z);
      if (ry) o.rotation.y = ry;
      o.color = color; p.add(o); return o;
    };
    const col = (p, geo, x, z, r, h, base, color) => {
      const o = new three.Mesh(geo);
      o.scale.set(r * 2, h, r * 2); o.position.set(x, base + h / 2, z);
      o.color = color; p.add(o); return o;
    };

    const riverX = z => 24 + 9 * Math.sin(z * 0.021 + 0.6) + 4 * Math.sin(z * 0.052);
    const bumps = (x, z) =>
        Math.sin(x * 0.024 + 1.7) * Math.cos(z * 0.019 - 0.4)
      + Math.sin(x * 0.013 - z * 0.016 + 2.2) * 0.75
      + Math.cos(x * 0.037 + z * 0.029) * 0.35;

    // Rects forced level, so nothing stands on a step. Filled by plot() before
    // the tiles are laid, which is why every site is declared up front.
    const flats = [];
    function ground(x, z) {
      for (const f of flats) {
        if (Math.abs(x - f[0]) < f[2] / 2 && Math.abs(z - f[1]) < f[3] / 2) return f[4];
      }
      const d = Math.abs(x - riverX(z));
      const t = Math.min(1, Math.max(0, (d - 8) / 20));   // the river sits in its own flat
      const r = Math.max(Math.abs(x), Math.abs(z));
      const rim = Math.min(1, Math.max(0, (r - 52) / 48));
      return bumps(x, z) * P.amp * t + rim * rim * P.rim * t;
    }
    const plot = (x, z, w, d) => { const y = ground(x, z); flats.push([x, z, w + 4, d + 4, y]); return y; };

    function segDist(px, pz, ax, az, bx, bz) {
      const dx = bx - ax, dz = bz - az, L = dx * dx + dz * dz;
      let t = L > 0 ? ((px - ax) * dx + (pz - az) * dz) / L : 0;
      t = Math.max(0, Math.min(1, t));
      return Math.hypot(px - (ax + dx * t), pz - (az + dz * t));
    }
    const ROADS = this.ROADS;
    function roadNear(x, z) {
      for (const r of ROADS) for (let i = 0; i < r.pts.length - 1; i++) {
        if (segDist(x, z, r.pts[i][0], r.pts[i][1], r.pts[i + 1][0], r.pts[i + 1][1]) < r.w) return true;
      }
      return false;
    }

    const Y = {};
    for (const k in SITES) { const s = SITES[k]; Y[k] = plot(s[0], s[1], s[2], s[3]); }
    flats.push([(COURT[0] + COURT[2]) / 2, (COURT[1] + COURT[3]) / 2,
                COURT[2] - COURT[0], COURT[3] - COURT[1], Y.castle]);

    // ---- the land, one box per tile; the colour is what the tile IS
    const land = new three.Group(); land.name = "land"; S.add(land);
    const T = P.tile, N = P.N;
    const river = [];
    const flow = new three.Group(); flow.name = 'river'; S.add(flow);
    for (let ix = -N; ix <= N; ix++) for (let iz = -N; iz <= N; iz++) {
      const x = ix * T, z = iz * T, d = Math.abs(x - riverX(z));
      let top, color;
      const j = ((((ix * 13 + iz * 7) % 4) + 4) % 4) * P.jitter;
      if (d < P.riverHalf) {
        top = P.bedY - 0.9 + 0.3 * Math.sin(x * 0.7 + z * 0.5); color = C.bed;
      } else if (d < P.riverHalf + 3.5) {
        top = ground(x, z) - 0.3; color = C.mud;
      } else if (x > COURT[0] && x < COURT[2] && z > COURT[1] && z < COURT[3]) {
        top = ground(x, z); color = ((ix + iz) & 1) ? C.cobble : C.cobble2;
      } else if (roadNear(x, z)) {
        top = ground(x, z); color = ((ix * 7 + iz * 3) & 1) ? C.dirt : C.dirt2;
      } else {
        top = ground(x, z);
        color = [0.285 + j, 0.435 + j * 1.5, 0.135 + j * 0.6];
      }
      // 8 and not 30: a tile's buried side faces are rasterised into the
      // shadow map every frame, and depth 30 cost 1.1 ms of a 3.9 ms frame for
      // geometry no angle can see. 8 and not 3 because the ground steps ~3
      // units at the riverbank and under a levelled pad. plan.md §10.
      slab(land, x, z, T, top + 8, T, -8, color);
      if (d < P.riverHalf) {
        const w = new three.Mesh(G.water);          // PlaneGeometry is vertical: lay it down
        w.rotation.x = -Math.PI / 2;
        w.position.set(x, P.waterY, z);
        w.color = C.water;                          // what it looks like with P.textured off
        flow.add(w);
        river.push(w);
      }
    }

    // ---- buildings: a stone box under a gabled prism, one Group each
    function house(key, wallH, rise, wallColor) {
      const s = SITES[key], g = new three.Group();
      g.name = key; g.position.set(s[0], Y[key], s[1]);
      slab(g, 0, 0, s[2], wallH, s[3], 0, wallColor || C.stone);
      const r = new three.Mesh(G.gable);
      r.scale.set(s[2] + 1.4, rise, s[3] + 1.4);
      r.position.set(0, wallH, 0); r.color = C.roof;
      g.add(r); S.add(g); return g;
    }
    slab(house("front", 4.6, 5.4), -6, 1, 1.3, 11.5, 1.3, 0, C.stone2);   // chimney
    slab(house("west", 8.2, 4.8), 6.5, 0, 1.3, 15.0, 1.3, 0, C.stone2);
    house("westWing", 4.4, 3.4);
    slab(house("mid", 4.6, 3.6), 0, 6.2, 9, 3.0, 3.2, 0, C.wood);         // porch
    house("n1", 4.4, 3.2); house("n2", 4.2, 3.0); house("n3", 4.6, 3.4);
    house("n4", 4.4, 3.2); house("e1", 4.6, 3.4); house("e2", 4.4, 3.2);
    house("e3", 4.4, 3.2); house("s1", 4.4, 3.2);

    { const g = new three.Group(); g.name = "windmill";
      g.position.set(SITES.mill[0], Y.mill, SITES.mill[1]);
      col(g, G.cyl, 0, 0, 3.4, 13, 0, C.stone);
      col(g, G.pyr, 0, 0, 4.3, 5, 13, C.roof);
      for (let i = 0; i < 4; i++) {
        const s = new three.Mesh(G.box);
        s.scale.set(1.0, 10, 0.4); s.position.set(0, 11.5, 3.9);
        s.rotation.z = i * Math.PI / 2; s.color = C.wood; g.add(s);
      }
      S.add(g); }

    { const g = new three.Group(); g.name = "castle";
      g.position.set(SITES.castle[0], Y.castle, SITES.castle[1]);
      slab(g, 0, 0, 26, 17, 26, 0, C.stone2);
      slab(g, 0, 0, 28, 2.0, 28, 17, C.stone2);                            // parapet
      for (const p of [[-13, -13], [13, -13], [-13, 13], [13, 13]]) {
        col(g, G.cyl, p[0], p[1], 4.2, 22, 0, C.stone2);
        col(g, G.cyl, p[0], p[1], 4.6, 1.6, 22, C.stone);
      }
      slab(g, 15, -21, 4, 9, 30, 0, C.stone2);                             // curtain wall
      S.add(g); }

    { const bz = -8, bx = riverX(bz), g = new three.Group();   // wherever the river is at z = -8
      g.name = "bridge"; g.position.set(bx, 0, bz);
      slab(g, 0, 0, 17, 0.5, 4.5, 1.0, C.wood);
      for (const sz of [-2.4, 2.4]) {
        slab(g, 0, sz, 17, 0.35, 0.35, 2.1, C.wood);
        for (const px of [-7, -3.5, 0, 3.5, 7]) slab(g, px, sz, 0.4, 1.1, 0.4, 1.0, C.wood);
      }
      for (const px of [-4.5, 4.5]) for (const pz of [-1.8, 1.8]) col(g, G.cyl, px, pz, 0.35, 4.5, -3.4, C.wood);
      S.add(g); }

    // ---- fences: every post stands on its own ground, rails span the average
    const fences = new three.Group(); fences.name = "fences"; S.add(fences);
    for (const f of this.FENCES) {
      const pts = f[0], closed = f[1], n = pts.length, last = closed ? n : n - 1;
      for (let i = 0; i < last; i++) {
        const a = pts[i], b = pts[(i + 1) % n];
        const dx = b[0] - a[0], dz = b[1] - a[1];
        const len = Math.hypot(dx, dz), ry = Math.atan2(dx, dz);
        const posts = Math.max(2, Math.round(len / 3.2));
        for (let p = 0; p <= posts; p++) {
          const t = p / posts, px = a[0] + dx * t, pz = a[1] + dz * t;
          slab(fences, px, pz, 0.35, 2.0, 0.35, ground(px, pz), C.wood);
          if (p === posts) continue;
          const u = t + 1 / posts, qx = a[0] + dx * u, qz = a[1] + dz * u;
          const my = (ground(px, pz) + ground(qx, qz)) / 2;
          slab(fences, (px + qx) / 2, (pz + qz) / 2, 0.2, 0.2, len / posts, my + 1.45, C.wood, ry);
          slab(fences, (px + qx) / 2, (pz + qz) / 2, 0.2, 0.2, len / posts, my + 0.75, C.wood, ry);
        }
      }
    }

    // ---- trees through the village, seeded so the layout is reproducible
    let seed = 20250824;
    const rnd = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
    const trees = new three.Group(); trees.name = "trees"; S.add(trees);
    const keepout = [[riverX(-8), -8, 14]];
    for (const k in SITES) { const s = SITES[k]; keepout.push([s[0], s[1], Math.max(s[2], s[3]) * 0.75 + 4]); }
    let placed = 0;
    for (let i = 0; i < 3000 && placed < P.trees; i++) {
      const x = -108 + rnd() * 216, z = -108 + rnd() * 216;
      if (Math.abs(x - riverX(z)) < P.riverHalf + 5) continue;
      if (roadNear(x, z)) continue;
      if (x > -2 && x < 16 && z > -47 && z < -30) continue;
      if (x > 36 && x < 66 && z > -46 && z < -14) continue;
      if (x > COURT[0] - 4 && x < COURT[2] + 4 && z > COURT[1] - 4 && z < COURT[3] + 4) continue;
      let hit = false;
      for (const b of keepout) if (Math.hypot(x - b[0], z - b[1]) < b[2]) { hit = true; break; }
      if (hit) continue;
      const s = 0.7 + rnd() * 0.8, y = ground(x, z), h = 5.2 * s;
      col(trees, G.cyl, x, z, 0.5 * s, h, y, C.trunk);
      if (rnd() < 0.78) col(trees, G.sph, x, z, 3.3 * s, 5.4 * s, y + h - 1.4 * s, C.leaf);
      else              col(trees, G.cone, x, z, 3.0 * s, 6.4 * s, y + h - 1.4 * s, C.leaf2);
      placed++;
    }

    this.ground = ground; this.riverX = riverX; this.Y = Y; this.G = G; this.scene = S;
    const ring = this.forest(P.forest);
    const dressed = P.textured ? this.dress(river) : (three.setAnimationLoop(null), null);

    // Nothing here moves again: the sun is fixed, and the village is the village.
    // So every caster goes into the shadow map once and stays there — plan.md
    // §19.3, which measured 0.5 ms of depth-only geometry a frame on exactly this
    // scene, rasterised to produce an image identical to the previous frame's.
    // Watch three.stats().shadowStaticDraws: it is the caster count on the frame
    // after a rebuild and 0 on every frame between. The river keeps its wave —
    // a depth pass runs no vertex body, so the water's shadow was always its flat
    // quad and marking it static changes nothing about the picture.
    S.traverse(o => { o.static = true; });

    three.camera.lookAt(P.cam.look[0], P.cam.look[1], P.cam.look[2]);
    three.camera.orbit(P.cam.yaw, P.cam.pitch, P.cam.dist);
    three.render(S, three.camera);
    three.unloadUnused();
    return { stats: S.stats(), trees: placed, forest: ring, water: river.length, dressed };

  },

  // The treeline that closes the horizon: the map is a square that ends, and
  // this is what stands between its edge and the black.
  forest(count) {
    const S = this.scene, G = this.G, C = this.C;
    const ground = this.ground, riverX = this.riverX;
    const g = new three.Group(); g.name = "forest"; S.add(g);
    let seed = 4242;
    const rnd = () => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed / 4294967296; };
    const col = (geo, x, z, r, h, base, color) => {
      const o = new three.Mesh(geo);
      o.scale.set(r * 2, h, r * 2); o.position.set(x, base + h / 2, z);
      o.color = color; g.add(o);
    };
    let n = 0;
    for (let i = 0; i < count * 10 && n < count; i++) {
      const a = rnd() * Math.PI * 2, r = 74 + rnd() * 34;
      const x = Math.cos(a) * r, z = Math.sin(a) * r;
      if (Math.abs(x) > 106 || Math.abs(z) > 106) continue;
      if (Math.abs(x - riverX(z)) < 10) continue;
      const s = 0.85 + rnd() * 0.9, y = ground(x, z), h = 5.2 * s;
      col(G.cyl, x, z, 0.5 * s, h, y, C.trunk);
      if (rnd() < 0.6) col(G.sph, x, z, 3.4 * s, 5.6 * s, y + h - 1.4 * s, C.leaf);
      else             col(G.cone, x, z, 3.1 * s, 6.8 * s, y + h - 1.4 * s, C.leaf2);
      n++;
    }
    return n;
  },

  // One procedural image, built here rather than loaded. f(x, y, N) answers
  // with sRGB bytes; the engine de-gammas on the way in, so a body reading it
  // gets linear and nothing in this file applies a gamma of its own.
  image(N, f) {
    const px = new Uint8Array(N * N * 4);
    for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
      const c = f(x, y, N), i = (y * N + x) * 4;
      px[i] = c[0]; px[i + 1] = c[1]; px[i + 2] = c[2]; px[i + 3] = 255;
    }
    return new three.DataTexture(px, N, N, { colorSpace: 'srgb', generateMipmaps: true });
  },

  // ---------------------------------------------------------------------------
  // The texture pass.
  //
  // It runs over meshes that are ALREADY in the scene. Nothing is rebuilt, no
  // geometry is touched, no instance is added: a material is assigned to a mesh
  // that is standing in the frame, and the next render has it. That is the only
  // kind of live edit this engine offers besides the transform — geometry is
  // immutable, and `mesh.geometry = other` is a getter with no setter, so the
  // write is swallowed rather than refused. Do not reach for it.
  //
  // WHY THE SHADER PROJECTS FROM WORLD SPACE. Every building here is the same
  // 1x1x1 BoxGeometry at a different scale — 17 x 4.6 x 14 for the one in the
  // foreground, 9 x 4.2 x 7 for the small ones — which is exactly what keeps
  // twelve houses in one draw call. But a box's uvs are 0..1 per face whatever
  // it is scaled to, so a map read through them would put stone blocks twice as
  // wide on the big house as on the small one, and the trick that bought the
  // draw call would be the thing that ruined the look. Sampling s.position on
  // all three axes and weighting by the normal ignores uv entirely: the block
  // is 1.2m on every wall in the village, and the roof course is the same depth
  // whatever the roof. The sampler wraps, so no frac() and the mip chain stays
  // clean across a tile boundary.
  //
  // Cost: three draw calls, one per material, and 44 KB of image. The buckets
  // split where a geometry is half dressed — the cylinders here are castle
  // towers and windmill AND tree trunks, and only the first two get a material.
  // ---------------------------------------------------------------------------
  dress(river) {
    const S = this.scene;
    const hash = (a, b) => { const n = Math.sin(a * 127.1 + b * 311.7) * 43758.5453; return n - Math.floor(n); };

    const stone = this.image(64, (x, y, N) => {
      const rowH = 8, row = Math.floor(y / rowH);
      const u = ((x / N) + ((row & 1) ? 0.5 : 0)) % 1;          // every other course offset
      const cols = 4, idx = Math.floor(u * cols);
      const fu = (u * cols) % 1, fv = (y % rowH) / rowH;
      const mortar = fu < 0.055 || fu > 0.945 || fv < 0.11 || fv > 0.89;
      let v = mortar ? 0.50 : 0.68 + hash(idx + 1, row + 1) * 0.20;
      v += (hash(x * 3, y * 7) - 0.5) * 0.07;
      return [v * 178, v * 176, v * 168];
    });

    const shingle = this.image(64, (x, y, N) => {
      const rowH = 8, row = Math.floor(y / rowH), fv = (y % rowH) / rowH;
      const u = ((x / N) + ((row & 1) ? 0.5 : 0)) % 1;
      const cols = 6, idx = Math.floor(u * cols), fu = (u * cols) % 1;
      const gap = fu < 0.06;
      // darker at the head of each course, where the one above overlaps it
      let v = gap ? 0.46 : (0.74 + hash(idx + 3, row + 5) * 0.22) * (0.72 + 0.34 * fv);
      v += (hash(x * 5, y * 11) - 0.5) * 0.05;
      return [v * 196, v * 104, v * 78];
    });

    const triplanar = `
      float3 shade(Surface s) {
        float3 n = abs(s.normal);
        float3 w = n / max(n.x + n.y + n.z, 1e-4);
        float3 p = s.position * scale;
        float3 c = albedo_map.Sample(p.zy).rgb * w.x
                 + albedo_map.Sample(p.xz).rgb * w.y
                 + albedo_map.Sample(p.xy).rgb * w.z;
        return c * tint * lambert(s.normal);
      }`;
    const wallMat = new three.ShaderMaterial({
      fragment: triplanar,
      uniforms: { scale: 0.21, tint: [1, 1, 1] },
      textures: { albedo_map: stone },
    });
    const roofMat = new three.ShaderMaterial({
      fragment: triplanar,
      uniforms: { scale: 0.30, tint: [1, 1, 1] },
      textures: { albedo_map: shingle },
    });

    let walls = 0, roofs = 0;
    const byShape = g => {
      for (const c of g.children) {
        if (!c.geometry) continue;
        if (c.geometry.type === 'ConvexGeometry') { c.material = roofMat; roofs++; }
        else if (c.geometry.type === 'BoxGeometry') { c.material = wallMat; walls++; }
      }
    };
    for (const k in this.SITES) { const g = S.getObjectByName(k); if (g) byShape(g); }

    const castle = S.getObjectByName('castle');
    if (castle) for (const c of castle.children) { c.material = wallMat; walls++; }

    const mill = S.getObjectByName('windmill');
    if (mill) {                                  // tower and cap only; the sails stay wood
      mill.children[0].material = wallMat; walls++;
      mill.children[1].material = roofMat; roofs++;
    }

    // The water is the other kind of live edit: a VERTEX body reshapes the mesh
    // per frame with no upload and no new asset, and `t` is a four-byte uniform
    // write. bounds is how far it can push a vertex — culling tests the
    // undisplaced box, so without it a moved crest can be dropped on screen.
    const waterMat = new three.ShaderMaterial({
      uniforms: { t: 0, deep: [0.09, 0.18, 0.31] },
      bounds: 0.3,
      // Two things this cost a compile each to learn.
      //
      // The vertex and fragment bodies are ONE Slang module, so a helper
      // declared in both is "function 'ripple' already has a body". Declare it
      // in the vertex string, which comes first, and call it from the fragment.
      //
      // Every uniform arrives as `#define t (push.t)`, so a parameter named `t`
      // expands to `float push.t` and the module will not parse. Hence `ph`.
      vertex: `
        float3 ripple(float2 q, float ph) {
          return float3(sin(q.x * 0.85 + ph * 1.6),
                        sin(q.y * 1.15 - ph * 1.1),
                        sin((q.x + q.y) * 0.45 + ph * 2.2));
        }
        void displace(inout Vertex v) {
          float3 r = ripple(float2(v.position.x, v.position.z), t * 0.9);
          v.position.y += r.x * 0.075 + r.y * 0.055 + r.z * 0.04;
        }`,
      // The wave is a function of WORLD position, so neighbouring tiles agree
      // on their shared edge and the river is seamless across all 158 of them.
      // The normal is not recomputed after a vertex body, so build it here.
      fragment: `
        float3 shade(Surface s) {
          float3 r = ripple(s.position.xz, t * 0.9);
          float3 n = normalize(float3(r.x * 0.30 + r.z * 0.18, 1.0, r.y * 0.26 + r.z * 0.18));
          float crest = max(r.x * 0.4 + r.y * 0.35 + r.z * 0.25, 0.0);
          return deep * lambert(n) + float3(0.11, 0.15, 0.19) * pow(crest, 4.0);
        }`,
    });
    for (const w of river) w.material = waterMat;
    // three.clock.timeScale = 0 freezes this without unregistering it, which is
    // what two screenshots of the same frame need.
    three.setAnimationLoop(() => { waterMat.uniforms.t = three.clock.time; });

    this.tex = { stone, shingle };
    this.mat = { wall: wallMat, roof: roofMat, water: waterMat };
    return { walls, roofs, water: river.length };
  },
};

// Under --script the return value has nowhere to go, so say it out loud: this
// is the line that tells you the texture pass cost three draw calls and not
// three thousand.
const built = V.build();
console.log('lumbridge: ' + JSON.stringify(built.stats) + ' dressed=' + JSON.stringify(built.dressed));
built;
