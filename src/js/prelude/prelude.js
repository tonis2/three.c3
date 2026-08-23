// three.c3 — the tier-1 scene API, as an agent sees it.
//
// This file is the API surface from `plan.md` §4. It is deliberately JavaScript
// rather than C3: the shape an agent has memorized is Three.js's, and matching
// it means constructors, prototype chains, getters that write through, and a
// `children` array that behaves like an array. Writing that in the host means
// one C3 function per property per class; writing it here means the host only
// has to expose flat verbs, and every Three.js-ism above them is ordinary JS.
//
// `js/bind_scene.c3` installs `globalThis.__three` — the flat verb layer — before
// this runs. Nothing here may assume anything else exists.
//
// ## Local transforms live here, not in the host
//
// `position`/`rotation`/`scale` are JavaScript numbers, and a write pushes all
// nine to the node in one call. That is safe only because nothing on the host
// side ever writes the local transform of a node JS created — the renderer reads
// world matrices, and world matrices are derived. If that ever stops being true,
// these become read-through accessors and this comment is the reason why.
//
// ## An object is not in the scene until it is added
//
// `new three.Mesh(ref)` creates no host node. `scene.add(m)` does, and that is
// what makes an unadded mesh invisible the way it is in Three.js rather than
// quietly rendering. Everything set before the add — transform, name, visibility,
// whole subtrees — is replayed onto the node at that moment (`_materialize`).

//
// ## One module space, many files
//
// This file is the entry of the `three:` module space: the parts beside it are
// embedded in the binary and resolve through the same loader a game's imports
// do, under a prefix a game cannot reach. The import graph bottoms out at
// math.js, api.js assembles the `three` object from everything else, and the
// two lines below are the whole reason any of it runs: the API an agent
// writes against is these globals, never an import.

import { Vector3 } from './math.js';
import { three } from './api.js';

globalThis.three = three;
globalThis.Vector3 = Vector3;
