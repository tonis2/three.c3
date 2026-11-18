// three.c3 — three.cutscene: plays a timeline of actor strips, camera keys and
// named events, loaded from a `.cutscene.glb` or built in code. See
// `## Cutscene` in docs/classes.md.
//
// One pure pose-at-time (`_evaluate`) serves both playback and seeking, so a
// scrubbed frame and a played frame are the same frame. The frame system is
// installed only while something plays, as cooldown.js does.
import { systems } from './systems.js';
import { CatmullRomCurve3, clamp01, eulerXYZFromQuat, lerp, multiplyQuat, quatFromEulerXYZ } from './math.js';

const H = globalThis.__three;

const WHERE = 'three.cutscene.create(spec, options)';
const OPTION_KEYS = ['level', 'actors', 'scene', 'camera', 'restoreCamera'];
const STRIP_TYPES = ['move', 'play', 'turn'];
const EASES = ['linear', 'in', 'out', 'inout'];
const SYSTEM = 'cutscene';
// The root extension a `.cutscene.glb` carries, and the versions of it read here.
// Version 2 adds an actor's `place` and the `turn` strip.
const EXTENSION = 'CUSTOM_cutscene';
const EXTENSION_VERSIONS = [1, 2];
const GLTF_FILE = /\.(glb|gltf)$/i;
// Seconds before its end a held loop is posed at. Wider than the exporter's
// 0.1 ms rounding of `start` and `end`, and a fortieth of a frame at 24 fps.
const HOLD_BEFORE = 1e-3;

// Every playing cutscene, stepped by one lazily installed system.
const _playing = [];

function _tick(dt) {
	// A copy: finishing removes a cutscene from the list mid-walk.
	for (const cs of _playing.slice()) cs._advance(dt);
}

function _start(cs) {
	if (_playing.includes(cs)) return;
	_playing.push(cs);
	if (_playing.length === 1) systems.add(SYSTEM, _tick, { phase: 'frame', first: true });
}

function _stop(cs) {
	const at = _playing.indexOf(cs);
	if (at < 0) return;
	_playing.splice(at, 1);
	if (_playing.length === 0) systems.remove(SYSTEM);
}

function _ease(kind, u) {
	switch (kind) {
		case 'in': return u * u;
		case 'out': return 1 - (1 - u) * (1 - u);
		case 'inout': return u * u * (3 - 2 * u);
		default: return u;
	}
}

function _num(value, fallback, where) {
	if (value === undefined || value === null) return fallback;
	const n = +value;
	if (!Number.isFinite(n)) throw new TypeError(`${where} is not a number: ${JSON.stringify(value)}`);
	return n;
}

function _triple(value, where) {
	if (!Array.isArray(value) || value.length !== 3 || !value.every(Number.isFinite)) {
		throw new TypeError(`${where} wants [x, y, z], not ${JSON.stringify(value)}`);
	}
	return value.slice();
}

function _readEase(raw, where) {
	const ease = raw.ease ?? 'inout';
	if (!EASES.includes(ease)) throw new RangeError(`${where}.ease is one of ${EASES.join(', ')}`);
	return ease;
}

// A turn faces a point, or another actor where it stands when the turn begins.
function _readTurn(raw, where) {
	if (raw.clip != null || raw.animation != null) throw new TypeError(`${where}: a turn plays no clip`);
	const start = _num(raw.start, 0, `${where}.start`);
	const end = raw.end === undefined ? null : _num(raw.end, 0, `${where}.end`);
	if (end === null || !(end > start)) throw new RangeError(`${where}: a turn needs an end after its start`);
	const point = raw.point ?? null, actor = raw.actor ?? null;
	if ((point === null) === (actor === null)) {
		const which = point === null ? 'names neither' : 'not both';
		throw new TypeError(`${where}: a turn faces a point: [x, y, z] or an actor: '<row>', ${which}`);
	}
	if (actor !== null && (typeof actor !== 'string' || actor === '')) {
		throw new TypeError(`${where}.actor is the row of the actor to face, not ${JSON.stringify(actor)}`);
	}
	return {
		type: 'turn', start, end, ease: _readEase(raw, where), clip: null,
		point: point === null ? null : _triple(point, `${where}.point`), actor, target: null,
	};
}

