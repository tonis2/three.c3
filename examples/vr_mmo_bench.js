// vr_mmo_bench.js — Quest 3 tabletop MMORPG crowd, LOD, cull-volume and shadow
// benchmark at 1:25 scale. Steps through its setups automatically using the
// `bench: begin` / `bench: end` / `bench: done` protocol so `quest.sh bench`
// pairs each setup with Meta's VrApi GPU timings out of the box.
//
//   packaging/android/build-apk.sh examples/vr_mmo_bench.js --install
//   packaging/android/quest.sh push examples/vr_mmo_bench.js
//   packaging/android/quest.sh bench
//   ./build/three --script examples/vr_mmo_bench.js
//
// Self-contained: generates a 7-joint animated humanoid .glb with three skinned
// LOD tiers in memory, caches it under `three.save` so single-file APK builds
// and `quest.sh push` need no external assets, and falls back gracefully if
// save storage is unavailable.
//
// Keep the headset still while it runs: each setup places the tabletop in front
// of the head and restarts if the head moves more than 3° or 3 cm. Pin the GPU
// level for comparable runs (`adb shell setprop debug.oculus.gpuLevel 4`) and
// disable charging boost (`setprop debug.crcs.disable_charging_boost 1`).

const SETTLE_MS = 2500;
const MEASURE_MS = 5000;
const MOVED_DEGREES = 3;
const MOVED_METRES = 0.03;
const MAX_RETRIES = 10;

// 1:25 miniature tabletop geometry: 15 world metres = 0.60 m tabletop disc.
const SCALE = 1 / 25;
const TABLE_RADIUS = 0.60;
const TABLE_WORLD_RADIUS = TABLE_RADIUS / SCALE;
const TABLE_Y = -0.20;
const TABLE_Z = -1.25;
const WORLD_EXTENT = 64;
const WORLD_PROP_COUNT = 2500;

const scene = new three.Scene();
scene.background = 0x101418;
three.light.set([-0.4, -1, -0.3], 1.0);
three.light.shadow = false;
if (three.xr.passthroughSupported) three.xr.passthrough = true;
three.alwaysRender = true;
three.sceneCache = false;
three.camera.lookAt(0, 1.6, 0);
three.camera.orbit(0, 0, 0.01);
// Match Quest's ~90° vertical FOV on desktop so LOD screen-size thresholds align.
if (!three.xr.presenting) three.camera.fov = 90;

const DEFAULT_PREPASS = three.depthPrepass;

// Stage anchored to the head pose at the start of each setup (local -Z ahead).
const turnGroup = new three.Group();
const stage = new three.Group();
turnGroup.add(stage);
scene.add(turnGroup);
let anchor = null;

function headPose() {
	const h = three.xr.head;
	const d = h.direction;
	const len = Math.hypot(d.x, d.y, d.z) || 1;
	const dir = [d.x / len, d.y / len, d.z / len];
	return {
		x: h.position.x, y: h.position.y, z: h.position.z, dir,
		yaw: Math.atan2(-dir[0], -dir[2]),
		pitch: Math.asin(Math.max(-1, Math.min(1, dir[1]))),
	};
}

function placeStage() {
	anchor = headPose();
	turnGroup.position.set(anchor.x, anchor.y, anchor.z);
	turnGroup.rotation.y = anchor.yaw;
	stage.rotation.x = anchor.pitch;
}

function headMoved() {
	const now = headPose();
	const dot = now.dir[0] * anchor.dir[0] + now.dir[1] * anchor.dir[1] + now.dir[2] * anchor.dir[2];
	const degrees = (Math.acos(Math.min(1, dot)) * 180) / Math.PI;
	const metres = Math.hypot(now.x - anchor.x, now.y - anchor.y, now.z - anchor.z);
	return degrees > MOVED_DEGREES || metres > MOVED_METRES;
}

// Deterministic PRNG so crowd layouts and world scatters match across runs.
function mulberry32(seed) {
	let a = seed >>> 0;
	return () => {
		a = (a + 0x6d2b79f5) >>> 0;
		let t = Math.imul(a ^ (a >>> 15), 1 | a);
		t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
		return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
	};
}

// ---------------------------------------------------------------------------
// Shared materials and procedural geometries (built once at startup)
// ---------------------------------------------------------------------------

const lit = new three.MeshLambertMaterial({});

