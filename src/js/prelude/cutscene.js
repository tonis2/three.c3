// three.c3 — three.cutscene: plays a `.cutscene.json` timeline of actor
// strips, camera keys and named events. See `## Cutscene` in docs/classes.md.
//
// One pure pose-at-time (`_evaluate`) serves both playback and seeking, so a
// scrubbed frame and a played frame are the same frame. The frame system is
// installed only while something plays, as cooldown.js does.
import { systems } from './systems.js';
import { CatmullRomCurve3, clamp01, lerp } from './math.js';

const H = globalThis.__three;

const WHERE = 'three.cutscene.create(spec, options)';
const OPTION_KEYS = ['level', 'actors', 'scene', 'camera', 'restoreCamera'];
const STRIP_TYPES = ['move', 'play'];
const EASES = ['linear', 'in', 'out', 'inout'];
const SYSTEM = 'cutscene';

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

function _readStrip(raw, where) {
	if (raw === null || typeof raw !== 'object') throw new TypeError(`${where} is not an object`);
	if (!STRIP_TYPES.includes(raw.type)) {
		throw new RangeError(`${where}: type is ${STRIP_TYPES.map(t => `'${t}'`).join(' or ')}, not ${JSON.stringify(raw.type)}`);
	}
	const strip = {
		type: raw.type,
		start: _num(raw.start, 0, `${where}.start`),
		end: raw.end === undefined ? null : _num(raw.end, 0, `${where}.end`),
		clip: raw.clip ?? null,
		loop: raw.loop ?? raw.type === 'move',
		speed: _num(raw.speed, 1, `${where}.speed`),
		fade: _num(raw.fade, 0.2, `${where}.fade`),
	};
	if (strip.clip !== null && typeof strip.clip !== 'string') throw new TypeError(`${where}.clip is a clip name`);
	if (raw.type === 'move') {
		if (strip.end === null || !(strip.end > strip.start)) {
			throw new RangeError(`${where}: a move needs an end after its start`);
		}
		if (!Array.isArray(raw.path) || raw.path.length < 2) {
			throw new RangeError(`${where}: a move needs a path of at least 2 points`);
		}
		strip.path = raw.path.map((p, i) => _triple(p, `${where}.path[${i}]`));
		strip.ease = raw.ease ?? 'inout';
		if (!EASES.includes(strip.ease)) throw new RangeError(`${where}.ease is one of ${EASES.join(', ')}`);
		strip.turn = raw.turn !== false;
		strip._curve = new CatmullRomCurve3(strip.path);
	}
	return strip;
}

// Turn the spec into checked, sorted tracks. Throws a sentence naming the bad field.
function _readSpec(spec) {
	if (spec === null || typeof spec !== 'object') throw new TypeError(`${WHERE} wants a cutscene object`);
	if (spec.format !== undefined && spec.format !== 'three-cutscene') {
		throw new TypeError(`${WHERE}: format is 'three-cutscene', not ${JSON.stringify(spec.format)}`);
	}
	const actors = (spec.actors ?? []).map((a, i) => {
		const where = `actors[${i}]`;
		if (typeof a?.row !== 'string' || a.row === '') throw new TypeError(`${where}.row names the object to drive`);
		const strips = (a.strips ?? []).map((s, k) => _readStrip(s, `${where}.strips[${k}]`));
		strips.sort((x, y) => x.start - y.start);
		return { row: a.row, strips };
	});
	const camera = (spec.camera ?? []).map((k, i) => ({
		at: _num(k.at, 0, `camera[${i}].at`),
		eye: _triple(k.eye, `camera[${i}].eye`),
		target: _triple(k.target, `camera[${i}].target`),
		fov: k.fov === undefined ? null : _num(k.fov, 0, `camera[${i}].fov`),
		cut: !!k.cut,
	})).sort((a, b) => a.at - b.at);
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
	return { actors, camera, events: events.filter(e => e.name !== 'end'), duration };
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
			return {
				row: a.row, strips: a.strips, object,
				home: object.position.toArray(),
				homeRotation: [r.x, r.y, r.z],
				clip: null,
			};
		});
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

	dispose() {
		if (this._disposed) return;
		this._playing = false;
		_stop(this);
		this._releaseCamera();
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
		// Where it stands: inside the latest move begun, or where that move ended.
		let move = null;
		for (const s of actor.strips) if (s.type === 'move' && s.start <= t) move = s;
		const object = actor.object;
		if (move === null) {
			object.position = actor.home;
			object.rotation = actor.homeRotation;
		}
		else {
			const u = _ease(move.ease, clamp01((t - move.start) / (move.end - move.start)));
			const p = move._curve.getPointAt(u);
			object.position = [p.x, p.y, p.z];
			if (move.turn) {
				const a = move._curve.getPointAt(Math.max(0, u - 1e-3));
				const b = move._curve.getPointAt(Math.min(1, u + 1e-3));
				if (Math.hypot(b.x - a.x, b.z - a.z) > 1e-6) {
					const r = object.rotation;
					object.rotation = [r.x, Math.atan2(b.x - a.x, b.z - a.z), r.z];
				}
			}
		}

		// What it plays: the latest strip begun that has a clip and has not ended.
		let active = null;
		for (const s of actor.strips) {
			if (s.start > t || s.clip === null) continue;
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
		const speed = this._playing ? active.speed : 0;
		const local = (t - active.start) * active.speed;
		if (exact) {
			object.play(active.clip, { loop: active.loop, speed, time: local });
		}
		else if (actor.clip !== active) {
			object.play(active.clip, { loop: active.loop, speed, time: local, fade: active.fade });
		}
		actor.clip = active;
	}

	_aim(t) {
		const keys = this._camera;
		let i = 0;
		while (i + 1 < keys.length && keys[i + 1].at <= t) i++;
		const a = keys[i];
		let eye = a.eye, target = a.target, fov = a.fov;
		const b = keys[i + 1];
		if (b && !b.cut && t > a.at) {
			const u = _ease('inout', clamp01((t - a.at) / (b.at - a.at)));
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

	load(path, options = null) {
		if (typeof path !== 'string' || path === '') {
			throw new TypeError('three.cutscene.load(path, options) wants a path in the assets directory');
		}
		const text = H.assetText(path);
		if (text === null) throw new Error(`three.cutscene.load: '${path}' is not there`);
		return new Cutscene(JSON.parse(text), options);
	},

	save(path, spec) {
		if (typeof path !== 'string' || path === '') {
			throw new TypeError('three.cutscene.save(path, spec) wants a path in the assets directory');
		}
		const plain = spec instanceof Cutscene ? spec.spec : spec;
		_readSpec(plain);
		return H.assetWriteText(path, JSON.stringify({ format: 'three-cutscene', version: 1, ...plain }, null, '\t') + '\n');
	},
};