// Where an actor stands as the cutscene starts, in place of its object's own transform.
function _readPlace(raw, where) {
	if (raw === null || typeof raw !== 'object') {
		throw new TypeError(`${where} wants { position: [x, y, z], rotation: [x, y, z, w] }`);
	}
	const position = _triple(raw.position, `${where}.position`);
	const q = raw.rotation;
	if (!Array.isArray(q) || q.length !== 4 || !q.every(Number.isFinite)) {
		throw new TypeError(`${where}.rotation wants a quaternion [x, y, z, w], not ${JSON.stringify(q)}`);
	}
	const length = Math.hypot(...q);
	if (length < 1e-6) throw new RangeError(`${where}.rotation is all zeros, which is not a rotation; no turn at all is [0, 0, 0, 1]`);
	return { position, rotation: q.map(v => v / length) };
}

function _readStrip(raw, where) {
	if (raw === null || typeof raw !== 'object') throw new TypeError(`${where} is not an object`);
	if (!STRIP_TYPES.includes(raw.type)) {
		const kinds = STRIP_TYPES.map(t => `'${t}'`);
		throw new RangeError(`${where}: type is ${kinds.slice(0, -1).join(', ')} or ${kinds.at(-1)}, not ${JSON.stringify(raw.type)}`);
	}
	if (raw.type === 'turn') return _readTurn(raw, where);
	const strip = {
		type: raw.type,
		start: _num(raw.start, 0, `${where}.start`),
		end: raw.end === undefined ? null : _num(raw.end, 0, `${where}.end`),
		clip: raw.clip ?? null,
		loop: raw.loop ?? raw.type === 'move',
		speed: _num(raw.speed, 1, `${where}.speed`),
		fade: _num(raw.fade, 0.2, `${where}.fade`),
		offset: _num(raw.offset, 0, `${where}.offset`),
		hold: false,
	};
	if (strip.clip !== null && typeof strip.clip !== 'string') throw new TypeError(`${where}.clip is a clip name`);
	// A play strip with an end stops there and holds; one without runs on to the next strip.
	if (raw.type === 'play' && strip.end !== null) {
		if (strip.end < strip.start) throw new RangeError(`${where}: end is before start`);
		strip.hold = true;
	}
	if (raw.animation !== undefined) {
		if (!Number.isInteger(raw.animation) || raw.animation < 0) {
			throw new TypeError(`${where}.animation is the index of an animation in the cutscene file, not ${JSON.stringify(raw.animation)}`);
		}
		if (strip.clip === null) throw new TypeError(`${where}: a one-off animation needs the clip name it plays as`);
		strip.animation = raw.animation;
	}
	if (raw.type === 'move') {
		if (strip.end === null || !(strip.end > strip.start)) {
			throw new RangeError(`${where}: a move needs an end after its start`);
		}
		if (!Array.isArray(raw.path) || raw.path.length < 2) {
			throw new RangeError(`${where}: a move needs a path of at least 2 points`);
		}
		strip.path = raw.path.map((p, i) => _triple(p, `${where}.path[${i}]`));
		strip.ease = _readEase(raw, where);
		strip.turn = raw.turn !== false;
		strip._curve = new CatmullRomCurve3(strip.path);
	}
	return strip;
}