function makeBlobShadowTexture(size) {
	const pixels = new Uint8Array(size * size * 4);
	for (let y = 0; y < size; y++) {
		const ny = ((y + 0.5) / size) * 2 - 1;
		for (let x = 0; x < size; x++) {
			const nx = ((x + 0.5) / size) * 2 - 1;
			const r = Math.hypot(nx, ny);
			const falloff = r >= 1 ? 0 : Math.pow(1 - r * r, 1.8);
			const idx = (y * size + x) * 4;
			pixels[idx] = 0;
			pixels[idx + 1] = 0;
			pixels[idx + 2] = 0;
			pixels[idx + 3] = Math.round(falloff * 165);
		}
	}
	return new three.DataTexture(pixels, size, size, { generateMipmaps: true });
}

const blobShadowTex = makeBlobShadowTexture(32);
const blobShadowMat = new three.MeshLambertMaterial({
	map: blobShadowTex,
	transparent: true,
	castShadow: false,
});

// Tabletop platform and tiled 64x64 ground (1:1 world metres under 1:25 root).
const tableDiscGeo = new three.CylinderGeometry(TABLE_WORLD_RADIUS, TABLE_WORLD_RADIUS * 1.02, 0.5, 48);
const groundTileGeo = new three.PlaneGeometry(8, 8);
const blobQuadGeo = new three.PlaneGeometry(0.95, 0.95);

function buildGrassTuftGeo() {
	const g = new three.Group();
	const blade = new three.ConeGeometry(0.14, 0.72, 4, 2);
	const offsets = [
		[-0.14, 0.34, -0.08, 0.16, 0.2, 0.12],
		[0.14, 0.36, -0.05, -0.14, 1.1, -0.15],
		[0.0, 0.38, 0.14, 0.18, 2.3, -0.08],
		[-0.08, 0.30, 0.11, -0.12, 3.6, 0.16],
		[0.10, 0.32, 0.08, 0.10, 4.9, -0.14],
	];
	for (const [x, y, z, rx, ry, rz] of offsets) {
		const m = new three.Mesh(blade, lit);
		m.position.set(x, y, z);
		m.rotation.set(rx, ry, rz);
		g.add(m);
	}
	return three.merge(g);
}

function buildTreePropGeo() {
	const g = new three.Group();
	const trunk = new three.Mesh(new three.CylinderGeometry(0.16, 0.28, 1.8, 8), lit);
	trunk.position.set(0, 0.9, 0);
	trunk.color = [0.36, 0.24, 0.15];
	g.add(trunk);

	const lower = new three.Mesh(new three.ConeGeometry(1.15, 1.9, 10, 2), lit);
	lower.position.set(0, 2.25, 0);
	lower.color = [0.18, 0.42, 0.20];
	g.add(lower);

	const upper = new three.Mesh(new three.ConeGeometry(0.82, 1.6, 10, 2), lit);
	upper.position.set(0, 3.3, 0);
	upper.color = [0.22, 0.50, 0.24];
	g.add(upper);

	return three.merge(g);
}

const grassGeo = buildGrassTuftGeo();
const rockGeo = new three.SphereGeometry(0.45, 10, 7);
const treeGeo = buildTreePropGeo();

// ---------------------------------------------------------------------------
// Procedural 7-joint animated humanoid .glb with 3 skinned LOD meshes
// ---------------------------------------------------------------------------

function quatAxisX(rad) { return [Math.sin(rad * 0.5), 0, 0, Math.cos(rad * 0.5)]; }
function quatAxisY(rad) { return [0, Math.sin(rad * 0.5), 0, Math.cos(rad * 0.5)]; }

function appendEllipsoid(out, cx, cy, cz, rx, ry, rz, joint, segU, segV) {
	const base = out.positions.length / 3;
	const stride = segU + 1;
	for (let iy = 0; iy <= segV; iy++) {
		const theta = (iy / segV) * Math.PI;
		const st = Math.sin(theta);
		const ct = Math.cos(theta);
		for (let ix = 0; ix <= segU; ix++) {
			const phi = (ix / segU) * Math.PI * 2;
			const ux = Math.cos(phi) * st;
			const uy = ct;
			const uz = Math.sin(phi) * st;

			const px = cx + rx * ux;
			const py = cy + ry * uy;
			const pz = cz + rz * uz;
			out.positions.push(px, py, pz);

			let nx = ux / rx;
			let ny = uy / ry;
			let nz = uz / rz;
			const nlen = Math.hypot(nx, ny, nz) || 1;
			out.normals.push(nx / nlen, ny / nlen, nz / nlen);

			out.joints.push(joint, 0, 0, 0);
			out.weights.push(1, 0, 0, 0);
		}
	}

	for (let iy = 0; iy < segV; iy++) {
		for (let ix = 0; ix < segU; ix++) {
			const a = base + iy * stride + ix;
			const b = a + 1;
			const c = a + stride;
			const d = c + 1;
			if (iy > 0) out.indices.push(a, b, c);
			if (iy < segV - 1) out.indices.push(b, d, c);
		}
	}
}

function buildSkinnedHumanoidMesh(tier) {
	const out = { positions: [], normals: [], joints: [], weights: [], indices: [] };
	// Joint indices: 0 hips, 1 torso, 2 head, 3 arm_L, 4 arm_R, 5 leg_L, 6 leg_R
	const fullParts = [
		[0, 0.90, 0, 0.19, 0.14, 0.14, 0],        // pelvis
		[0, 1.24, 0, 0.23, 0.28, 0.16, 1],        // torso
		[-0.27, 1.44, 0, 0.11, 0.09, 0.11, 1],    // left pauldron
		[0.27, 1.44, 0, 0.11, 0.09, 0.11, 1],     // right pauldron
		[0, 1.18, -0.18, 0.20, 0.30, 0.07, 1],    // cloak / pack
		[0, 1.66, 0, 0.13, 0.15, 0.14, 2],        // head
		[-0.30, 1.16, 0.03, 0.075, 0.28, 0.075, 3], // left arm
		[-0.39, 1.12, 0.10, 0.04, 0.20, 0.18, 3], // shield
		[0.30, 1.16, 0.03, 0.075, 0.28, 0.075, 4], // right arm
		[-0.12, 0.44, 0, 0.09, 0.44, 0.095, 5],   // left leg
		[0.12, 0.44, 0, 0.09, 0.44, 0.095, 6],    // right leg
	];
	const coreParts = [
		[0, 1.18, 0, 0.24, 0.36, 0.17, 1],        // combined torso
		[0, 1.66, 0, 0.13, 0.15, 0.14, 2],        // head
		[-0.31, 1.16, 0.04, 0.08, 0.28, 0.09, 3], // left arm
		[0.31, 1.16, 0.04, 0.08, 0.28, 0.09, 4],  // right arm
		[-0.12, 0.44, 0, 0.095, 0.44, 0.095, 5],  // left leg
		[0.12, 0.44, 0, 0.095, 0.44, 0.095, 6],   // right leg
	];

	// LOD 0: 2,156 tris | LOD 1: 528 tris | LOD 2: 120 tris
	const cfg = tier === 0
		? { parts: fullParts, segU: 14, segV: 8 }
		: tier === 1
			? { parts: fullParts, segU: 8, segV: 4 }
			: { parts: coreParts, segU: 5, segV: 3 };

	for (const [cx, cy, cz, rx, ry, rz, joint] of cfg.parts) {
		appendEllipsoid(out, cx, cy, cz, rx, ry, rz, joint, cfg.segU, cfg.segV);
	}
	return out;
}