// Turn the spec into checked, sorted tracks. Throws a sentence naming the bad field.
function _readSpec(spec) {
	if (spec === null || typeof spec !== 'object') throw new TypeError(`${WHERE} wants a cutscene object`);
	const file = spec.file ?? null;
	if (file !== null && (typeof file !== 'string' || file === '')) {
		throw new TypeError(`${WHERE}: file is the path of the cutscene file its one-off clips are in`);
	}
	const rows = (spec.actors ?? []).map(a => a?.row);
	const actors = (spec.actors ?? []).map((a, i) => {
		const where = `actors[${i}]`;
		if (typeof a?.row !== 'string' || a.row === '') throw new TypeError(`${where}.row names the object to drive`);
		const strips = (a.strips ?? []).map((s, k) => {
			const strip = _readStrip(s, `${where}.strips[${k}]`);
			if (strip.actor) {
				strip.target = rows.indexOf(strip.actor);
				if (strip.target < 0) {
					throw new RangeError(`${where}.strips[${k}].actor is '${strip.actor}', and this cutscene has no actor of that row`);
				}
			}
			return strip;
		});
		// Stable, so strips that start together keep their order.
		strips.sort((x, y) => x.start - y.start);
		const oneOff = strips.find(s => s.animation !== undefined);
		if (oneOff && file === null) {
			throw new TypeError(`${where} plays the one-off clip '${oneOff.clip}', which lives in a cutscene file, and this spec names no file — load the file with three.cutscene.load(path)`);
		}
		if (oneOff && !(Number.isInteger(a.node) && a.node >= 0)) {
			throw new TypeError(`${where}.node is the actor's stub node in ${file}, which its one-off clips are bound through`);
		}
		const place = a.place == null ? null : _readPlace(a.place, `${where}.place`);
		return { row: a.row, node: a.node ?? null, place, strips };
	});
	const camera = (spec.camera ?? []).map((k, i) => {
		const ease = k.ease ?? 'inout';
		if (!EASES.includes(ease)) throw new RangeError(`camera[${i}].ease is one of ${EASES.join(', ')}`);
		return {
			at: _num(k.at, 0, `camera[${i}].at`),
			eye: _triple(k.eye, `camera[${i}].eye`),
			target: _triple(k.target, `camera[${i}].target`),
			fov: k.fov === undefined ? null : _num(k.fov, 0, `camera[${i}].fov`),
			cut: !!k.cut,
			ease,
		};
	}).sort((a, b) => a.at - b.at);
	const events = (spec.events ?? []).map((e, i) => {
		if (typeof e?.name !== 'string' || e.name === '') throw new TypeError(`events[${i}].name is missing`);
		return { at: _num(e.at, 0, `events[${i}].at`), name: e.name, data: e.data ?? {}, always: !!e.always };
	}).sort((a, b) => a.at - b.at);

	let duration = spec.duration === undefined ? null : _num(spec.duration, 0, 'duration');
	const end = events.find(e => e.name === 'end');
	if (end) duration = end.at;
	if (duration === null) {
		duration = 0;
		for (const a of actors) for (const s of a.strips) duration = Math.max(duration, s.end ?? s.start);
		for (const k of camera) duration = Math.max(duration, k.at);
		for (const e of events) duration = Math.max(duration, e.at);
	}
	return { actors, camera, events: events.filter(e => e.name !== 'end'), duration, file };
}

// A `CUSTOM_cutscene` glTF document as the spec `create` plays. The payload
// already uses the spec's names; what differs is that a move's `path` is an
// index into `paths`, and that `file` names the glTF its one-off clips are in.
function _fromGltf(doc, path) {
	const where = `three.cutscene.load('${path}')`;
	const ext = doc?.extensions?.[EXTENSION];
	if (ext === null || typeof ext !== 'object') {
		throw new TypeError(`${where}: this glTF has no ${EXTENSION} extension, so it is not a cutscene — write one with the Blender exporter's Export Cutscene`);
	}
	if (!EXTENSION_VERSIONS.includes(ext.version)) {
		throw new RangeError(`${where}: ${EXTENSION} is version ${JSON.stringify(ext.version)}, and this engine reads versions ${EXTENSION_VERSIONS.join(' and ')}`);
	}
	// Neither existed in version 1, so a file saying 1 that has one is mislabelled.
	const newer = (field) => new RangeError(`${where}: ${field} needs ${EXTENSION} version 2, and the file says version 1`);
	const paths = Array.isArray(ext.paths) ? ext.paths : [];
	const animations = Array.isArray(doc.animations) ? doc.animations : [];
	const actors = (Array.isArray(ext.actors) ? ext.actors : []).map((a, i) => ({
		...a,
		strips: (Array.isArray(a?.strips) ? a.strips : []).map((s, k) => {
			const at = `actors[${i}].strips[${k}]`;
			if (ext.version === 1 && s?.type === 'turn') throw newer(`${at}.type 'turn'`);
			const strip = { ...s };
			if (s?.type === 'move') {
				const p = Number.isInteger(s.path) ? paths[s.path] : undefined;
				if (!p) {
					const count = `${paths.length} path${paths.length === 1 ? '' : 's'}`;
					throw new RangeError(`${where}: ${at}.path is ${JSON.stringify(s.path)}, and the file has ${count}`);
				}
				strip.path = p.points;
			}
			if (s?.animation !== undefined && !(Number.isInteger(s.animation) && animations[s.animation])) {
				throw new RangeError(`${where}: ${at}.animation is ${JSON.stringify(s.animation)}, and the file has ${animations.length} animations`);
			}
			return strip;
		}),
	}));
	if (ext.version === 1) {
		const placed = actors.findIndex(a => a?.place != null);
		if (placed >= 0) throw newer(`actors[${placed}].place`);
	}
	const spec = { file: path };
	for (const key of ['name', 'duration', 'fps']) if (ext[key] !== undefined) spec[key] = ext[key];
	spec.actors = actors;
	spec.camera = Array.isArray(ext.camera) ? ext.camera : [];
	spec.events = Array.isArray(ext.events) ? ext.events : [];
	return spec;
}

// The spec in a cutscene file. Only the exporter's glTF is one.
function _readFile(path) {
	if (typeof path !== 'string' || path === '') {
		throw new TypeError('three.cutscene.load(path, options) wants a path in the assets directory');
	}
	if (!GLTF_FILE.test(path)) {
		throw new TypeError(`three.cutscene.load('${path}'): a cutscene is a .cutscene.glb (or .gltf) written by the Blender exporter`);
	}
	const text = H.gltfJson(path);
	if (text === null) throw new Error(`three.cutscene.load: '${path}' is not there`);
	let doc;
	try { doc = JSON.parse(text); } catch (e) {
		throw new SyntaxError(`three.cutscene.load('${path}'): not a glTF file — its JSON does not parse (${e.message})`);
	}
	return _fromGltf(doc, path);
}

// eye/target → the host's orbit numbers, inverting `three.camera.position()`.
function _orbit(eye, target) {
	const dx = eye[0] - target[0], dy = eye[1] - target[1], dz = eye[2] - target[2];
	const d = Math.max(1e-4, Math.hypot(dx, dy, dz));
	return {
		yaw: Math.atan2(dx, dz) * 180 / Math.PI,
		pitch: Math.asin(Math.max(-1, Math.min(1, dy / d))) * 180 / Math.PI,
		distance: d,
	};
}

// A turn of `yaw` radians about +Y.
function _yawQuat(yaw) {
	return [0, Math.sin(yaw / 2), 0, Math.cos(yaw / 2)];
}

// The heading about +Y of an orientation: the Y of a YZX decomposition, which is
// Blender's Euler Z once its Z-up is glTF's Y-up.
function _headingOf([x, y, z, w]) {
	return Math.atan2(2 * (w * y - x * z), 1 - 2 * (y * y + z * z));
}

// An orientation less its heading: the lean a character stands with, such as a
// tilted armature, which strips keep while they turn the heading.
function _lean(q) {
	return multiplyQuat(_yawQuat(-_headingOf(q)), q);
}

// The signed turn from `from` to `to` the short way round, in (-π, π].
function _shortest(from, to) {
	let d = (to - from) % (2 * Math.PI);
	if (d > Math.PI) d -= 2 * Math.PI;
	else if (d <= -Math.PI) d += 2 * Math.PI;
	return d;
}

function _moveU(move, t) {
	return _ease(move.ease, clamp01((t - move.start) / (move.end - move.start)));
}

// Where an actor stands at `t` by its first `n` strips: inside the latest move
// begun, or where that move ended, else at home.
function _position(actor, t, n = actor.strips.length) {
	let move = null;
	for (let i = 0; i < n; i++) {
		const s = actor.strips[i];
		if (s.type === 'move' && s.start <= t) move = s;
	}
	if (move === null) return actor.home;
	const p = move._curve.getPointAt(_moveU(move, t));
	return [p.x, p.y, p.z];
}