function buildRiggedHeroGlb() {
	const chunks = [];
	const bufferViews = [];
	const accessors = [];
	let byteOffset = 0;

	function pushBuffer(typedArray, componentType, type, count, minMax = null) {
		const raw = new Uint8Array(typedArray.buffer, typedArray.byteOffset, typedArray.byteLength);
		const pad = (4 - (raw.byteLength % 4)) % 4;
		const viewIndex = bufferViews.length;
		bufferViews.push({ buffer: 0, byteOffset, byteLength: raw.byteLength });
		chunks.push(raw);
		if (pad > 0) chunks.push(new Uint8Array(pad));
		byteOffset += raw.byteLength + pad;

		const acc = { bufferView: viewIndex, componentType, count, type };
		if (minMax) {
			acc.min = minMax.min;
			acc.max = minMax.max;
		}
		const accIndex = accessors.length;
		accessors.push(acc);
		return accIndex;
	}

	function bounds3(arr) {
		const min = [Infinity, Infinity, Infinity];
		const max = [-Infinity, -Infinity, -Infinity];
		for (let i = 0; i < arr.length; i += 3) {
			for (let k = 0; k < 3; k++) {
				if (arr[i + k] < min[k]) min[k] = arr[i + k];
				if (arr[i + k] > max[k]) max[k] = arr[i + k];
			}
		}
		return { min, max };
	}

	const meshNames = ['hero_lod0', 'hero_lod1', 'hero_lod2'];
	const gltfMeshes = meshNames.map((name, tier) => {
		const m = buildSkinnedHumanoidMesh(tier);
		const vCount = m.positions.length / 3;
		const posAcc = pushBuffer(new Float32Array(m.positions), 5126, 'VEC3', vCount, bounds3(m.positions));
		const nrmAcc = pushBuffer(new Float32Array(m.normals), 5126, 'VEC3', vCount);
		const jntAcc = pushBuffer(new Uint8Array(m.joints), 5121, 'VEC4', vCount);
		const wgtAcc = pushBuffer(new Float32Array(m.weights), 5126, 'VEC4', vCount);
		const idxAcc = pushBuffer(new Uint16Array(m.indices), 5123, 'SCALAR', m.indices.length);
		return {
			name,
			primitives: [{
				attributes: { POSITION: posAcc, NORMAL: nrmAcc, JOINTS_0: jntAcc, WEIGHTS_0: wgtAcc },
				indices: idxAcc,
			}],
		};
	});

	// Inverse bind matrices in column-major order (translation = -worldPos).
	const jointWorld = [
		[0, 0.92, 0],       // 0 hips
		[0, 1.06, 0],       // 1 torso
		[0, 1.54, 0],       // 2 head
		[-0.28, 1.42, 0],   // 3 arm_L
		[0.28, 1.42, 0],    // 4 arm_R
		[-0.12, 0.88, 0],   // 5 leg_L
		[0.12, 0.88, 0],    // 6 leg_R
	];
	const ibms = new Float32Array(jointWorld.length * 16);
	for (let j = 0; j < jointWorld.length; j++) {
		const o = j * 16;
		ibms[o] = 1; ibms[o + 5] = 1; ibms[o + 10] = 1; ibms[o + 15] = 1;
		ibms[o + 12] = -jointWorld[j][0];
		ibms[o + 13] = -jointWorld[j][1];
		ibms[o + 14] = -jointWorld[j][2];
	}
	const ibmAcc = pushBuffer(ibms, 5126, 'MAT4', jointWorld.length);

	// Seamless 1.0 s walk cycle across all 7 joints (9 keyframes).
	const KEYS = 9;
	const times = new Float32Array(KEYS);
	const hipsT = new Float32Array(KEYS * 3);
	const torsoR = new Float32Array(KEYS * 4);
	const headR = new Float32Array(KEYS * 4);
	const armLR = new Float32Array(KEYS * 4);
	const armRR = new Float32Array(KEYS * 4);
	const legLR = new Float32Array(KEYS * 4);
	const legRR = new Float32Array(KEYS * 4);
	for (let k = 0; k < KEYS; k++) {
		const u = k / (KEYS - 1);
		const a = u * Math.PI * 2;
		times[k] = u;
		hipsT.set([0, 0.92 + 0.045 * Math.abs(Math.sin(a)), 0], k * 3);
		torsoR.set(quatAxisY(0.14 * Math.sin(a)), k * 4);
		headR.set(quatAxisY(-0.08 * Math.sin(a)), k * 4);
		armLR.set(quatAxisX(-0.48 * Math.sin(a)), k * 4);
		armRR.set(quatAxisX(0.48 * Math.sin(a)), k * 4);
		legLR.set(quatAxisX(0.55 * Math.sin(a)), k * 4);
		legRR.set(quatAxisX(-0.55 * Math.sin(a)), k * 4);
	}
	const timeAcc = pushBuffer(times, 5126, 'SCALAR', KEYS, { min: [0], max: [1] });
	const tracks = [
		{ node: 1, path: 'translation', acc: pushBuffer(hipsT, 5126, 'VEC3', KEYS) },
		{ node: 2, path: 'rotation', acc: pushBuffer(torsoR, 5126, 'VEC4', KEYS) },
		{ node: 3, path: 'rotation', acc: pushBuffer(headR, 5126, 'VEC4', KEYS) },
		{ node: 4, path: 'rotation', acc: pushBuffer(armLR, 5126, 'VEC4', KEYS) },
		{ node: 5, path: 'rotation', acc: pushBuffer(armRR, 5126, 'VEC4', KEYS) },
		{ node: 6, path: 'rotation', acc: pushBuffer(legLR, 5126, 'VEC4', KEYS) },
		{ node: 7, path: 'rotation', acc: pushBuffer(legRR, 5126, 'VEC4', KEYS) },
	];

	const doc = {
		asset: { version: '2.0', generator: 'vr_mmo_bench.js' },
		scene: 0,
		scenes: [{ nodes: [0] }],
		nodes: [
			{ name: 'hero_root', children: [1, 8] },
			{ name: 'hips', translation: [0, 0.92, 0], children: [2, 6, 7] },
			{ name: 'torso', translation: [0, 0.14, 0], children: [3, 4, 5] },
			{ name: 'head', translation: [0, 0.48, 0] },
			{ name: 'arm_L', translation: [-0.28, 0.36, 0] },
			{ name: 'arm_R', translation: [0.28, 0.36, 0] },
			{ name: 'leg_L', translation: [-0.12, -0.04, 0] },
			{ name: 'leg_R', translation: [0.12, -0.04, 0] },
			{ name: 'hero_body', mesh: 0, skin: 0 },
		],
		meshes: gltfMeshes,
		skins: [{ name: 'hero_rig', joints: [1, 2, 3, 4, 5, 6, 7], inverseBindMatrices: ibmAcc, skeleton: 1 }],
		animations: [{
			name: 'walk',
			samplers: tracks.map((tr) => ({ input: timeAcc, output: tr.acc, interpolation: 'LINEAR' })),
			channels: tracks.map((tr, idx) => ({ sampler: idx, target: { node: tr.node, path: tr.path } })),
		}],
		accessors,
		bufferViews,
		buffers: [{ byteLength: byteOffset }],
	};

	let jsonStr = JSON.stringify(doc);
	const jsonPad = (4 - (jsonStr.length % 4)) % 4;
	if (jsonPad > 0) jsonStr += ' '.repeat(jsonPad);
	const jsonBytes = new Uint8Array(jsonStr.length);
	for (let i = 0; i < jsonStr.length; i++) jsonBytes[i] = jsonStr.charCodeAt(i);

	const totalLength = 12 + 8 + jsonBytes.byteLength + 8 + byteOffset;
	const glb = new Uint8Array(totalLength);
	const view = new DataView(glb.buffer);
	view.setUint32(0, 0x46546c67, true); // 'glTF'
	view.setUint32(4, 2, true);
	view.setUint32(8, totalLength, true);
	view.setUint32(12, jsonBytes.byteLength, true);
	view.setUint32(16, 0x4e4f534a, true); // 'JSON'
	glb.set(jsonBytes, 20);

	const binHeader = 20 + jsonBytes.byteLength;
	view.setUint32(binHeader, byteOffset, true);
	view.setUint32(binHeader + 4, 0x004e4942, true); // 'BIN\0'
	let cursor = binHeader + 8;
	for (const chunk of chunks) {
		glb.set(chunk, cursor);
		cursor += chunk.byteLength;
	}
	return glb;
}