// The heading at `t` from the actor's first `n` strips, or null to keep the home
// rotation. Time and the spec alone, never what was posed before.
function _heading(actor, t, n, actors) {
	let at = -1;
	for (let i = 0; i < n; i++) {
		const s = actor.strips[i];
		if (s.start <= t && (s.type === 'turn' || (s.type === 'move' && s.turn))) at = i;
	}
	if (at < 0) return null;
	const s = actor.strips[at];
	if (s.type === 'move') {
		const u = _moveU(s, t);
		const a = s._curve.getPointAt(Math.max(0, u - 1e-3));
		const b = s._curve.getPointAt(Math.min(1, u + 1e-3));
		if (Math.hypot(b.x - a.x, b.z - a.z) > 1e-6) return Math.atan2(b.x - a.x, b.z - a.z);
		return _heading(actor, t, at, actors);
	}
	// A turn starts from the heading it found and ends facing its target.
	const from = _heading(actor, s.start, at, actors) ?? actor.homeHeading;
	const pos = _position(actor, s.start, n);
	const target = s.point ?? _position(actors[s.target], s.start);
	const dx = target[0] - pos[0], dz = target[2] - pos[2];
	if (Math.hypot(dx, dz) <= 1e-6) return from;
	const u = _ease(s.ease, clamp01((t - s.start) / (s.end - s.start)));
	return from + _shortest(from, Math.atan2(dx, dz)) * u;
}

export class Cutscene {
	constructor(spec, options = null) {
		if (options !== null && options !== undefined) {
			if (typeof options !== 'object') throw new TypeError(`${WHERE} wants an options object`);
			for (const key of Object.keys(options)) {
				if (!OPTION_KEYS.includes(key)) {
					throw new TypeError(`${WHERE}: '${key}' is not an option — this call takes: ${OPTION_KEYS.join(', ')}`);
				}
			}
		}
		const read = _readSpec(spec);
		this.spec = spec;
		this.duration = read.duration;
		this._camera = read.camera;
		this._events = read.events;
		this._fired = read.events.map(() => false);
		this._handlers = new Map();
		this._time = 0;
		this._playing = false;
		this._done = false;
		this._disposed = false;
		this.driveCamera = options?.camera !== false;
		this.restoreCamera = options?.restoreCamera !== false;
		this._held = null;

		this._actors = read.actors.map(a => {
			const object = this._resolve(a.row, options);
			const r = object.rotation;
			const q = a.place ? a.place.rotation : quatFromEulerXYZ([r.x, r.y, r.z]);
			return {
				row: a.row, node: a.node, strips: a.strips, object,
				home: a.place ? a.place.position.slice() : object.position.toArray(),
				homeRotation: a.place ? eulerXYZFromQuat(q) : [r.x, r.y, r.z],
				homeHeading: _headingOf(q),
				lean: _lean(q),
				clip: null,
				holding: false,
			};
		});

		// The one-off clips the file holds, put on the actors' assets until dispose().
		this._oneOffs = [];
		try {
			for (const actor of this._actors) this._adopt(actor, read.file);
		} catch (error) {
			this._release();
			throw error;
		}
	}

	// Every one-off clip this actor plays, bound to it by stub name and added to
	// its asset. A strip then plays it by the name it was given there, which is
	// its own unless the asset already had a clip called that.
	_adopt(actor, file) {
		const strips = actor.strips.filter(s => s.animation !== undefined);
		if (strips.length === 0) return;
		const object = actor.object;
		if (!object._asset || !object._clips) {
			throw new TypeError(`${WHERE}: actor '${actor.row}' plays the one-off clip '${strips[0].clip}' from ${file}, and only the root of an asset.instantiate() or asset.node() tree can play a clip — this object came from no file`);
		}
		const named = new Map();
		for (const strip of strips) {
			let name = named.get(strip.animation);
			if (name === undefined) {
				const gltfNode = object._gltfNode >= 0 ? object._gltfNode : -1;
				name = H.cutsceneClip(file, strip.animation, object._asset, gltfNode, actor.node, strip.clip, actor.row);
				named.set(strip.animation, name);
				this._oneOffs.push({ object, asset: object._asset, name });
				object._clips = [...object._clips, name];
			}
			strip.clip = name;
		}
	}

	_release() {
		for (const { object, asset, name } of this._oneOffs) {
			H.cutsceneDropClip(asset, name);
			if (object._clips) object._clips = object._clips.filter(n => n !== name);
		}
		this._oneOffs = [];
	}

	_resolve(row, options) {
		const actors = options?.actors;
		let found = null;
		if (actors instanceof Map) found = actors.get(row) ?? null;
		else if (actors && typeof actors === 'object') found = actors[row] ?? null;
		if (!found && options?.level?.objects) found = options.level.objects.get(row) ?? null;
		if (!found && options?.scene?.getObjectByName) found = options.scene.getObjectByName(row) ?? null;
		if (!found) {
			throw new RangeError(`${WHERE}: no object for actor '${row}' — pass { level }, { actors: { ${row}: object } } or { scene }`);
		}
		return found;
	}

	get time() { return this._time; }
	get playing() { return this._playing; }
	get done() { return this._done; }

	on(name, fn) {
		if (typeof fn !== 'function') throw new TypeError(`cutscene.on('${name}', fn) wants a function`);
		if (!this._handlers.has(name)) this._handlers.set(name, []);
		this._handlers.get(name).push(fn);
		return this;
	}

	once(name, fn) {
		const wrapped = (e) => { this.off(name, wrapped); fn(e); };
		return this.on(name, wrapped);
	}

	off(name, fn = null) {
		if (fn === null) this._handlers.delete(name);
		else {
			const list = this._handlers.get(name);
			if (list) {
				const at = list.indexOf(fn);
				if (at >= 0) list.splice(at, 1);
			}
		}
		return this;
	}

	// A throwing handler is reported and the scene carries on.
	_emit(name, event) {
		const list = this._handlers.get(name);
		if (!list) return;
		for (const fn of list.slice()) {
			try { fn(event); } catch (error) {
				console.log(`three.cutscene: a '${name}' handler threw — ${error && error.message ? error.message : error}`);
			}
		}
	}

	_fire(i) {
		this._fired[i] = true;
		const e = this._events[i];
		this._emit(e.name, { ...e.data, name: e.name, at: e.at });
	}

	play() {
		this._alive('play()');
		if (this._done) this.seek(0);
		this._playing = true;
		this._evaluate(this._time, true);
		_start(this);
		return this;
	}

	pause() {
		this._alive('pause()');
		if (!this._playing) return this;
		this._playing = false;
		_stop(this);
		this._evaluate(this._time, true);
		return this;
	}

	// Events before `t` count as passed without firing; ones from `t` on fire again.
	seek(t) {
		this._alive('seek(t)');
		const at = Math.max(0, Math.min(this.duration, _num(t, 0, 'cutscene.seek(t)')));
		this._time = at;
		this._done = false;
		this._events.forEach((e, i) => { this._fired[i] = e.at < at; });
		this._evaluate(at, true);
		return this;
	}

	// To the end: only events marked `always` still fire, then 'end'.
	skip() {
		this._alive('skip()');
		if (this._done) return this;
		this._events.forEach((e, i) => { if (!this._fired[i] && e.always) this._fire(i); });
		this._fired.fill(true);
		this._time = this.duration;
		this._evaluate(this.duration, true);
		this._finish();
		return this;
	}

	// Also takes the file's one-off clips off the actors' assets, so a character
	// still holding one goes back to its rest pose.
	dispose() {
		if (this._disposed) return;
		this._playing = false;
		_stop(this);
		this._releaseCamera();
		this._release();
		this._disposed = true;
	}

	_alive(where) {
		if (this._disposed) throw new Error(`cutscene.${where}: this cutscene was disposed`);
	}

	_advance(dt) {
		if (!this._playing) return;
		this._time = Math.min(this.duration, this._time + dt);
		this._evaluate(this._time, false);
		for (let i = 0; i < this._events.length; i++) {
			if (!this._fired[i] && this._events[i].at <= this._time) this._fire(i);
		}
		if (this._time >= this.duration) this._finish();
	}

	_finish() {
		this._playing = false;
		this._done = true;
		_stop(this);
		if (this.restoreCamera) this._releaseCamera();
		this._emit('end', { name: 'end', at: this.duration });
	}