// Fallback unskinned procedural character LODs (only used if .glb loading fails).
function buildProceduralHeroFallback(tier) {
	const seg = tier === 0 ? [16, 12] : tier === 1 ? [8, 6] : [5, 4];
	const g = new three.Group();
	const parts = [
		[0, 1.18, 0, new three.SphereGeometry(0.26, seg[0], seg[1]), [1, 1.35, 0.72]],
		[0, 1.66, 0, new three.SphereGeometry(0.14, seg[0], seg[1]), [1, 1.05, 1]],
		[-0.30, 1.16, 0, new three.CylinderGeometry(0.07, 0.06, 0.56, seg[0]), [1, 1, 1]],
		[0.30, 1.16, 0, new three.CylinderGeometry(0.07, 0.06, 0.56, seg[0]), [1, 1, 1]],
		[-0.12, 0.44, 0, new three.CylinderGeometry(0.09, 0.07, 0.88, seg[0]), [1, 1, 1]],
		[0.12, 0.44, 0, new three.CylinderGeometry(0.09, 0.07, 0.88, seg[0]), [1, 1, 1]],
	];
	for (const [x, y, z, geo, [sx, sy, sz]] of parts) {
		const m = new three.Mesh(geo, lit);
		m.position.set(x, y, z);
		m.scale.set(sx, sy, sz);
		g.add(m);
	}
	return three.merge(g);
}

function initHeroAssets() {
	let rig = null;
	try {
		three.configure({ saveDir: 'vr-mmo-bench' });
		const bytes = buildRiggedHeroGlb();
		three.save.writeBytes('mmo_crowd_hero.glb', bytes);
		const dir = three.save.path;
		if (dir) rig = three.load(`${dir}/mmo_crowd_hero.glb`);
	} catch (err) {
		console.warn(`bench: could not write/load procedural rigged .glb (${err.message})`);
	}

	if (rig && rig.meshes.includes('hero_lod0') && rig.meshes.includes('hero_lod1') && rig.meshes.includes('hero_lod2')) {
		return {
			rig,
			clip: rig.animations[0] ?? null,
			lod0: rig.mesh('hero_lod0'),
			lod1: rig.mesh('hero_lod1'),
			lod2: rig.mesh('hero_lod2'),
		};
	}

	// Secondary fallback: repo fixture on desktop + procedural LOD fallbacks.
	if (!rig) {
		try { rig = three.load('../test/fixtures/legs.glb'); } catch (_) { rig = null; }
	}
	const fallbackLod0 = buildProceduralHeroFallback(0);
	const fallbackLod1 = buildProceduralHeroFallback(1);
	const fallbackLod2 = buildProceduralHeroFallback(2);
	return {
		rig,
		clip: rig?.animations?.[0] ?? null,
		lod0: rig ? rig.meshAt(0) : fallbackLod0,
		lod1: fallbackLod1,
		lod2: fallbackLod2,
	};
}

const heroAssets = initHeroAssets();

// Screen-height thresholds tuned for a 1.8 m hero at 1:25 tabletop scale (~7.2 cm
// tall) spread across depth 0.70..1.80 m: ~20% LOD 0, ~40% LOD 1, ~40% LOD 2.
const HERO_LOD_LEVELS = [
	{ mesh: heroAssets.lod1, minSize: 0.046 },
	{ mesh: heroAssets.lod2, minSize: 0.031 },
];

const FACTION_COLORS = [
	[0.82, 0.24, 0.22],
	[0.24, 0.50, 0.84],
	[0.26, 0.68, 0.34],
	[0.84, 0.66, 0.22],
	[0.64, 0.32, 0.78],
	[0.24, 0.70, 0.72],
	[0.84, 0.44, 0.20],
	[0.74, 0.74, 0.78],
];

// ---------------------------------------------------------------------------
// Scene builders
// ---------------------------------------------------------------------------

const activeLodBases = [];
const activeCullRoots = [];

function makeTableRoot() {
	const root = new three.Group();
	root.position.set(0, TABLE_Y, TABLE_Z);
	root.scale.set(SCALE, SCALE, SCALE);
	stage.add(root);
	return root;
}

function addTableDisc(root) {
	const disc = new three.Mesh(tableDiscGeo, lit);
	disc.position.set(0, -0.25, 0);
	disc.color = [0.22, 0.28, 0.20];
	disc.collides = false;
	disc.static = true;
	root.add(disc);
	return disc;
}

function spawnCrowd(root, count, { useLods = false, blobShadows = false } = {}) {
	const GOLDEN_ANGLE = 2.399963229728653;
	const maxR = TABLE_WORLD_RADIUS * 0.92;
	let firstHeroMesh = null;

	for (let i = 0; i < count; i++) {
		const r = maxR * Math.sqrt((i + 0.5) / count);
		const theta = i * GOLDEN_ANGLE;
		const wx = Math.cos(theta) * r;
		const wz = Math.sin(theta) * r;
		const tint = FACTION_COLORS[i % FACTION_COLORS.length];

		if (heroAssets.rig) {
			const actor = heroAssets.rig.instantiate();
			actor.position.set(wx, 0, wz);
			actor.rotation.y = theta + Math.PI * 0.5;
			actor.traverse((node) => {
				if (node instanceof three.Mesh) {
					node.color = tint;
					node.collides = false;
					if (!firstHeroMesh) firstHeroMesh = node;
				}
			});
			root.add(actor);
			if (heroAssets.clip) {
				actor.play(heroAssets.clip, {
					loop: true,
					time: (i * 0.137) % 1.0,
					speed: 0.85 + (i % 5) * 0.08,
				});
			}
		} else {
			const mesh = new three.Mesh(heroAssets.lod0, lit);
			mesh.position.set(wx, 0, wz);
			mesh.rotation.y = theta + Math.PI * 0.5;
			mesh.color = tint;
			mesh.collides = false;
			if (!firstHeroMesh) firstHeroMesh = mesh;
			root.add(mesh);
		}

		if (blobShadows) {
			const blob = new three.Mesh(blobQuadGeo, blobShadowMat);
			blob.position.set(wx, 0.025, wz);
			blob.rotation.x = -Math.PI * 0.5;
			blob.color = [0, 0, 0, 1];
			blob.collides = false;
			root.add(blob);
		}
	}

	if (useLods && firstHeroMesh) {
		firstHeroMesh.setLods(HERO_LOD_LEVELS);
		activeLodBases.push(firstHeroMesh.geometry);
	}
}