	// The whole picture at `t`. `exact` re-poses clips at their time (seek,
	// pause); otherwise a clip is only started when its strip is entered.
	_evaluate(t, exact) {
		for (const actor of this._actors) this._pose(actor, t, exact);
		if (this.driveCamera && this._camera.length > 0) this._aim(t);
	}

	_pose(actor, t, exact) {
		const object = actor.object;
		object.position = _position(actor, t);
		const heading = _heading(actor, t, actor.strips.length, this._actors);
		object.rotation = heading === null ? actor.homeRotation
			: eulerXYZFromQuat(multiplyQuat(_yawQuat(heading), actor.lean));

		// What it plays: the latest strip begun that has a clip and has not ended.
		let active = null;
		for (const s of actor.strips) {
			if (s.start > t || s.clip === null || s.type === 'turn') continue;
			if (s.type === 'move' && t > s.end) continue;
			active = s;
		}
		if (active === null) {
			if (actor.clip !== null) {
				actor.clip = null;
				object.stop();
			}
			return;
		}
		// A play strip with an end stops there and keeps the pose it ends on: a hair
		// before `end` for a loop, so one that ends on a whole cycle holds the cycle's
		// last frame, as Blender does, rather than wrapping to its first.
		const holding = active.hold && t >= active.end;
		const speed = this._playing && !holding ? active.speed : 0;
		let local = active.offset + ((holding ? active.end : t) - active.start) * active.speed;
		if (holding && active.loop && local > HOLD_BEFORE) local -= HOLD_BEFORE;
		if (exact) {
			object.play(active.clip, { loop: active.loop, speed, time: local });
		}
		else if (actor.clip !== active) {
			object.play(active.clip, { loop: active.loop, speed, time: local, fade: active.fade });
		}
		else if (actor.holding !== holding) {
			object.play(active.clip, { loop: active.loop, speed, time: local });
		}
		actor.clip = active;
		actor.holding = holding;
	}

	_aim(t) {
		const keys = this._camera;
		let i = 0;
		while (i + 1 < keys.length && keys[i + 1].at <= t) i++;
		const a = keys[i];
		let eye = a.eye, target = a.target, fov = a.fov;
		const b = keys[i + 1];
		if (b && !b.cut && t > a.at) {
			// The key arrived at says how: a baked camera's keys are linear.
			const u = _ease(b.ease, clamp01((t - a.at) / (b.at - a.at)));
			eye = eye.map((v, k) => lerp(v, b.eye[k], u));
			target = target.map((v, k) => lerp(v, b.target[k], u));
			if (fov !== null && b.fov !== null) fov = lerp(fov, b.fov, u);
		}
		this._takeCamera();
		const c = H.cameraGet();
		const o = _orbit(eye, target);
		H.cameraSet(target[0], target[1], target[2], o.yaw, o.pitch, o.distance, fov ?? c.fov, 0);
	}

	// The camera as it was, kept the first time a key drives it.
	_takeCamera() {
		if (this._held !== null) return;
		const c = H.cameraGet();
		this._held = { camera: c, controls: H.controlsGet() };
		if (H.cameraAttached()) H.cameraDetach();
		H.controlsSet(false);
	}

	_releaseCamera() {
		if (this._held === null) return;
		const { camera: c, controls } = this._held;
		H.cameraSet(...c.target, c.yaw, c.pitch, c.distance, c.fov, c.roll);
		H.controlsSet(controls);
		this._held = null;
	}

	toString() {
		const state = this._done ? 'done' : this._playing ? 'playing' : 'paused';
		return `Cutscene(${state}, ${this._time.toFixed(2)}/${this.duration}s)`;
	}
}

export const cutscene = {
	create(spec, options = null) { return new Cutscene(spec, options); },

	// A `.cutscene.glb` / `.gltf`, CUSTOM_cutscene version 1 or 2.
	load(path, options = null) {
		const spec = _readFile(path);
		try {
			return new Cutscene(spec, options);
		} catch (error) {
			// Named after the file, which is the thing to go and fix.
			if (error instanceof Error) {
				error.message = `three.cutscene.load('${path}'): ${error.message.replace(`${WHERE}: `, '')}`;
			}
			throw error;
		}
	},
};