function buildWorldScatter(root, { cullVolume = false } = {}) {
	// 8x8 tiled ground spanning 64x64 world metres so tiles outside the disc also cull.
	const tilesPerSide = WORLD_EXTENT / 8;
	const half = WORLD_EXTENT * 0.5;
	for (let gz = 0; gz < tilesPerSide; gz++) {
		for (let gx = 0; gx < tilesPerSide; gx++) {
			const tile = new three.Mesh(groundTileGeo, lit);
			tile.position.set(-half + (gx + 0.5) * 8, 0, -half + (gz + 0.5) * 8);
			tile.rotation.x = -Math.PI * 0.5;
			const checker = (gx + gz) & 1 ? 0.24 : 0.21;
			tile.color = [checker * 0.9, checker * 1.15, checker * 0.8];
			tile.collides = false;
			tile.static = true;
			root.add(tile);
		}
	}

	// 2,500 scattered foliage, rocks and trees across the 64x64 map (3 instanced draws).
	const rand = mulberry32(0x4d4d4f33);
	for (let i = 0; i < WORLD_PROP_COUNT; i++) {
		const wx = (rand() - 0.5) * WORLD_EXTENT;
		const wz = (rand() - 0.5) * WORLD_EXTENT;
		const roll = rand();
		let mesh;
		if (roll < 0.72) {
			mesh = new three.Mesh(grassGeo, lit);
			const s = 0.75 + rand() * 0.7;
			mesh.scale.set(s, s, s);
			mesh.color = [0.24 + rand() * 0.10, 0.48 + rand() * 0.16, 0.18 + rand() * 0.08];
		} else if (roll < 0.92) {
			mesh = new three.Mesh(rockGeo, lit);
			const sx = 0.7 + rand() * 0.9;
			const sy = 0.45 + rand() * 0.55;
			const sz = 0.7 + rand() * 0.9;
			mesh.scale.set(sx, sy, sz);
			mesh.position.y = sy * 0.25;
			const g = 0.38 + rand() * 0.18;
			mesh.color = [g, g * 0.97, g * 0.92];
		} else {
			mesh = new three.Mesh(treeGeo, lit);
			const s = 0.75 + rand() * 0.55;
			mesh.scale.set(s, s, s);
			mesh.color = [0.85 + rand() * 0.2, 0.9 + rand() * 0.15, 0.85 + rand() * 0.15];
		}
		mesh.position.x = wx;
		mesh.position.z = wz;
		mesh.rotation.y = rand() * Math.PI * 2;
		mesh.collides = false;
		mesh.static = true;
		root.add(mesh);
	}

	if (cullVolume) {
		root.setCullVolume({
			shape: 'cylinder',
			center: [0, 0, 0],
			radius: TABLE_WORLD_RADIUS,
			space: 'local',
			shadows: true,
		});
		activeCullRoots.push(root);
	}
}

// ---------------------------------------------------------------------------
// Benchmark setups (names <= 34 chars to fit `quest.sh bench` table columns)
// ---------------------------------------------------------------------------

const SETUPS = [
	{ name: 'mmo empty', build() {} },

	{
		name: 'mmo crowd 25 skinned',
		build() {
			const root = makeTableRoot();
			addTableDisc(root);
			spawnCrowd(root, 25, { useLods: false });
		},
	},

	{
		name: 'mmo 50 chars high-poly (no LOD)',
		build() {
			const root = makeTableRoot();
			addTableDisc(root);
			spawnCrowd(root, 50, { useLods: false });
		},
	},
	{
		name: 'mmo 50 chars with LOD',
		build() {
			const root = makeTableRoot();
			addTableDisc(root);
			spawnCrowd(root, 50, { useLods: true });
		},
	},

	{
		name: 'mmo 100 chars high-poly (no LOD)',
		build() {
			const root = makeTableRoot();
			addTableDisc(root);
			spawnCrowd(root, 100, { useLods: false });
		},
	},
	{
		name: 'mmo 100 chars with LOD',
		build() {
			const root = makeTableRoot();
			addTableDisc(root);
			spawnCrowd(root, 100, { useLods: true });
		},
	},

	{
		name: 'mmo world no cullVolume',
		build() {
			const root = makeTableRoot();
			buildWorldScatter(root, { cullVolume: false });
		},
	},
	{
		name: 'mmo world with cullVolume',
		build() {
			const root = makeTableRoot();
			buildWorldScatter(root, { cullVolume: true });
		},
	},

	{
		name: 'mmo 50 chars + sun shadow',
		shadow: true,
		build() {
			const root = makeTableRoot();
			addTableDisc(root);
			spawnCrowd(root, 50, { useLods: true, blobShadows: false });
		},
	},
	{
		name: 'mmo 50 chars + blob shadows',
		shadow: false,
		build() {
			const root = makeTableRoot();
			addTableDisc(root);
			spawnCrowd(root, 50, { useLods: true, blobShadows: true });
		},
	},

	{
		name: 'mmo full tabletop (LOD+cull+blob)',
		shadow: false,
		build() {
			const root = makeTableRoot();
			buildWorldScatter(root, { cullVolume: true });
			spawnCrowd(root, 50, { useLods: true, blobShadows: true });
		},
	},
];

// ---------------------------------------------------------------------------
// Benchmark runner (exact `vr_bench.js` state machine and log format)
// ---------------------------------------------------------------------------

let index = -1;
let phase = 'wait'; // wait -> next -> settle -> measure -> done
let since = 0;
let tick = null;
let frames = 0;
let jsMs = 0;
let hostMs = 0;
let trackedFrames = 0;
let retries = 0;

function clear() {
	for (const root of activeCullRoots) root.clearCullVolume();
	activeCullRoots.length = 0;
	for (const base of activeLodBases) scene.clearLods(base);
	activeLodBases.length = 0;
	for (const child of [...stage.children]) stage.remove(child);
	tick = null;
}

function apply(setup) {
	clear();
	placeStage();
	three.depthPrepass = setup.prepass ?? DEFAULT_PREPASS;
	three.light.shadow = setup.shadow ? { enabled: true, distance: 3 } : false;
	if (three.xr.presenting) three.xr.foveation = setup.foveation ?? 'medium';
	tick = setup.build() ?? null;
	if (typeof tick !== 'function') tick = null;
}

function report(setup) {
	const stats = three.stats();
	const n = Math.max(frames, 1);
	const seconds = MEASURE_MS / 1000;
	const draws = stats.drawnCalls ?? stats.drawCalls;
	const instances = stats.drawnInstances ?? stats.instances;
	const triangles = stats.drawnTriangles ?? stats.triangles;
	const trisK = triangles > 0 && triangles < 10000
		? (triangles / 1000).toFixed(1)
		: (triangles / 1000).toFixed(0);
	const extras = [];
	if (stats.skinnedInstances) extras.push(`${stats.skinnedDraws}/${stats.skinnedInstances} skinned`);
	if (stats.volumeCulled) extras.push(`${stats.volumeCulled} vol-culled`);
	const detail = extras.length ? `, ${extras.join(', ')}` : '';
	const moved = retries >= MAX_RETRIES ? ' (the head kept moving)' : '';
	console.log(
		`bench: end ${setup.name} | frames ${frames}, fps ${(frames / seconds).toFixed(1)}, `
		+ `js ${(jsMs / n).toFixed(2)} ms, engine ${(hostMs / n).toFixed(2)} ms | `
		+ `${draws} draws, ${instances} copies, ${trisK}k triangles${detail}${moved}`
	);
}

three.setAnimationLoop((ms) => {
	if (tick) tick(ms / 1000);

	if (phase === 'wait') {
		const ready = three.xr.presenting ? three.xr.head.tracked : true;
		trackedFrames = ready ? trackedFrames + 1 : 0;
		if (trackedFrames < 30) return;
		console.log(`bench: ${SETUPS.length} setups, ${SETTLE_MS} ms to settle and ${MEASURE_MS} ms measured each`);
		phase = 'next';
	}

	if (phase === 'next') {
		index++;
		if (index >= SETUPS.length) {
			clear();
			console.log('bench: done');
			phase = 'done';
			return;
		}
		retries = 0;
		apply(SETUPS[index]);
		phase = 'settle';
		since = ms;
		return;
	}

	if ((phase === 'settle' || phase === 'measure') && retries < MAX_RETRIES && headMoved()) {
		retries++;
		console.log(`bench: the head moved, starting ${SETUPS[index].name} again`);
		apply(SETUPS[index]);
		phase = 'settle';
		since = ms;
		return;
	}

	if (phase === 'settle' && ms - since >= SETTLE_MS) {
		console.log(`bench: begin ${SETUPS[index].name}`);
		phase = 'measure';
		since = ms;
		frames = 0;
		jsMs = 0;
		hostMs = 0;
		return;
	}

	if (phase === 'measure') {
		const spent = three.frame.ms;
		jsMs += spent.total;
		hostMs += spent.host;
		frames++;
		if (ms - since >= MEASURE_MS) {
			report(SETUPS[index]);
			phase = 'next';
		}
	}
});
