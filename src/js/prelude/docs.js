// three.c3 — the machine-readable docs, `three.getApiDocs()`'s answer.
//
// Strings about the API, beside the code they describe so the two drift
// together or not at all. Deliberately import-free: the class names in here
// are prose, and the one live call is `H.keyNames()`, so the key table an
// agent reads and the table the host searches stay one list.

const H = globalThis.__three;

// -----------------------------------------------------------------------
// The docs
//
// `plan.md` §4: ship this from day one. The agent's one real disadvantage
// against Three.js is that it has not memorized this API, and a
// machine-readable dump of the surface is the cheapest possible mitigation.
// It lives beside the code it describes so the two drift together or not
// at all.

export const DOCS = {
	version: '0.1.0',
	summary:
		'A Three.js-shaped scene API over Vulkan. Every mesh placed with the same ' +
		'asset reference is one instanced draw call — there is no batching step to ' +
		'invoke and no way to write an unbatched scene.',
	differences: {
		'load-is-synchronous': 'three.load(path) is synchronous; await works but is not needed.',
		'measure-everything': 'Everything placeable can be MEASURED, and you should measure rather than guess. asset.mesh(name).bounds and geometry.bounds are a Box3 in the piece\'s own space, read out of the glTF JSON so it costs no upload; object.boundingBox() is the world-space box of a subtree, from the host; object.boundsInParent() is the same box in the parent\'s frame and works before add(). A kit piece\'s origin is wherever its exporter left it, so a size table written by hand into a script is the thing that goes stale and sinks pieces into walls.',
		'align': 'object.align(axis, edge, at) moves an object until one face of its box sits at a coordinate — align(\'y\', \'min\', 0) stands a piece on the ground, align(\'z\', \'min\', wallZ) puts its back flush with a wall. object.alignTo(other, {axis, mine, theirs, offset}) says the same thing against a sibling. Both work in the PARENT\'s frame, because that is the frame a script writes positions in; alignTo refuses objects with different parents rather than being wrong by whatever the parents differ by. Set rotation and scale first — they are inputs to where the box is.',
		'debug-draw': 'There is DEBUG DRAW, and reaching for it is the cheap move: three.BoxHelper(object) boxes what an object actually occupies, three.Box3Helper(box) boxes a Box3 you worked out yourself, three.AxesHelper(size) shows where a pivot is and which way it faces, three.GridHelper(size, divisions) says where the ground is, and three.WireframeHelper(mesh) draws a mesh\'s own edges — which is how two faces 0.01 apart are found, because a z-fighting starburst is invisible in a solid render. They are ordinary meshes: a thousand of them are one draw call, helper.color is per copy and free, scene.remove(helper) works, and they are NOT pickable, so a click goes through the box onto the thing inside it.',
		'helpers-draw-over': 'Helpers draw OVER everything — the line pipeline tests no depth, unlike Three.js\'s helpers. That is deliberate: the times you ask where something is are the times it is inside a wall, and a depth-tested helper would be hidden by exactly the geometry being asked about. The cost of being ordinary meshes is the other direction: a helper draws, so it is inside boundingBox(), inside the boundsInParent() of whatever it hangs from, and inside three.camera.frameAll(). Align first and add helpers after, or hang them from a Group of their own.',
		'helper-material': 'A helper cannot be given a ShaderMaterial. A material is a pipeline and every pipeline you can build draws triangles, while a helper\'s indices are pairs — assigning one would read the pairs as triangles rather than fail, so it throws instead. helper.color is the knob a helper has.',
		'geometry-kinds': 'Geometry is BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry, ConeGeometry, TorusGeometry and ConvexGeometry, built for you with Three.js\'s signatures, defaults and orientations. There is no BufferGeometry, no attribute access and no way to read or write a vertex — that refusal is what makes every scene one instanced draw per unique shape.',
		'convex-geometry': 'new three.ConvexGeometry(points) is the way to make a shape that is not one of the six parametric ones: hand over a cloud of points and get its convex hull. Rocks, crystals, gems, debris, the bound of a scan. It takes Vector3s, [x, y, z]s or a flat array of coordinates, needs at least 4 points, and is capped at 65536. It is flat shaded, because a hull\'s faces meet at hard creases, and it is textured face by face: each facet gets its own planar projection at one uv unit per unit of local space, so a map is the same size on a hull as on a box beside it. The points are a description the hull is computed from, not the mesh\'s vertices — most of them are discarded and none can be read back.',
		'geometry-identity': 'Two geometries with the same numbers are ONE asset and one draw call, however many times you construct them. Two different sizes are two. Prefer mesh.scale over a new size when you want variety cheaply.',
		'mesh-construct': 'new three.Mesh(geometry, material) takes either a generated shape or asset.mesh(name); material is optional, as in Three.js.',
		'color-and-variant-only': 'mesh.color and mesh.variant are the ONLY two things copies sharing a geometry and a material may differ in without becoming separate draw calls. A thousand meshes in a thousand colours is one call; giving two of them different materials is two. There is no InstancedMesh because every mesh is already an instance.',
		'uniform-tables': 'A ShaderMaterial uniform may be a table — { palette: [[1,0,0], [0,1,0]] } becomes float3 palette[2] and mesh.variant picks the row. That is how one material gives many meshes many looks. s.variant is clamped to the table, so an index past the end is the last row. A table is not capped at the push block: past 104 bytes the array columns move to a device buffer on their own and the body is unchanged, so hundreds of rows is an ordinary thing to ask for (up to 256 KiB, which is thousands). PLAIN uniforms — the ones with no rows — do stay in the push block and are still held to that 104.',
		'vertex-stage': 'A ShaderMaterial has a vertex stage as well as a fragment one: { vertex: `void displace(inout Vertex v) { v.position.y += sin(v.local.x * 3 + t) * 0.4; }` } moves geometry per vertex with no draw call, no upload and no geometry change — the mesh is still the same asset and a thousand copies of it are still one call. Vertex is the varyings: position (world), normal, uv, color and variant are read back after your body runs, and local (object space) and index (the vertex number) are inputs. The normal is not recomputed for you. Always pass `bounds` with a vertex body — the number of world units it can displace by — because culling tests the mesh\'s undisplaced box and geometry outside it is dropped while still on screen.',
		'one-module': 'The vertex body and the fragment body compile into ONE Slang module, vertex first. So a helper function may be declared in only one of them — declaring `float3 ripple(float2 q)` in both is `error[E30201]: function \'ripple\' already has a body`, which is correct and surprising. Put shared helpers in `vertex`, which comes first, and call them from `fragment`.',
		'material-samplers': 'A ShaderMaterial or a post pass may declare up to four samplers of its own: { textures: { noise_map: tex } } makes noise_map.Sample(uv) work in the body. You never write a binding number — the shader is generated with the bindings in it and the host resolves each name through the compiled module\'s reflection, so adding one at the front of the list renumbers nothing. material.map is separate and is still the base colour image. A sampler declared and left null reads 1x1 white rather than reading nothing, and both objects are live: mat.textures.noise_map = other swaps the image with no compile.',
		'no-colour-management': 'Colours are linear rgb in 0..1 (hex is divided by 255, not de-gamma\'d): there is no colour management here, and half of one would be worse than none.',
		'one-scene': 'There is one scene at a time. new three.Scene() empties it, and handles into the previous scene throw.',
		'manual-free': 'Nothing is freed until you say so. scene.unload() empties the scene and gives back every asset and texture nothing else holds; three.unloadUnused() does the freeing without the emptying. Neither is a garbage collector — resident memory that depended on when the interpreter felt like collecting would be the worst possible property for the one number a game watches — and stats().assets is how you watch it work.',
		'stale-handles': 'An asset handle goes stale when the asset is unloaded, because the host reuses the slot. Placing one throws a sentence saying so — at the scene.add(), which is where the handle is used, not at the new three.Mesh(), which is still only a description. Loading the file again gives a fresh handle. This is the same rule object handles follow across new three.Scene().',
		'camera-is-a-turntable': 'There is one camera, a turntable: three.camera.orbit(yaw, pitch, distance) and three.camera.frameAll(). It is read-ONLY through accessors — camera.yaw/.pitch/.distance/.fov/.near/.far read back, camera.position()/forward()/right() give the eye and the look/strafe directions in world space, and camera.planarMove(fwd, strafe) turns a W/A/S/D input into a world direction. There is no camera.position to assign, and yaw/pitch/distance throw if assigned.',
		'spatial-queries': 'There are BULK SPATIAL QUERIES, and they go through an index rather than a scan: three.query.sphere(point, radius), three.query.box(box), three.query.raycastAll(origin, direction) and three.query.sweep(from, to, { radius, height }). scene.raycast goes through the same index, which is why it stopped being linear in the node count — it used to test EVERY node in the scene before it reached any BVH, and a hundred agents casting one ground ray apiece cost 2.1 ms in a 500-node demo. The index is rebuilt by the first query after anything moved and by nothing else, so a frame that asks nothing pays nothing and the hundredth ray in a frame costs a cell walk. Every verb comes in two forms: three.query.sphere(p, r) allocates an Array of objects and is right for a click or a one-off, and three.query.sphere(p, r, buffer) fills a three.query.buffer(n) you keep and answers with a count, which is right for the loop. box and sphere are BROAD phase — box against box — so a node whose box overlaps and whose triangles do not is included; raycastAll and sweep are exact.',
		'move-and-slide': 'three.moveAndSlide(position, motion, options) is the character controller: it sweeps a capsule, slides along what it hits, climbs a ledge under the step height and reports whether it is standing on anything. It takes a POSITION and answers with a position — it does not own an object, integrates nothing and remembers nothing between calls, so gravity, the velocity and the jump stay yours. Options are { radius, height, step, slope, skin, snap, ignore }; height is the whole capsule, and slope in degrees decides grounded, whether a ledge is climbed and whether a contact is a floor or a wall, all from one number so three cannot disagree. Pass the character\'s own object as ignore or it collides with its own mesh. It is kinematic and touches no rigidbody: a character built out of physics is pushed by contacts, tips over and answers a frame late. Not to be confused with three.character(), which is the higher-level helper that rides a height field and does not collide with anything.',
		'navigation': 'three.nav.bake({ cell, radius, height, slope }) voxelizes the scene\'s standing room, and NOTHING bakes it for you — call it after the level is built. Then TWO verbs, and the split is the design: three.nav.path(from, to) is one agent\'s route, and three.nav.field(goals) is a solve KEPT that a whole crowd samples. A path solves the entire reachable set and throws it away, so a hundred agents heading for one door is a hundred solves for one field. A field has direction(point), cost(point) — Infinity for unreachable — and dispose(). Paths come back shortened against the actual geometry with a capsule sweep at the agent\'s own size, so they do not look like they are walking cell centres, and their waypoints sit on the floor. cell decides everything: it is the resolution AND the largest step that can be climbed, because two cells are connected when they are adjacent and one cell up. three.nav.stats() reports voxels, walkable and bakeMs so you can find out whether the bake is a level-boundary operation or a loading screen.',
		'steering': 'three.steer(positions, velocities, options) fills a Float32Array with a desired velocity per agent — seek, arrive and separation, for the whole crowd, in ONE crossing. positions is three floats per agent and is read; velocities is three floats per agent and is written. Options are { field, goal, maxSpeed, arrive, separation, separationWeight }; a field wins over a goal, because a field already knows the way round a wall. What comes back is a DESIRED velocity, not a position: integrating it and deciding whether an agent may actually go there are yours, which is what lets the same call feed three.moveAndSlide for agents that collide and a plain add for agents that do not.',
		'batched-transforms': 'three.batch(objects) moves many nodes in one crossing, through a Float32Array. It is NOT a faster way to move a dozen things and should not be reached for as one — five hundred ordinary mesh.position.set calls measure 0.245 ms a frame, three per cent of the budget, and the trigger for this is about two thousand nodes a frame. It is for the case where the write is already a loop over numbers: a crowd steered by three.steer, a particle field, a chunked terrain. batch.positions is a Float32Array seeded from where the objects are now; batch.flush() writes them and answers with how many landed. With { trs: true } the stride is ten floats — position, an xyzw QUATERNION, then scale.',
		'pointer-lock': 'three.input.pointerLock = true takes the mouse pointer out of the user\'s hands, and what it buys is a look that does not STOP. Without it three.input.pointer.dx is a difference of cursor positions, and a cursor stops at the edge of the screen while a hand does not — so a mouse look turns until the pointer reaches the edge and then quietly refuses to turn further. Reading the property back tells you whether the platform gave it, not what you asked for: a headless run has no window and always reads false, and so does a backend with no implementation. Nothing throws, so a game can fall back to a drag-look rather than refuse to start. three.input.pointer.locked is the same fact reported beside the deltas it is about.',
		'damping-and-curves': 'three.damp(current, target, lambda, dt) and three.smoothDamp(current, target, state, smoothTime, dt) are the two verbs between "where it is" and "where it should be", and both are frame-rate independent — which is the whole reason they are named rather than written inline. `x += (target - x) * 0.1` closes a tenth of the gap per FRAME, so it is twice as fast at 120 Hz as at 60 and a chase tuned on one machine is a different chase on another. damp is a decay, right for a camera easing onto a target; smoothDamp is a critically damped spring with momentum, right for a turret slew or a sliding panel, and its state object must OUTLIVE the frame or it is re-launched from rest every tick. three.dampAngle takes the short way round a circle, which is what a heading needs. dt is in SECONDS: three.clock.dt is milliseconds, so it is three.clock.dt / 1000 at every call site. new three.CatmullRomCurve3(points) is the three-dimensional curve a loop samples — getPointAt(u) walks its LENGTH and getPoint(t) walks its own parameter, and the difference is what makes hand-written rail code look wrong.',
		'camera-follow': 'The camera can FOLLOW something: three.camera.attach(object, { offset, distance, lag }) puts the orbit point on that object every frame, after the animation, the physics and your animation callback have all moved it — so the camera is never a frame behind, which is what makes a trailing camera look like the character sliding. three.camera.detach() stops, three.camera.attached is what it is following or null. A drag still orbits and the wheel still zooms while attached; a PAN is the one gesture that stops working, because a pan writes the orbit point and the next frame writes it back.',
		'camera-first-person': 'FIRST PERSON is distance 0, and it is not a mode: the eye sits on the point it orbits, so three.camera.attach(character, { offset: [0, 1.7, 0], distance: 0 }) is a person and scrolling back out is a third-person camera again with nothing to switch. The offset is where the head is, in WORLD space — [0, 1.7, 0] is the same vector whichever way a character faces. Aim it with three.camera.orbit(yaw, pitch), leaving the distance argument off, and three.input.pointer.dx/dy is what a mouse look feeds it.',
		'camera-planes-derived': 'The near and far planes are derived, not set: from the orbit distance and from the scene\'s own bounds, every time the camera moves. Three.js makes them constructor arguments to PerspectiveCamera. Read them — three.camera.near and .far — when something has stopped being drawn, because geometry past far is absent rather than dim and is culled as well as clipped. Assigning either throws rather than being ignored.',
		'one-light': 'There is one light and it is not an Object3D: three.light.direction is a world-space surface-to-light vector and three.light.ambient is the floor an unlit face gets, 0 to 1. three.light.set(direction, ambient) does both. Not scene.add(new DirectionalLight(...)), because there is no second light and no colour per light — the name is different so nothing reads as a promise the renderer cannot keep. The direction is not normalized, so it reads back as you wrote it, and a zero one throws rather than turning every shaded pixel into a NaN. Defaults to [0.35, 0.8, 0.45] with an ambient of 0.25, and a new Scene restores that.',
		'shadows-off-by-default': 'It does cast a shadow, and it is off until you ask: three.light.shadow = true, or three.light.shadow = { enabled: true, size: 4096 }. The four properties are enabled, size (texels per side, clamped to 256..8192 and rounded down to a power of two), bias (extra depth offset in the light\'s clip space, 0 by default) and intensity (how dark, 0 to 1). Nothing is allocated and no shader is compiled until the first frame with it on, and a new Scene turns it back off.',
		'shadow-cast-receive': 'Everything opaque casts and everything shaded receives — there is no castShadow or receiveShadow per object, because two copies of one mesh disagreeing about it would be two draw calls and this renderer is built to refuse that trade. A transparent material casts nothing (a shadow map holds one depth per texel, so glass would have to be either solid or absent, and absent is the better wrong answer) and neither does a debug helper. A ShaderMaterial receives shadows with no change to its body: lambert() already has the shadow folded into the direct term, and s.shadow is the raw factor for a body that wants it separately.',
		'shadow-one-map': 'One map, fitted around the whole scene every frame, so its resolution is size divided by however wide the scene is. If shadows look blocky the scene is large, not the map small: raise three.light.shadow.size, or draw the part that matters and leave the rest out. There are no cascades. Self-shadowing stripes should not appear — each sample is lifted two texels along its own normal first — and if they do, three.light.shadow.bias is the knob, in small numbers like 0.0005.',
		'shadow-costs-a-draw': 'A shadow pass costs a second draw call per opaque bucket — stats().shadowDraws is the count — and it turns frustum culling off for the frame, because a caster the camera cannot see still throws a shadow into the frame. So stats().culledLastFrame reads 0 while shadows are on. Neither costs draw calls: culling here drops instances from buckets, never buckets. Mark the scenery object.static = true and that second pass all but disappears — see the static-casters topic.',

		'background-is-a-colour': 'scene.background is a colour or null, never a Texture: [r,g,b], 0x87ceeb, or null for the default. There is no environment map and no scene.environment. A gradient sky is still geometry — what this removes is having to build one to escape the default near-black.',
		'colours-are-srgb': 'Every colour you state is sRGB — the components a colour picker gives. mesh.color = 0xff8040 renders as 0xff8040 under a full light, scene.background = 0x2060a0 screenshots as 0x2060a0, and a texture\'s bytes come back out as the bytes that went in. The shading arithmetic in between is linear and the conversion is the renderer\'s job, so nothing in a script should ever apply a gamma of its own; a scene that pre-corrects its own textures will now be twice corrected.',
		'side-is-on-the-material': 'material.side is on the material and not on the mesh, because it is a property of the pipeline: two meshes sharing a geometry and a material are one draw call and would stop being one if they could disagree about it. three.BackSide is how a skydome is made visible from inside; scaling a sphere by -1 does not work, because a negative scale does not reverse a triangle\'s winding.',
		'add-to-add': 'An object is not in the scene until it is add()ed, and removing it makes it a detached description that can be added again.',
		'group-for-belonging': 'A Group is how several objects stay one object. Nothing else records that they belong together: siblings built by one loop and placed by the same arithmetic have no relationship the scene graph can see, so a later edit that moves one leaves the others where they were. Parent the pieces of a thing to a Group, place them relative to it once, and move the Group instead. It costs a node and no draw call.',
		'name-things': 'name is empty until a script sets it and getObjectByName answers null for a miss, both as in Three.js — so a node nobody named is reachable only through traverse, and a misspelled one is a null that throws somewhere else. Name whatever a later script will look for. asset.instantiate() trees need no help: the root takes the file name and every node under it keeps the name the file gave it.',
		'fragment-not-program': 'ShaderMaterial takes a fragment function, not a whole program: you write float3 shade(Surface s) and three.c3 supplies the vertex stage, the Surface and the uniform block. Uniforms are flat values, not Three.js\'s { value } wrappers.',
		'post-is-a-chain': 'There is post-processing and it is a CHAIN, not an EffectComposer: three.setPost({ fragment }) runs a float3 post(Post p) over the finished frame, three.addPass({ fragment }) puts another after it, and three.setPost(null) stops all of them. There are no render targets to manage and no dependency declarations — a pass reads what the pass before it wrote as p.color and the frame as the geometry left it as p.scene, and those two are the whole model. The chain runs in linear float, so a pass may return values above 1 and the next one still sees them, which is what a bright pass followed by a blur needs; the encode to the display happens once, at the end, and is the engine\'s. It applies to the window, to render() and to screenshots alike, and it belongs to the renderer rather than to the scene, so it survives new three.Scene() and outlives the script that set it.',
		'mesh-no-material': 'A mesh with no material draws with the base colour and texture its glTF material carried.',
		'no-raycaster': 'There is no Raycaster. scene.pick(x, y) takes pixels of the rendered image and scene.raycast(origin, direction) takes a world ray; both answer with the closest hit or null, not with an array.',
		'script-scope': 'Each run_script call runs in its own function scope. Use globalThis to keep state between calls.',
		'animation-loop': 'three.setAnimationLoop(fn) runs fn once per frame, with the elapsed milliseconds, until three.setAnimationLoop(null). It is how a scene moves without an agent in the loop. The callback must be synchronous, is stopped for good if it throws or runs longer than 100ms in one frame, and what it logs comes back with the next run_script under an [animation loop] marker.',
		'game-clock': 'There is a GAME CLOCK, which Three.js has nothing quite like: three.clock.dt is what the frame being drawn is worth in seconds, three.clock.time is what the frames have added up to, and three.clock.timeScale is the multiplier — 0 is paused. It is not a convenience over differencing the callback\'s argument yourself. Everything in a frame that moves is downstream of it — the clips, the physics, the fixed loop, the follow camera, the argument setAnimationLoop is handed and p.time in a post body — so timeScale = 0 stops the WORLD, which no amount of a script stopping its own arithmetic can do.',
		'fixed-loop-for-gameplay': 'Gameplay belongs in three.setFixedLoop(fn), which runs at three.clock.fixedRate (60 Hz) however fast frames arrive and hands the callback the same dt every call. Drawing the consequence belongs in setAnimationLoop. The accumulator is the host\'s: one written in the animation callback spends the script budget catching up and gets the callback stopped for good instead of merely stuttering.',
		'animation-loop-freezes-render': 'A running animation loop makes render() and screenshot() no longer repeatable — the scene has moved between them. three.clock.timeScale = 0 is the finer instrument: it freezes the world without unregistering anything, and three.clock.advance(seconds) then steps it by exactly as much as you ask, so two runs asking for the same amount draw the same frame. setAnimationLoop(null) still stops the callback outright.',
		'keyboard': 'There is a keyboard, which Three.js has no equivalent of at all: three.input.isDown(key) for held keys, three.input.pressed(key)/released(key) for this frame\'s edges, and three.onKeyDown(key, fn)/onKeyUp(key, fn) to bind an action. Key names are the browser\'s KeyboardEvent.key lowercased — three.input.keys() lists every one. It only reports anything while a window is open: --headless has no keyboard.',
		'script-can-press-keys': 'A script can press keys itself: three.input.press(key), three.input.release(key) and three.input.releaseAll(). A pressed key stays down until released, exactly as a finger does, and goes through the same path a real one does — so isDown, pressed, released and every onKeyDown handler cannot tell the two apart. It adds to the real keyboard rather than replacing it. This is what makes an input-driven scene testable at all: a headless boot has no keyboard, so without it the only way to exercise a character was for the scene to hand its internals to a global.',
		'keys-read-per-frame': 'Keys are read once per frame, so three.input.pressed() and three.input.text mean something inside the animation callback and almost never outside one. isDown() is fine anywhere.',
		'mouse-is-one-thing': 'There is a mouse, and it is one thing: three.onClick(fn) calls fn(hit, x, y) with what is under the cursor already picked. three.input.pointer is everything else about it for this frame — position, movement, all three buttons and the wheel. There is no mouseDown and no drag events: the left button orbits the camera, a press that travels or is held is a drag rather than a click, and the buttons are latches a script polls rather than edges anything dispatches.',
		'mouse-look-and-no-pointer-lock': 'A mouse look is three.input.pointer.dx and .dy, not a difference you take yourself between frames — the host differences the reading the frame is actually drawing with, while two calls from a script straddle it. There is NO POINTER LOCK, so the movement stops at the edge of the screen where the platform stops the cursor: a look that must keep turning forever needs the cursor recentred, and nothing here can do that yet.',
		'controls-can-be-taken': 'The camera\'s hand on the window can be taken away: three.controls.enabled = false stops the mouse orbiting, panning and zooming, and is what a scene that drives its own camera every frame needs — otherwise the turntable writes yaw and pitch again underneath it and the two fight over one matrix sixty times a second. It does not stop three.camera.orbit(), which is a script moving the camera on purpose. Turn it back on when the mode ends: a window nobody can move the camera in is a bad way to leave one, and there is no gesture that undoes it.',
		'pointer-is-in-image-pixels': 'three.input.pointer and the click are in the rendered image\'s pixels, not the window\'s. The window shows the image stretched to fit it, so the two differ on a retina display and after any resize; scene.pick(x, y) and the PNG use the same pixels the click does, whatever size the window is.',
		'physics-world': 'There is a physics world, which Three.js has no equivalent of at all: object.body = { shape, mass } describes a body and three.physics.add(object) gives the object one. It is XPBD with real contacts, friction, restitution, joints and triggers — not a demo. Y is down: three.physics.gravity is [0, -9.8, 0] and there is no axis to configure.',
		'physics-steer-a-body': 'A dynamic body is steered with three.physics.setVelocity(object, [x, y, z]) and pushed with three.physics.applyImpulse(object, [x, y, z]) — set a speed for a character, add an impulse for a jump or a hit. Between them a dynamic capsule with a velocity set each frame is a character controller: it walks and it collides, which no combination of the other verbs can do. Reading back is three.physics.velocity(object). Static and kinematic bodies refuse both by name, because for those the transform is the only thing that moves them.',
		'physics-owns-transform': 'The solver owns a dynamic body\'s transform, and writing to it throws. That is the one place in this API where two writers are not resolved by last-writer-wins — a solver and a script writing the same transform every frame produce jitter rather than a compromise. Give the body kind \'kinematic\' to drive it from a script, or three.physics.remove(object) to take the body away. A body with mass 0 is static and is not owned, because it never moves.',
		'physics-fixed-60hz': 'Physics runs at a fixed 60 Hz whatever rate frames arrive at, and the accumulator is the host\'s rather than the animation callback\'s — so a slow frame stutters instead of spending the script budget and stopping the callback for good. A frame that ran very long catches up at most five steps and drops the rest, which is the difference between a stutter and a spiral. What it steps by is GAME time, so three.clock.timeScale scales the world and 0 stops it falling; three.clock.fixedRate is the gameplay rate and does not touch the solver\'s.',
		'collider-from-mesh': 'A collider comes from the mesh, not from numbers you supply: \'box\' and \'sphere\' are its own bounds, \'capsule\' is the bounds about Y, \'heightfield\' is a TerrainGeometry\'s own grid of heights — one shape for a whole landscape, at any slope, where the alternative is a chain of invisible boxes and a path forced flat to have them — and \'hull\' is the convex hull of its points — which is the same collision::quickhull that built a ConvexGeometry, so a convex rock\'s collider is exactly its own geometry rather than an approximation of it.',
		'export-round-trips': 'The scene comes back OUT with scene.export(path, options) — a .glb with one mesh per unique geometry, so what the file says about sharing is what the frame says. Round-trips: export it, three.load it, and the draw-call count is the same, per-copy colours included. Sibling copies of one shape are written as a single node carrying an array of transforms (EXT_mesh_gpu_instancing, which any glTF reader can place) with a _COLOR_0 array beside them holding each copy\'s mesh.color; a reader that does not know _COLOR_0 gets them in the material\'s own colour rather than in the wrong place. A copy with no sibling drawing the same shape keeps its name and its own material instead, which costs no draw call, and groups are never collapsed. Siblings that share a shape but not a material do not batch either — a colour travels per copy in _COLOR_0, a texture or a blend mode has no per-copy channel — so they come back as the two draws they were. Two things are left out on purpose — helpers and hidden subtrees, because the export is what the frame shows, and ShaderMaterials, because a material here is a Slang pipeline and glTF describes surfaces rather than programs.',
		'static-casters': 'A shadow pass rasterises every caster every frame, which for a village is the largest thing in the frame. Say object.static = true on whatever will not move again — buildings, ground, walls, scenery — and those are drawn into the shadow map once and kept; each frame after that draws only what moved. It costs no draw call in the colour pass, so marking ten thousand crates is free, and moving one afterwards is safe (the map is rebuilt) rather than wrong. scene.traverse(o => o.static = true) is the usual way to say it. Watch three.stats().shadowStaticDraws: 0 on most frames means the cache is holding. Refused on skinned meshes — a pose changes the silhouette without the transform moving — and reading .static back is how you see that.',
		'return-is-the-value': 'Return a value from your script with `return`; it comes back as the `value` field.',

	},
	classes: {
		Scene: {
			construct: 'new three.Scene()',
			note: 'Empties the one host scene and becomes its root. It is an Object3D, so moving it moves everything.',
			methods: [
				'add(...objects)', 'remove(...objects)', 'traverse(fn)', 'getObjectByName(name)', 'stats()',
				'unload()', 'export(path)', 'pick(x, y)', 'raycast(origin, direction)', 'getWorldPosition()',
				'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
				'play(name, { loop, speed, time })', 'stop()', 'toJSON()',
			],
			properties: [
				'position', 'rotation', 'scale', 'visible', 'name', 'children', 'parent', 'animations',
				'static (marks the whole scene as not moving again — see the static-casters topic)',
				'background (the clear colour: [r,g,b], 0x87ceeb, or null for the default)',
				// three.light rather than a scene property: it is per renderer, like
				// three.camera, and listing it here would suggest two scenes could
				// disagree about it.
			],
		},
		Mesh: {
			construct: 'new three.Mesh(geometry, material)',
			note:
				'geometry is a generated shape (new three.BoxGeometry(1, 1, 1)) or a reference from '
				+ 'asset.mesh(name) / asset.meshAt(i). material is optional. N meshes sharing one geometry '
				+ 'AND one material is one draw call.',
			properties: [
				'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'material', 'children', 'parent',
				'color (per copy, free: [r,g,b], [r,g,b,a] or 0xff8800)',
				'variant (per copy, free: which row of the material\'s table)',
				'static (this will not move again: drawn into the shadow map once and kept)',
				'animations (empty unless this came from asset.instantiate())',
			],
			methods: [
				'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
				'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
				'play(name, opts)', 'stop()', 'toJSON()',
			],
		},
		Material: {
			construct: 'not constructed — it is what MeshLambertMaterial and ShaderMaterial share',
			note:
				'The base both materials extend, exported for instanceof and for the two properties '
				+ 'they have in common. mesh.material accepts anything that is one. Assigning a '
				+ 'material to a helper throws whatever kind it is: a helper draws line pairs and '
				+ 'every pipeline you can build draws triangles.',
			properties: [
				'map (a three.texture, or null; wins over whatever image the mesh itself carries)',
				'side (three.FrontSide, three.BackSide or three.DoubleSide)',
				'transparent (whether it blends; derived from blending, and read-only — see blending)',
				'blending (three.NoBlending, three.NormalBlending or three.AdditiveBlending; decided at construction and NOT settable — this device bakes blending into the pipeline, so a change is a new material, which is one line)',
				'opacity (0 to 1, settable and free — it rides the push block. Does NOTHING unless the material was built transparent, because an opaque pipeline discards the alpha; that is the hardware\'s answer and Three.js behaves the same way)',
				'repeat ([u, v], or one number for both: how many times the map is laid across the surface. 1 by default; zero throws)',
				'offset ([u, v]: where the map starts, in whole repeats)',
				'alive (false once dispose() has been called on it)',
			],
			methods: ['dispose()', 'toJSON()'],
		},
		DataTexture: {
			construct: 'new three.DataTexture(data, width, height, { colorSpace, generateMipmaps })',
			note:
				'Pixels a script built, uploaded as a texture. data is a Uint8Array (or a plain '
				+ 'Array, which is copied) of width*height*4 bytes in r, g, b, a order, row-major '
				+ 'from the bottom-left corner — uv (0,0) is bottom-left, as it is in Three.js. '
				+ 'RGBA8 only, and it is on the device when the constructor returns: there is no '
				+ 'needsUpdate here and nothing to schedule. Deduplicated against every other '
				+ 'texture by content, so generated pixels and the identical .png are one upload. '
				+ 'It is a Texture in every other way — map, dispose, width, height. Generating '
				+ '256x256 in JavaScript costs about 16ms before any of this, so build at load '
				+ 'rather than per frame. path is null; the side limit is 8192. The fourth '
				+ 'argument is the same options object three.texture takes rather than a format, '
				+ 'and both options matter more here than there: generated pixels are as often a '
				+ 'TABLE indexed exactly — a palette, a ramp, a lookup a shader reads — as a '
				+ 'picture, and a table wants { colorSpace: three.LinearSRGBColorSpace, '
				+ 'generateMipmaps: false }, because its channels are numbers and a blurred mip '
				+ 'level of a lookup approximates nothing.',
			properties: [
				'width', 'height', 'path (null)', 'alive',
				'colorSpace (\'srgb\' or \'srgb-linear\'; fixed at upload)',
				'levels (how many mip levels it got)',
				'generateMipmaps (whether it got a chain — the answer, not the request)',
			],
			methods: ['read(into)', 'dispose()', 'toJSON()', 'toString()'],
		},
		Texture: {
			construct: 'three.texture(path, { colorSpace, generateMipmaps })',
			note:
				'A PNG or JPEG on the device. Synchronous — it is uploaded by the time the call '
				+ 'returns, so width and height are readable immediately and there is no onLoad. '
				+ 'The format is read from the file\'s first bytes, not its extension. Images are '
				+ 'deduplicated by content AND by colourspace: two paths holding the same picture, '
				+ 'or a .png and the identical image inside a .glb, are one upload — each call '
				+ 'still answers with its own handle. Under --assets the path is inside the game '
				+ 'directory and cannot climb out of it. Put it on something with new '
				+ 'three.MeshLambertMaterial({ map }). 16-bit PNGs are refused by name; save as '
				+ '8-bit. read() copies the pixels back off the device. '
				+ 'THE OPTION WORTH KNOWING ABOUT IS colorSpace. It defaults to sRGB, which is '
				+ 'right for a picture of something and wrong for a map whose channels are numbers '
				+ '— a normal map, a roughness or metalness or occlusion map, a height field. '
				+ 'Those want three.LinearSRGBColorSpace, and getting it wrong has no error and no '
				+ 'obvious symptom: a normal map read as sRGB has its "no tilt" 0.5 decoded to '
				+ '0.21, so every surface leans the same way and the detail goes soft. '
				+ 'A full mip chain is built unless you say otherwise, so a textured floor stops '
				+ 'shimmering at grazing angles. An option this does not have is refused rather '
				+ 'than ignored — there is no magFilter or wrapS here.',
			properties: [
				'width', 'height', 'path', 'alive',
				'colorSpace (\'srgb\' or \'srgb-linear\'; fixed at upload, so load again to change it)',
				'levels (how many mip levels it got)',
				'generateMipmaps (whether it got a chain — the answer, not the request)',
			],
			methods: ['read(into)', 'dispose()', 'toJSON()', 'toString()'],
		},
		MeshLambertMaterial: {
			construct: 'new three.MeshLambertMaterial({ map, side, transparent, blending, opacity })',
			note:
				'The built-in shader with an image on it — the material to reach for when what you '
				+ 'want is a picture on a shape. It compiles nothing and cannot fail with a shader '
				+ 'diagnostic. Lambert is what it actually computes: one directional light and an '
				+ 'ambient floor, no specular and no environment. It has no color, because mesh.color '
				+ 'is the per-copy channel and multiplies into the sampled texel — so one material '
				+ 'tints a thousand copies differently and is still one draw call. With no map it is '
				+ 'the cheapest way to ask for a side, which is what a skydome needs.',
			properties: [
				'map (a three.texture, or null; settable)',
				'side (three.FrontSide, three.BackSide or three.DoubleSide; settable)',
				'transparent (whether it blends; derived from blending, and read-only — see blending)',
				'blending (three.NoBlending, three.NormalBlending or three.AdditiveBlending; decided at construction and NOT settable — this device bakes blending into the pipeline, so a change is a new material, which is one line)',
				'opacity (0 to 1, settable and free — it rides the push block. Does NOTHING unless the material was built transparent, because an opaque pipeline discards the alpha; that is the hardware\'s answer and Three.js behaves the same way)',
				'repeat ([u, v], or one number for both: how many times the map is laid across the surface. 1 by default; zero throws)',
				'offset ([u, v]: where the map starts, in whole repeats)',
				'alive (false once dispose() has been called on it)',
			],
			methods: ['dispose()', 'toJSON()'],
		},
		ShaderMaterial: {
			construct: "new three.ShaderMaterial({ fragment, vertex, uniforms, textures, bounds, side, transparent, blending, opacity })",
			note:
				'fragment is a Slang function `float3 shade(Surface s)` returning linear rgb. '
				+ 'Surface has albedo, normal, uv, position, color (this copy\'s own, already in albedo), '
				+ 'vertex_color (the mesh\'s own COLOR_0 attribute, interpolated across the triangle, '
				+ 'white where the file carried none, and NOT already in albedo — it is the one value '
				+ 'here that varies across a surface, so it is a painted weight as often as a tint), '
				+ 'shadow (how much of the directional light reaches this point, 1 in the open and 0 '
				+ 'under something; 1 everywhere with shadows off, and already folded into lambert() '
				+ 'so a body does not have to read it to be shadowed) '
				+ 'and variant (its row of the table, clamped). Each uniform is readable in the body by '
				+ 'its own name; a uniform written as an array of arrays is a table column, read as '
				+ 'name[s.variant]. textures is the same idea for images: { noise_map: tex } declares a '
				+ 'Sampler2D called noise_map that the body samples by that name — noise_map.Sample(uv) — '
				+ 'and up to eight of them. You never write a binding number: the shader is generated with '
				+ 'the bindings in it and the host resolves each name back through the compiled module\'s '
				+ 'own reflection. Sample with any uv you like, which is the point — s.uv + float2(t, 0) '
				+ 'scrolls, s.uv * 4 tiles, float2(k, 0.5) reads a gradient as a lookup table. A sampler '
				+ 'left null, or one you never fill, reads as 1x1 opaque white rather than as nothing. '
				+ 'Three helpers are already in scope in a body. lambert(normal) is the built-in '
				+ 'directional light as a single factor, so `return s.albedo * lambert(s.normal)` '
				+ 'IS the default look — the shadow is inside it, on the direct term and not on the '
				+ 'ambient floor, so a material written before shadows existed lands in the same '
				+ 'shadow the default shading does. srgb_to_linear(c) decodes a colour you wrote down yourself. '
				+ 'And mapped_normal(s, texel) applies a tangent-space NORMAL MAP: hand it the '
				+ 'map\'s rgb exactly as sampled and it answers with a world-space normal to give '
				+ 'lambert — `float3 n = mapped_normal(s, bumps.Sample(s.uv).rgb); return s.albedo '
				+ '* lambert(n);`. The meshes here carry no tangents, so the frame is rebuilt per '
				+ 'pixel from screen-space derivatives: it works on any textured mesh including a '
				+ 'generated primitive, it is fragment-stage only, and it cannot see the seam of a '
				+ 'mirrored uv island. LOAD THE MAP WITH { colorSpace: three.LinearSRGBColorSpace } '
				+ '— through the default sRGB the stored 0.5 that means "no tilt" arrives as 0.21, '
				+ 'every surface leans the same way and the bumps go soft. '
				+ 'Compiles on construction, so a bad shader throws here, carrying the '
				+ 'Slang diagnostic with the line number you wrote. Needs a GPU device. '
				+ 'shade() returns rgb and never alpha: how much of the surface shows is the '
				+ 'material\'s opacity times this copy\'s mesh.color alpha, so a body cannot make '
				+ 'geometry invisible by accident and a script can, deliberately. discard works in a '
				+ 'body and is how a dissolve or a cutout is done, since the alpha is not yours to return. '
				+ 'vertex is the other half: a Slang function `void displace(inout Vertex v)` that runs '
				+ 'per vertex, before anything is projected. Vertex IS the varyings — write v.position '
				+ '(world space, after the mesh\'s own transform) to move the vertex, and v.normal, v.uv, '
				+ 'v.color, v.vertex_color and v.variant to change what the fragment stage receives; v.local (object '
				+ 'space, before the transform) and v.index (the vertex number, a per-vertex seed) are '
				+ 'inputs only. Waves, flags, breathing, jitter, explosions, a mesh that inflates on a '
				+ 'hit — all of them are one line here and none of them costs a draw call, because the '
				+ 'geometry never changes. The normal is NOT recomputed from what you do to the position: '
				+ 'write v.normal yourself if you moved the surface enough for the lighting to care. '
				+ 'A sampler reads with SampleLevel(uv, 0) in a vertex body, not Sample — there are no '
				+ 'derivatives to pick a mip with. Omitting fragment is allowed once vertex is given: it '
				+ 'defaults to the built-in lit look. '
				+ 'bounds is what a vertex body owes the renderer: how far, in world units, it can move '
				+ 'a vertex. Culling tests a mesh\'s own bounds, so a body that pushes geometry outside '
				+ 'them draws something the frustum was never told about — and the symptom is geometry '
				+ 'vanishing at the edge of the screen and coming back when the camera turns, which reads '
				+ 'as a renderer bug. Set it to the largest displacement your body can produce; too big '
				+ 'costs a draw call that could have been skipped, too small drops geometry you can see.',
			properties: [
				'uniforms (live: mat.uniforms.tint = [1, 0, 0], or mat.uniforms.palette[2] = [1, 0, 0])',
				'textures (live: mat.textures.noise_map = otherTexture, or null to put white back. Only the names given at construction exist; assigning any other throws)',
				'fragment',
				'vertex (the displace body, or an empty string; read-only, like fragment — a new body is a new material)',
				'bounds (how far the vertex body moves a vertex, world units; read-only, and what the frustum test is widened by)',
				'map (a three.texture, or null; sampled as Surface.albedo before your shade() runs)',
				'side (three.FrontSide, three.BackSide or three.DoubleSide; settable, and cheap after the first time each side is asked for)',
				'transparent (whether it blends; derived from blending, and read-only — see blending)',
				'blending (three.NoBlending, three.NormalBlending or three.AdditiveBlending; decided at construction and NOT settable — this device bakes blending into the pipeline, so a change is a new material, which is one line)',
				'opacity (0 to 1, settable and free — it rides the push block. Does NOTHING unless the material was built transparent, because an opaque pipeline discards the alpha; that is the hardware\'s answer and Three.js behaves the same way)',
				'repeat ([u, v], or one number for both: how many times the map is laid across the surface. 1 by default; zero throws)',
				'offset ([u, v]: where the map starts, in whole repeats)',
				'alive (false once dispose() has been called on it)',
			],
			methods: ['dispose()', 'toJSON()'],
		},
		LayeredMaterial: {
			construct: 'new three.LayeredMaterial({ map, normal, mask, layers, side, transparent, blending, opacity })',
			note:
				'An ordered stack of materials blended over a base one — terrain splatting, weathering, '
				+ 'decals. It is a ShaderMaterial whose shade() body is GENERATED from the description, so '
				+ 'everything a ShaderMaterial has it has, and mat.fragment is the Slang that was written '
				+ 'for you — read it when a stack looks wrong. '
				+ 'The base material is map plus the mesh\'s own base colour, exactly as without this: '
				+ 'the layers are extra, and a stack with none of them shades as a MeshLambertMaterial. '
				+ 'layers is an array, OUTERMOST LAST — each is blended over everything under it as '
				+ 'lerp(below, blend(below, layer), mask). '
				+ 'A layer takes: map (its albedo), normal, emissive, emissiveFactor, tint, opacity, '
				+ 'blend, mask, maskSource, maskTexture, invert, uvScale, uvOffset, enabled, animated, name. '
				+ 'mask is WHICH CHANNEL this layer\'s weight is read from — \'r\', \'g\', \'b\' or \'a\' — '
				+ 'which is the economy that makes a four-layer terrain one mask image instead of four. '
				+ 'Pass that image as the top-level mask. A layer with no mask '
				+ 'covers everything; maskTexture gives one layer a mask of its own; invert flips it. '
				+ 'maskSource says which THING the channel belongs to: \'texture\' (the default) or '
				+ '\'vertexColor\', which reads the mesh\'s own COLOR_0 attribute — a weight an artist '
				+ 'painted per vertex, costing no sampler and no image at all. '
				+ 'A layer that states no colour — no map, no tint, not animated — leaves what is under it '
				+ 'alone rather than blending white over it, so { emissive: glow } only glows and '
				+ '{ normal: bumps } only adds detail. White is what the file\'s own default is, which makes '
				+ 'it the absence of a statement about colour; use a white map to paint white deliberately. '
				+ 'blend is \'mix\' (the default), \'multiply\', \'add\', \'subtract\', \'screen\', \'overlay\', '
				+ '\'softLight\', \'difference\', \'darken\' or \'lighten\' — Blender\'s Mix node modes, because '
				+ 'that is where the glTF extension this implements comes from. '
				+ 'uvScale is per layer and TILES THE DETAIL WITHOUT TILING THE MASK, which is the whole '
				+ 'trick of a splat map: the mask describes one specific surface, the detail maps repeat '
				+ 'across it. It composes with material.repeat rather than replacing it. '
				+ 'EVERYTHING IS BAKED INTO THE SHADER AS A LITERAL unless you say animated: true on a '
				+ 'layer, which promotes its tint and opacity to a uniform you can write every frame — '
				+ 'mat.layers[2].opacity = 0.25. That costs 16 of the material\'s 104 uniform bytes, so at '
				+ 'most six layers may be animated; the rest are free and cost the push block nothing. '
				+ 'The real ceiling is SAMPLERS: eight, counting one per layer map, normal, emissive and '
				+ 'own mask, plus one for the shared mask. The base map does not count. { enabled: false } '
				+ 'drops a layer and its samplers entirely, which is how you get back under it. '
				+ 'LOAD MASKS AND NORMAL MAPS WITH { colorSpace: three.LinearSRGBColorSpace } — their '
				+ 'channels are numbers rather than colours, and through the default sRGB every weight '
				+ 'comes out wrong. '
				+ 'metalness, roughness, subsurface, height and bump are REFUSED rather than ignored: '
				+ 'lambert() is the whole of the built-in light, so there is no equation for them to feed, '
				+ 'and a material property that provably changes no pixel is worse than an error. '
					+ 'asset.mesh(name).layers hands you a description straight out of a glTF authored with '
				+ 'CUSTOM_materials_layers, so new three.LayeredMaterial(ref.layers) is the whole import.',
			properties: [
				'layers (a view per enabled layer: layers[i].map = tex swaps an image, and '
				+ 'layers[i].tint / layers[i].opacity read and write the ones declared animated)',
				'fragment (the generated Slang — read-only, and the thing to look at first)',
				'uniforms, textures (the ShaderMaterial proxies, under the generated names)',
				'map, side, transparent, blending, opacity, repeat, offset, alive (as ShaderMaterial)',
			],
			methods: ['dispose()', 'toJSON()'],
		},
		Group: {
			construct: 'new three.Group(), or asset.instantiate()',
			note:
				'Transforms its children and draws nothing itself, which makes it the way to keep several '
				+ 'objects one object: parent the pieces, place them relative to the Group once, and afterwards '
				+ 'there is one transform to move rather than a convention to remember. '
				+ 'asset.instantiate() answers with one '
				+ 'of these carrying the file\'s own node hierarchy, and that one is what animations, '
				+ 'play(name, {loop, speed}) and stop() work on — a glTF clip drives a whole subtree, so '
				+ 'its root is where it is played. On a hand-built Group animations is empty and play() '
				+ 'throws saying which door to use. There is no AnimationMixer: one clip at a time, no '
				+ 'crossfade.',
			methods: [
				'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
				'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
				'play(name, opts)', 'stop()', 'toJSON()',
			],
			properties: [
				'position', 'rotation', 'scale', 'visible', 'name', 'children', 'parent',
				'static (this will not move again: see the static-casters topic)',
				'animations (clip names, from asset.instantiate())',
			],
		},
		Box3: {
			construct: 'new three.Box3(minX, minY, minZ, maxX, maxY, maxZ)',
			note:
				'An axis-aligned box, and the answer to "how big is this actually". A kit piece\'s origin '
				+ 'is wherever whoever exported it left it, so nothing about a transform says where the '
				+ 'piece\'s faces are — which is what "put this window on that wall" is really asking. '
				+ 'size and center are derived from min/max rather than stored. '
				+ 'edge(axis, which) is one face\'s coordinate, and is what align() is written in terms of.',
			properties: ['min', 'max', 'size', 'center'],
			methods: ['edge(axis, \'min\' | \'center\' | \'max\')', 'union(other)', 'clone()', 'toJSON()', 'toString()'],
		},
		MeshRef: {
			construct: 'not constructible — asset.mesh(name) and asset.meshAt(i) answer with these',
			note:
				'One piece of a loaded file: the handle new three.Mesh() wants, plus bounds. Reading bounds '
				+ 'costs no upload — the box comes out of the glTF JSON at load, so asking how big two '
				+ 'hundred kit pieces are before placing twelve of them still uploads twelve. It is not '
				+ 'cached: a reference that outlives its asset throws rather than answering with the size '
				+ 'the mesh used to be.',
			properties: [
				'asset', 'assetGeneration', 'mesh', 'name', 'bounds (a Box3 in the mesh\'s own space)',
				'layers (this mesh\'s CUSTOM_materials_layers stack as a three.LayeredMaterial '
				+ 'description, or null when its material never carried the extension. '
				+ 'new three.LayeredMaterial(ref.layers) is the whole import, and what you get first is a '
				+ 'plain object you may edit — drop a layer, retune an opacity, mark one animated. '
				+ 'UNLIKE EVERYTHING ELSE ON A MeshRef THIS UPLOADS THE MESH, because a stack is texture '
				+ 'slots and slots exist only once the primitive is on the device — and every read hands '
				+ 'back fresh Texture handles each holding a reference, so read it once and keep what it '
				+ 'gave you)',
				'material (what this primitive\'s glTF material said, beyond the base colour the mesh '
				+ 'already draws with: { alphaMode, alphaCutoff, doubleSided, normalMap, emissive, '
				+ 'emissiveMap, emissiveIntensity, aoMap, metalness, roughness, metalnessRoughnessMap }, '
				+ 'or null for a primitive that names no material. THIS IS WHAT THE LOADER USED TO DROP. '
				+ 'Each map arrives with its colourspace already right — normal, occlusion and '
				+ 'metallic-roughness are data and load linear, emissive is a colour and loads sRGB — '
				+ 'which is decided by the importer rather than by you and is the difference between a '
				+ 'normal map that works and one that leans every surface the same way. It is a '
				+ 'DESCRIPTION and not a material: what to build from it is yours, and '
				+ 'asset.instantiate({ materials: true }) is the shorter door. aoMap has no built-in '
				+ 'term (one line in a shade body multiplies by it) and metalness/roughness have '
				+ 'nothing to feed, because the built-in light is one lambert factor with no specular — '
				+ 'they cross so a ShaderMaterial can do something with them. LIKE layers THIS UPLOADS '
				+ 'THE MESH and every read hands back fresh Texture handles holding references, so read '
				+ 'it once and keep it)',
			],
			methods: [
				'split() — cut this mesh into its connected components and get one geometry back per '
				+ 'piece. THE ANSWER TO A KIT THAT ARRIVED AS ONE MERGED MESH: a town square with 23 '
				+ 'buildings in it, or a pack of four animals, is one transform and one bounding box '
				+ 'until it is cut, so nothing in it can be placed, rotated, culled or picked on its own. '
				+ 'Two triangles are in the same piece when they share a vertex, which is the right cut '
				+ 'for a merged kit (they are merged by concatenation, so nothing welds them) and no cut '
				+ 'at all for a surface that is genuinely connected — a terrain with the houses extruded '
				+ 'out of it comes back whole. Length one means it was already one thing, and the one '
				+ 'geometry you get is this mesh itself with nothing uploaded. Each piece is an ordinary '
				+ 'geometry: instanced, pickable, exportable, unloadable on its own, carrying the '
				+ 'source\'s colour and base colour map. It does NOT carry a layer stack and a mesh that '
				+ 'has one throws instead of losing it quietly. Expect the pack to include the details '
				+ 'that were modelled as separate shells — eyes, horns, hooves — so filter by '
				+ 'piece.bounds.size if you only want the bodies. Not free and not automatic: it reads '
				+ 'the geometry back and uploads one asset per piece, so it is a load-time step, and '
				+ 'splitting the same mesh twice answers with the same assets.',
				'toJSON()',
				'toString()',
			],
		},
		Vector3: {
			construct: 'new three.Vector3(null, x, y, z)',
			note: 'position/rotation/scale are live Vector3s: writing x, y, z or calling set() moves the object.',
			methods: [
				'set(x,y,z)', 'copy(v)', 'add(v)', 'sub(v)', 'multiplyScalar(s)', 'length()', 'clone()',
				'toArray()', 'toJSON()', 'toString()',
			],
		},
		Asset: {
			construct: 'three.load(path)',
			properties: ['path', 'meshes (names, in load order)', 'animations (clip names)'],
			methods: [
				'mesh(name)', 'meshAt(index)',
				'instantiate(name?, { skeleton, skinning, materials })',
				'toJSON()',
			],
			note:
				'instantiate() is Three.js\'s gltf.scene: the file\'s own node hierarchy as Object3Ds, '
				+ 'with the transforms the file gave them. Use it for anything whose pieces are '
				+ 'positioned by nodes rather than baked into the vertices — a rig, a prop with parts, '
				+ 'a level laid out in Blender. asset.mesh(name) is the other door and is what you want '
				+ 'when you are placing pieces yourself. Instantiating twice gives two independent trees '
				+ 'over one upload. '
				+ '{ materials: true } BUILDS A MATERIAL PER GLTF MATERIAL and puts it on the meshes that '
				+ 'wear it, which is how a .glb authored with alphaMode BLEND renders blended and how a '
				+ 'file\'s normal maps and emissive maps reach the frame — without it the file draws with '
				+ 'its base colour and its base colour map and nothing else, which is what it always did. '
				+ 'It builds nothing for a material that is opaque, single-sided and has no normal or '
				+ 'emissive map, because that is the default material already. Occlusion and '
				+ 'metallic-roughness are not applied; ref.material has them and the reason. Off by '
				+ 'default because it compiles a shader per distinct material, which a scene that was '
				+ 'happy without them should not pay for. '
				+ 'A RIGGED file: the skeleton is left out by default and the character is posed from a '
				+ 'table baked once at load, so a hundred of them is a hundred nodes, one draw call and '
				+ 'one uint per copy per frame — give each a phase with play(name, { time }). '
				+ '{ skeleton: true } keeps the bones as objects and switches that copy onto a palette '
				+ 'computed from them every frame, so writing bone.rotation moves the skin — a look-at, '
				+ 'an aim, a foot on a slope. That is the hero-character option and it costs per copy. '
				+ '{ skinning: \'compute\' } poses the vertices in a compute pass instead of in the vertex '
				+ 'shader; it splits the character into its own draw call and holds a posed copy of the '
				+ 'mesh, and only pays off when the same character is drawn more than once a frame.',
		},
		Geometry: {
			construct: 'not constructible — use one of the seven shapes below',
			note:
				'What every shape is: a handle three.c3 built, carrying the numbers you asked for. Hand it '
				+ 'to new three.Mesh(). Constructing the same shape twice answers with the same asset, so a '
				+ 'geometry per mesh costs nothing and a thousand identical ones are one draw call; two '
				+ 'different sizes are two. There is no BufferGeometry and no attribute access — a script '
				+ 'describes shapes, never vertices, and ConvexGeometry\'s point cloud is a description too. '
				+ 'Sizes are world units and must be positive, segment counts '
				+ 'are capped at 512, Y is up, and every shape is centred on its own origin.',
			properties: [
				'type', 'name', 'parameters (what you asked for, defaults filled in)', 'asset', 'mesh',
				'bounds (a Box3 in the shape\'s own space — what it IS, which is not always what it was asked for)',
			],
			methods: ['toJSON()', 'toString()'],
		},
		BoxGeometry: {
			construct:
				'new three.BoxGeometry(width = 1, height = 1, depth = 1, widthSegments = 1, heightSegments = 1, depthSegments = 1)',
			note: 'A box centred on the origin. The segment counts subdivide it and change nothing about its size.',
			properties: ['bounds'],
			methods: ['toJSON()', 'toString()'],
		},
		SphereGeometry: {
			construct: 'new three.SphereGeometry(radius = 1, widthSegments = 32, heightSegments = 16)',
			note: 'A UV sphere with its poles on the Y axis.',
			properties: ['bounds'],
			methods: ['toJSON()', 'toString()'],
		},
		PlaneGeometry: {
			construct: 'new three.PlaneGeometry(width = 1, height = 1, widthSegments = 1, heightSegments = 1)',
			note:
				'A one-sided rectangle in the XY plane, facing +Z — Three.js\'s orientation, which is '
				+ 'vertical. A floor is this with rotation.x = -Math.PI / 2. From behind it is invisible, '
				+ 'because back faces are culled.',
			properties: ['bounds'],
			methods: ['toJSON()', 'toString()'],
		},
		CylinderGeometry: {
			construct:
				'new three.CylinderGeometry(radiusTop = 1, radiusBottom = 1, height = 1, radialSegments = 32, heightSegments = 1, openEnded = false)',
			note: 'A cylinder or a truncated cone about the Y axis. Either radius may be 0, but not both.',
			properties: ['bounds'],
			methods: ['toJSON()', 'toString()'],
		},
		ConeGeometry: {
			construct:
				'new three.ConeGeometry(radius = 1, height = 1, radialSegments = 32, heightSegments = 1, openEnded = false)',
			note:
				'A cone about the Y axis with its point up. The same triangles as '
				+ 'CylinderGeometry(0, radius, height) — and the same asset, so the two spellings share a draw call.',
			properties: ['bounds'],
			methods: ['toJSON()', 'toString()'],
		},
		TorusGeometry: {
			construct: 'new three.TorusGeometry(radius = 1, tube = 0.4, radialSegments = 12, tubularSegments = 48)',
			note:
				'A ring in the XY plane. radius is measured to the centre of the tube, so the shape is '
				+ '2 * (radius + tube) across and 2 * tube thick.',
			properties: ['bounds'],
			methods: ['toJSON()', 'toString()'],
		},
		ConvexGeometry: {
			construct: 'new three.ConvexGeometry(points)',
			note:
				'The convex hull of a cloud of points, and the way to make a shape that is not one of the '
				+ 'six parametric ones — a rock, a crystal, a gem, a chunk of debris, the bound of a scan. '
				+ 'points is an array of Vector3s, of [x, y, z] or of {x, y, z}, or a flat array or '
				+ 'Float32Array of coordinates; at least 4 points, at most 65536. The hull is flat shaded, '
				+ 'because its faces meet at hard creases. It carries uvs, but they are a projection '
				+ 'rather than an unwrap: every facet is mapped face-on at one uv unit per unit of local '
				+ 'space, so a texture is never stretched and is the same size everywhere on the hull and '
				+ 'on anything beside it — the only artefact is that two facets meeting at a crease do not '
				+ 'line up along the shared edge, which reads as nothing on the noise and grain a rock '
				+ 'wants and as a break on a regular pattern. The points describe the shape, they are not its '
				+ 'vertices — most are discarded and none can be read back. parameters.points is the count '
				+ 'you handed over. Two identical arrays are one asset; two runs of Math.random() are two, '
				+ 'because the key is bit-exact.',
			properties: ['bounds'],
			methods: ['toJSON()', 'toString()'],
		},
		TerrainGeometry: {
			construct: 'new three.TerrainGeometry({ width, depth, segments, heights, skirt })',
			note:
				'Ground that is a surface rather than a pile of boxes, and the only geometry here that '
				+ 'answers questions afterwards. heights is a three.Field, a flat array of '
				+ '(segments + 1) squared numbers row-major in z, or a function (x, z) => y sampled at '
				+ 'the grid points in WORLD coordinates — the same frame everything else in the scene '
				+ 'uses, so one height function can drive the terrain, the mask and the scatter. Omit it '
				+ 'for a flat field to stamp into later. It lies in the xz plane with +y up and is '
				+ 'centred on the origin, its uv runs 0..1 across the whole field so a splat mask lines '
				+ 'up with no transform, and its normals come from the GRID rather than from the '
				+ 'triangles, which is the difference between ground and steps. skirt is how far a wall '
				+ 'drops around the border so the map edge is not a hole. One asset, one draw call: a '
				+ '256-segment field is one vkCmdDrawIndexed. heightAt(x, z) and normalAt(x, z) read the '
				+ 'same grid the mesh was built from, through the same interpolation, so what a script '
				+ 'stands on cannot disagree with what is drawn; off the map the edges extend outwards '
				+ 'rather than dropping to zero.',
			properties: ['bounds'],
			methods: ['heightAt(x, z)', 'normalAt(x, z)', 'toJSON()', 'toString()'],
		},
		RibbonGeometry: {
			construct:
				'new three.RibbonGeometry({ path, width, y, terrain, lift, samples, columns })',
			note:
				'A mesh that follows a curve — a road, a river, a path, a wall — and the answer to "why '
				+ 'does the bend look like it was drawn with a ruler". path is sparse control points '
				+ '([[x, z], ...] or {x, z}) and is bent by the SAME centripetal Catmull-Rom as '
				+ 'three.catmullRom, sampling samples cross-sections per control segment, so you write '
				+ 'the bends you can see and the ribbon is smooth between them. Two modes by the options: '
				+ 'flat at a constant y (a river or pond — a water surface is a plane, not a drape), or '
				+ 'draped over `terrain` (a TerrainGeometry or a Field), where every vertex is '
				+ 'heightAt/valueAt + lift so the strip hugs the ground (a road or a path) and lift keeps '
				+ 'it from z-fighting where it lies. columns is the cross-section: 2 is a straight chord '
				+ 'across the width, more follows a crown or a bank. width is the full width in world '
				+ 'units, u runs across it and v along the length, so a texture flows with the road. One '
				+ 'asset, one draw call, like every other shape — the strip is one mesh, not a row of '
				+ 're-edged boxes.',
			properties: ['bounds'],
			methods: ['toJSON()', 'toString()'],
		},
		Field: {
			construct: 'new three.Field({ width, depth, segments, value })',
			note:
				'A scalar grid in world coordinates — the authoring half of TerrainGeometry, and the '
				+ 'SAME object a splat mask is made of. That is the point rather than a convenience: '
				+ 'carve a river channel and stroke the mud mask from one polyline and the mud is where '
				+ 'the water is by construction, instead of because two functions were kept in step. '
				+ 'Everything mutates in place and returns this, so it chains. fill and add take a '
				+ 'number or an (x, z) => v in world coordinates; flatten({x, z, width, depth}, y) is a '
				+ 'building pad and defaults y to the mean under the rect, which is where the ground '
				+ 'already was; carve(path, width, depth) lowers along a polyline and stroke(path, '
				+ 'width, value) paints along the same one; circle, blur, normalize and clamp finish the '
				+ 'set. Every stamp takes a feather in world units with a smoothstep falloff. '
				+ 'valueAt(x, z) reads it back bilinearly BEFORE any upload, which is what lets a script '
				+ 'place buildings and scatter trees on ground that does not exist on the device yet. '
				+ 'texture() is the field as a mask in all four channels; three.Field.mask({r, g, b, a}) '
				+ 'packs up to four of one resolution into the RGBA image a LayeredMaterial reads, '
				+ 'always linear because a mask is a weight and not a colour.',
			properties: ['width', 'depth', 'segments', 'side', 'values'],
			methods: [
				'fill(v)', 'add(v)', 'flatten(rect, y, feather)', 'carve(path, width, depth, feather)',
				'stroke(path, width, value, feather)', 'circle(x, z, radius, value, feather)',
				'blur(passes)', 'normalize(low, high)', 'clamp(low, high)', 'range()',
				'valueAt(x, z)', 'xAt(i)', 'zAt(j)', 'texture()',
			],
		},
		CatmullRomCurve3: {
			construct: 'new three.CatmullRomCurve3(points, closed, curveType, tension)',
			note:
				'The three-dimensional half of the curve pair, and the one a loop SAMPLES rather than a '
				+ 'bake consumes: a camera rail, a patrol route, a projectile arc, a rope. Three.js\'s '
				+ 'class name and method names, so the line an agent writes from memory is the right '
				+ 'line. curveType is \'centripetal\' (the default), \'chordal\' or \'uniform\' — '
				+ 'centripetal passes through every control point without swinging wide of a tight one, '
				+ 'which is what a hand-written path always has. '
				+ '**getPoint(t) and getPointAt(u) are not the same function**, and the gap between them '
				+ 'is what makes hand-written rail code look wrong: t is the curve\'s own parameter, '
				+ 'spread evenly over the control segments, so an object moving at a constant t per '
				+ 'second speeds up through the widely spaced ones and crawls through the close ones. u '
				+ 'is spread evenly over the LENGTH, and that is the one anything moving wants. '
				+ 'three.catmullRom is the other half of the pair: a GROUND path, [x, z] in and a dense '
				+ 'polyline out, for field.carve, field.stroke and RibbonGeometry.',
			properties: ['points', 'closed', 'curveType', 'tension'],
			methods: [
				'getPoint(t)', 'getPointAt(u)', 'getTangent(t)', 'getLength()',
				'getPoints(count)', 'getSpacedPoints(count)', 'toString()',
			],
		},
		QueryResult: {
			construct: 'three.query.buffer(capacity)',
			note:
				'A reusable answer for the flat form of three.query.sphere and three.query.box. Make it '
				+ 'ONCE, outside the loop: the whole reason it exists is that a query answering with an Array '
				+ 'of objects allocates, and a hundred agents asking every frame is a hundred allocations a '
				+ 'frame. handles is the raw Int32Array of index/generation pairs the host filled, so a script '
				+ 'that only wants to COUNT what is nearby never resolves anything at all; objects() resolves '
				+ 'the lot in one walk of the scene when it does want them. full is true when the query filled '
				+ 'the buffer, which means there may be more it could not tell you about — a count equal to the '
				+ 'capacity is otherwise indistinguishable from a scene that happened to have exactly that many.',
			properties: ['handles', 'capacity', 'count', 'full'],
			methods: ['objects()', 'toString()'],
		},
		TransformBatch: {
			construct: 'three.batch(objects, { trs })',
			note:
				'A Float32Array-shaped bulk write over many nodes, and NOT a faster way to move a dozen '
				+ 'things — five hundred ordinary mesh.position.set calls are 0.245 ms, three per cent of a '
				+ 'frame, and the trigger for reaching here is about two thousand nodes a frame. What it is '
				+ 'for is the case where the write is ALREADY a loop over numbers: a crowd steered by '
				+ 'three.steer, a particle field, a chunked terrain. positions is three floats per object, '
				+ 'seeded from where they are now so a batch made and immediately flushed changes nothing. '
				+ 'With { trs: true } the stride is ten — position, an xyzw QUATERNION, then scale — because a '
				+ 'batch is written by arithmetic and the arithmetic that produced a rotation produced a '
				+ 'quaternion. flush() sends the lot in one crossing and answers with how many landed; a '
				+ 'member that has left the scene is skipped rather than throwing, because a crowd where one '
				+ 'agent was removed this frame is ordinary.',
			properties: ['positions', 'data', 'handles', 'objects', 'trs', 'stride', 'length'],
			methods: ['flush()'],
		},
		NavField: {
			construct: 'three.nav.field(goals)',
			note:
				'A solved flow field over the current three.nav.bake() — the solve KEPT, which is the whole '
				+ 'reason there are two navigation verbs instead of one. three.nav.path solves the entire '
				+ 'reachable set and throws it away after one answer, so a hundred agents heading for the same '
				+ 'door is a hundred solves for one field. direction(point) is a unit XZ vector, or zero for '
				+ 'nowhere to go — standing on the goal, off the mesh, or in a pocket no goal reaches, and '
				+ 'cost(point) is how those are told apart. cost is measured ALONG THE GROUND rather than '
				+ 'through walls, and is Infinity for unreachable. Feed the field to three.steer rather than '
				+ 'calling direction() in a loop: that is one crossing for the whole crowd instead of one per '
				+ 'agent. Freed by dispose() and by new three.Scene(), and nothing else — a field is one float '
				+ 'per walkable cell and this API does not collect.',
			properties: ['alive'],
			methods: ['direction(point)', 'cost(point)', 'reaches(point)', 'dispose()', 'toString()'],
		},
		Box3Helper: {
			construct: 'new three.Box3Helper(box, color = 0xffff00)',
			note:
				'A wire box drawn exactly where a three.Box3 says. The helper to reach for when the box '
				+ 'came from somewhere that is not one object — a plot to fill, a gap to check, the union '
				+ 'of two things. `box` is settable and the helper follows it. It is read in the frame of '
				+ 'whatever the helper is added to, so a box from boundsInParent() belongs under the same '
				+ 'parent and a box from boundingBox() belongs under the scene. Draws over everything: the '
				+ 'line pipeline tests no depth, because the times you ask where something is are the '
				+ 'times it is inside a wall.',
			properties: [
				'box (settable — the helper moves and rescales to it)',
				'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'children', 'parent',
				'color (per copy, free: [r,g,b] or 0xff8800)',
				'material (always null, and assigning throws — a helper draws with the line material)',
				'variant (meaningless here: the line material has no table)',
				'static (meaningless here: a helper casts no shadow to cache)',
				'animations (always empty)',
			],
			methods: [
				'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
				'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
				'play(name, opts)', 'stop()', 'toJSON()',
			],
		},
		BoxHelper: {
			construct: 'new three.BoxHelper(object, color = 0xffff00)',
			note:
				'The box of an object and everything under it — "how big is that actually, and where '
				+ 'does it end". It must hang from the SAME PARENT as the object it measures, and is '
				+ 'refused anywhere else: the box is measured in that frame, so a helper parented '
				+ 'elsewhere would be drawn wherever the two frames differ, which is a box in the wrong '
				+ 'place rather than no box. The usual spelling is therefore the Three.js one — '
				+ 'scene.add(piece); scene.add(new three.BoxHelper(piece)) — and a nested piece takes '
				+ 'piece.parent.add(...). Nothing watches the object, so call update() after moving it.',
			properties: [
				'object (what it measures, read-only)',
				'box (the box it is currently drawn on)',
				'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'children', 'parent',
				'color (per copy, free)',
				'material (always null, and assigning throws)',
				'variant (meaningless here)',
				'static (meaningless here: a helper casts no shadow to cache)',
				'animations (always empty)',
			],
			methods: [
				'update()', 'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)',
				'getWorldPosition()', 'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)',
				'alignTo(other, opts)', 'play(name, opts)', 'stop()', 'toJSON()',
			],
		},
		AxesHelper: {
			construct: 'new three.AxesHelper(size = 1)',
			note:
				'Red +X, green +Y, blue +Z from the origin — where a pivot is and which way it faces, '
				+ 'which is the question a kit piece whose origin is in an unexpected corner makes '
				+ 'somebody ask. Parent it to an object to see THAT object\'s pivot. It is a Group of '
				+ 'three meshes over one segment asset, so a hundred of them are still one draw call. '
				+ 'Remember that a helper parented to a piece is inside that piece\'s box: align first, '
				+ 'add the axes after.',
			properties: [
				'size (settable — rescales the three arms, builds nothing)',
				'position', 'rotation', 'scale', 'visible', 'name', 'children', 'parent',
				'static (meaningless here: a helper casts no shadow to cache)',
				'animations (always empty)',
			],
			methods: [
				'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
				'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
				'play(name, opts)', 'stop()', 'toJSON()',
			],
		},
		GridHelper: {
			construct: 'new three.GridHelper(size = 10, divisions = 10, color = 0x888888)',
			note:
				'A ruled square in the XZ plane, centred on the origin: where the ground is and how big '
				+ 'a metre looks. ONE colour, not Three.js\'s two — the darker centre line would be a '
				+ 'second mesh here for a distinction nothing has needed. Keyed on the divisions alone, '
				+ 'so GridHelper(100, 10) and GridHelper(40, 10) are one asset at two scales and one '
				+ 'draw call. There is no `size` to read back because the size IS the scale: grid.scale.x, '
				+ 'and it is live. Divisions are capped at 256.',
			properties: [
				'divisions (read-only — a different count is a different mesh)',
				'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'children', 'parent',
				'color (per copy, free)',
				'material (always null, and assigning throws)',
				'variant (meaningless here)',
				'static (meaningless here: a helper casts no shadow to cache)',
				'animations (always empty)',
			],
			methods: [
				'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
				'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
				'play(name, opts)', 'stop()', 'toJSON()',
			],
		},
		WireframeHelper: {
			construct: 'new three.WireframeHelper(meshOrGeometry, color = 0xffffff)',
			note:
				'A mesh\'s own triangles as the edges between them — the tool for two faces 0.01 apart '
				+ 'z-fighting into a starburst, which is invisible in a solid render and obvious the '
				+ 'moment the edges are drawn. Takes a Mesh that is already in the scene, or the '
				+ 'geometry / asset.mesh(name) it draws. THE MESH HAS TO BE ON THE DEVICE: a generated '
				+ 'shape is uploaded when it is constructed and works straight away, but a mesh out of a '
				+ 'file reaches the device when something drawing it is added to a scene, and until then '
				+ 'there are no triangles to read — you get a sentence saying so, not an empty helper. '
				+ 'Add it as a CHILD of the mesh — piece.add(new three.WireframeHelper(piece)) — because '
				+ 'the edges are in the mesh\'s own space and a child at the identity transform overlays '
				+ 'it to the pixel. Each shared edge is drawn once. A Group has no triangles of its own: '
				+ 'traverse it and make one per Mesh.',
			properties: [
				'of (the name of the mesh these edges belong to)',
				'position', 'rotation', 'scale', 'visible', 'name', 'geometry', 'children', 'parent',
				'color (per copy, free)',
				'material (always null, and assigning throws)',
				'variant (meaningless here)',
				'static (meaningless here: a helper casts no shadow to cache)',
				'animations (always empty)',
			],
			methods: [
				'add(...)', 'remove(...)', 'traverse(fn)', 'getObjectByName(name)', 'getWorldPosition()',
				'boundingBox()', 'boundsInParent()', 'align(axis, edge, at)', 'alignTo(other, opts)',
				'play(name, opts)', 'stop()', 'toJSON()',
			],
		},
	},
	functions: {
		'three.load(path)':
			'Read a .glb or .gltf. Nothing is uploaded: this parses the JSON and answers with an Asset '
			+ 'that knows its meshes, their bounds and the file\'s node tree. A mesh reaches the GPU when '
			+ 'a Mesh drawing it is added to a scene, so loading a 200-piece kit to place twelve costs '
			+ 'twelve. Under --assets the path is relative to the assets directory and cannot climb out '
			+ 'of it, so three.inventory() paths go straight in; otherwise it is relative to where three '
			+ 'was started. Loading the same path twice returns the same asset — unless it was unloaded '
			+ 'in between, which gives a fresh one and makes the old handle throw. '
			+ 'asset.instantiate() for the file\'s own hierarchy, asset.mesh(name) for one piece of it.',
		'three.render(scene, camera)': 'Draw one frame. camera is optional and must be three.camera.',
		'three.catmullRom(points, options)':
			'A smooth curve through sparse control points, as a dense polyline — the path half of the '
			+ 'curve pair (RibbonGeometry is the mesh half). Pass [[x, z], ...] or {x, z} control points '
			+ 'and get back [[x, z], ...] with samples points per control segment (default 16). Type is '
			+ '\'centripetal\' (default), \'chordal\' or \'uniform\'; centripetal passes through every point '
			+ 'without swinging wide of a tight one, which is what a hand-written road path is. Feed the '
			+ 'result to field.carve / field.stroke / a scatter avoid corridor so a sparse polyline stops '
			+ 'being a black-and-white zigzag, or pass the raw control points to a RibbonGeometry, which '
			+ 'curves them itself. The first and last control points are reproduced exactly.',
		'three.query.sphere(centre, radius, into)':
			'Every drawable node whose bounding box reaches within radius of a point. With no third '
			+ 'argument it answers with an Array of objects; with a three.query.buffer(n) it fills that '
			+ 'and answers with a count, which is the form to use in a loop. A BROAD-phase answer: the '
			+ 'test is against each node\'s box, so something whose box reaches and whose triangles do '
			+ 'not is included. Invisible nodes are left out, as they are for picking.',
		'three.query.box(box, into)':
			'The same, for a Box3, a { min, max } or a flat [minX, minY, minZ, maxX, maxY, maxZ].',
		'three.query.buffer(capacity)':
			'A reusable answer for the flat form of every query verb. Make it once, outside the loop. It '
			+ 'holds .handles (an Int32Array of index/generation pairs), .count, .full — true when the query '
			+ 'filled it, which means there may be more — and .objects(), which resolves them all in ONE walk '
			+ 'of the scene. A script that only wants to count what is nearby never has to resolve anything, '
			+ 'which is most of why this shape exists.',
		'three.query.raycastAll(origin, direction, options)':
			'Every node a ray hits, not only the nearest — shooting through a window, listing what is behind '
			+ 'what, a laser that stops at the first SOLID thing rather than at the first thing. Options are '
			+ '{ maxDistance, limit }. NOT sorted by distance: sorting means holding every hit before '
			+ 'answering, and a caller who wants the nearest should call scene.raycast, which is cheaper than '
			+ 'sorting because it can stop walking.',
		'three.query.sweep(from, to, options)':
			'Move a sphere or an upright capsule from one point to another and report the first thing it '
			+ 'touches, or null. { radius } alone is a sphere; adding { height } makes it a capsule that tall '
			+ 'overall, and { ignore } leaves one object out. The hit carries fraction — where along the '
			+ 'motion it happened — so the safe position is from + (to - from) * fraction. This is the same '
			+ 'narrow phase three.moveAndSlide is built out of, so a wall this reports and a wall a character '
			+ 'slides along cannot be two different walls. There is no orientation argument: everything this '
			+ 'is for stands up.',
		'three.moveAndSlide(position, motion, options)':
			'The character controller. Sweeps a capsule from position by motion, slides along whatever it '
			+ 'hits, climbs a ledge under the step height, and answers with { position, remaining, grounded, '
			+ 'slope, ground, hit, normal, stepped, slides }. Options are { radius, height, step, slope, '
			+ 'skin, snap, ignore } — height is the whole capsule, step is how high a ledge may be, slope in '
			+ 'degrees is the steepest ground that still counts as ground, and snap is how far the floor may '
			+ 'drop under the feet in one frame and still be walked down rather than fallen off. It '
			+ 'integrates nothing: gravity, the velocity and the jump are yours, and a frame is '
			+ 'three.moveAndSlide(where, [vx * dt, vy * dt, vz * dt], opts) followed by copying r.position '
			+ 'onto whatever you are driving. Pass the character\'s own object as ignore. It is KINEMATIC and '
			+ 'touches no rigidbody — see the move-and-slide topic for why that is the design rather than a '
			+ 'limitation.',
		'three.batch(objects, options)':
			'A Float32Array-shaped bulk write over many nodes. batch.positions is three floats per object, '
			+ 'seeded from where they are now; batch.flush() sends the lot in one crossing and answers with '
			+ 'how many landed. With { trs: true } the stride is ten — position, an xyzw QUATERNION, then '
			+ 'scale. A member that has left the scene is skipped rather than throwing, because a crowd where '
			+ 'one agent was removed this frame is ordinary. Do not reach for this to move a dozen things: '
			+ 'five hundred ordinary position writes are three per cent of a frame, and the trigger for this '
			+ 'is about two thousand nodes a frame.',
		'three.nav.bake(options)':
			'Voxelize the scene\'s standing room, so three.nav.path and three.nav.field have a graph to work '
			+ 'over. { cell, radius, height, slope, bounds } — every one a property of the AGENT except the '
			+ 'last. Call it AFTER the level is built; nothing bakes on demand, because that would hide a '
			+ 'cost and would rebake on the first call after anything moved. cell decides everything: it is '
			+ 'the resolution and it is also the largest step that can be climbed, because two cells are '
			+ 'connected when they are adjacent and one cell up — half a metre is a generous stair and a '
			+ 'cheap bake, and a finer one costs as the CUBE. Answers with the same object stats() does, or '
			+ 'null when the region held no standing room, which is an answer and not an error. A second bake '
			+ 'replaces the first, and new three.Scene() drops it — it was voxelized out of triangles that '
			+ 'are gone.',
		'three.nav.stats()':
			'What the last bake produced and what it cost: { cell, radius, height, slope, voxels, solid, '
			+ 'floor, walkable, bakeMs, bounds }, or null if there has not been one. bakeMs and voxels are '
			+ 'the numbers that decide whether baking is a level-boundary operation or a loading screen for '
			+ 'YOUR level rather than for a reference one.',
		'three.nav.path(from, to, options)':
			'One agent, one route: an Array of Vector3 waypoints on the walking surface, starting at the '
			+ 'point given, or empty when there is no route. The straight lines between them have been '
			+ 'checked with a capsule sweep at the agent\'s own size, so a corner it cannot physically round '
			+ 'has not been cut and the path does not look like it is walking cell centres. This SOLVES A '
			+ 'WHOLE FIELD and throws it away — right for a wanderer replanning every few seconds, and the '
			+ 'thing three.nav.field exists to replace for a crowd. { limit } caps the waypoint count.',
		'three.nav.field(goals)':
			'Solve towards one or more goals and KEEP the answer — the verb a crowd uses. Takes a point or '
			+ 'an array of points; many goals is not several routes, it is one field whose value is the '
			+ 'distance to the nearest of them, which is what a crowd heading for whichever exit is closest '
			+ 'wants. Returns a NavField with direction(point) — a unit XZ vector, or zero for nowhere to go '
			+ '— cost(point), which is Infinity for unreachable, reaches(point), and dispose(). Returns null '
			+ 'when no goal landed on a walkable cell, which is the usual way a goal is wrong: given at the '
			+ 'height of the floor\'s underside, inside a wall, or outside the baked region. Feed the field '
			+ 'to three.steer rather than calling direction() in a loop.',
		'three.steer(positions, velocities, options)':
			'Seek, arrive and separation over a whole crowd in one crossing. positions and velocities are '
			+ 'Float32Arrays of three floats per agent — the first read, the second written. Options are '
			+ '{ field, goal, maxSpeed, arrive, separation, separationWeight }. A field wins over a goal, '
			+ 'because a field already knows the way round a wall and a goal does not. arrive is how far out '
			+ 'an agent starts slowing, and 0 never slows — which is how a crowd ends up orbiting a door. '
			+ 'What comes back is a DESIRED velocity: integrate it yourself, and feed it to three.moveAndSlide '
			+ 'for agents that collide or add it straight on for agents that do not.',
		'three.damp(current, target, lambda, dt)':
			'Move current towards target by a fixed fraction of the remaining distance PER SECOND. lambda is '
			+ 'the rate — 1 is lazy, 5 is a normal follow, 20 is nearly rigid — and dt is in SECONDS, so it '
			+ 'is three.clock.dt / 1000. Three.js spells this MathUtils.damp and means the same thing. '
			+ 'three.dampAngle is the same taking the short way round a circle, which is what a heading needs '
			+ 'and what the plain one gets wrong at exactly the place a mouse look crosses constantly.',
		'three.smoothDamp(current, target, state, smoothTime, dt, maxSpeed)':
			'A critically damped spring — the one to reach for when damp overshoots the feel you wanted. The '
			+ 'difference is MOMENTUM: damp is fastest at the start and asymptotically slow at the end, right '
			+ 'for a camera easing onto a target and wrong for anything that should look accelerated. state '
			+ 'is an object this writes .velocity into and it must OUTLIVE THE FRAME — one created inside the '
			+ 'loop is a spring re-launched from rest sixty times a second, which looks exactly like damp '
			+ 'with a worse constant and is the one way to use this and see nothing. smoothTime is roughly '
			+ 'how long the move takes, in seconds.',
		'new three.CatmullRomCurve3(points, closed, curveType, tension)':
			'The three-dimensional half of the curve pair, and the one a loop samples rather than a bake '
			+ 'consumes: a camera rail, a patrol route, a rope. Three.js\'s class and method names — '
			+ 'getPoint(t), getPointAt(u), getTangent(t), getLength(), getPoints(n), getSpacedPoints(n). '
			+ 'getPoint and getPointAt are NOT the same function and the gap between them is what makes '
			+ 'hand-written rail code look wrong: t is the curve\'s own parameter, spread evenly over the '
			+ 'control segments, so an object moving at a constant t per second speeds up through the widely '
			+ 'spaced ones and crawls through the close ones. u is spread evenly over the LENGTH, and that is '
			+ 'the one anything moving wants. three.catmullRom is the other half: a GROUND path, [x, z] in '
			+ 'and a dense polyline out, for field.carve, field.stroke and RibbonGeometry.',
		'three.character(options)':
			'A walkable character with a follow camera, the controller a third-person scene writes by '
			+ 'hand and the place its worst bugs are already fixed. Takes { mesh, legs, arms, terrain, '
			+ 'height, speed, jump, gravity, snap, bounds, spawn, keys, camera }. mesh is a Group to '
			+ 'drive (or omit for a built-in voxel person); terrain is a TerrainGeometry (its heightAt '
			+ 'is the ground) or height is an (x, z) => y function. spawn is [x, z] or { x, z } — the '
			+ 'ground supplies the y. Returns { g, step, dispose, position, yaw, pitch, dist, heading, '
			+ 'moving, grounded, bounds }. scene.add(p.g) FIRST, then call step() from setAnimationLoop '
			+ '— the follow camera attaches on the first step, which requires the mesh to be in the '
			+ 'scene. step() with no argument reads three.clock.dt, which is what the loop is stepping; '
			+ 'a dt that is not a finite number throws rather than leaving the camera NaN. '
			+ 'It reads WASD/arrows relative to the camera (via camera.planarMove), drag-looks, q/e '
			+ 'turn and r/f pitch, jumps while space is HELD — hold-to-hop, not one jump per press — '
			+ 'rides the height field, and swings the limb pivots as it walks. Every key is rebindable '
			+ 'through keys: { forward, back, left, right, jump, yawLeft, yawRight, pitchUp, pitchDown }, '
			+ 'each a key name or a list of them, merged over the defaults, and an action that is not in '
			+ 'that list is an error rather than a binding nothing reads. bounds is the fence it walks '
			+ 'inside — { x, z, width, depth }, false for none, and by default the terrain\'s own extent, '
			+ 'the same one three.scatter fills. snap is how far the ground may drop under the feet in '
			+ 'one frame and still count as walking down it (0.5); past that it is a ledge and the '
			+ 'character falls rather than being teleported to the bottom. camera takes { offset, '
			+ 'distance, lag, yaw, pitch, sensitivity, pitchRange, distanceRange } — the ranges default '
			+ 'to [-8, 84] and [3, 26] WIDENED to hold whatever distance and pitch you asked for, so a '
			+ 'distance of 40 is 40 and is not silently clamped. Pass { camera: false } to leave the '
			+ 'camera alone entirely: no attach, no orbit, no look of its own, and movement then follows '
			+ 'whatever your camera is doing — yaw/pitch/dist read the camera through and refuse to be '
			+ 'written. yaw/pitch/dist are otherwise the character\'s own look, kept here so the view and '
			+ 'the movement frame never disagree. dispose() gives the camera and three.controls back, '
			+ 'and only detaches if the camera is still following this character.',
		'three.scatter(options)':
			'Where to put a hundred trees: { count, seed, onTerrain, bounds, spacing, minHeight, '
			+ 'maxHeight, maxSlope, avoid, accept }. Returns [{ x, y, z, normal, index }] — placements, '
			+ 'not meshes, because the loop that turns a placement into a mesh is three lines and the '
			+ 'caller almost always wants to vary the colour or the scale per point. onTerrain is a '
			+ 'TerrainGeometry or a Field and supplies the height and the normal; bounds defaults to '
			+ 'that terrain\'s own extent. avoid takes { x, z, radius } circles and { path, width } '
			+ 'corridors, so the same polyline that carved the river keeps the trees out of it. '
			+ 'maxSlope is in degrees off flat. spacing is a minimum separation enforced by rejection, '
			+ 'not a guarantee: the sampler gives up after a bounded number of tries and returns a '
			+ 'shorter list rather than spinning, so read .length. The same seed places the same points, '
			+ 'which is what makes a screenshot comparable to yesterday\'s.',
		'three.stats()':
			'The numbers below, for the whole scene, with culling off. The six ...Ms are the exception: '
			+ 'they are not facts about the scene but measurements of the last frame drawn, so they move '
			+ 'when nothing about the scene has. gpuMs is the frame and the other five are what it was '
			+ 'spent on, which is how you find out that a slow scene is slow in the shadow pass.',
		'three.camera.attach(object, options)':
			'Follow an object with the camera. { offset: [x, y, z] } is added to its world position and '
			+ 'becomes the orbit point every frame; { distance } is how far behind the eye sits, and 0 '
			+ 'puts the eye ON the point, which is first person; { lag } is milliseconds of catch-up, 0 '
			+ 'for rigid, ~120 for a camera that trails. The follow runs LAST in the frame, after the '
			+ 'animation, the solver and your callback, so the camera is never a frame behind what it is '
			+ 'watching. It owns the orbit point and nothing else: a drag still orbits, the wheel still '
			+ 'zooms, orbit() still aims, and a PAN stops working because a pan writes the orbit point. '
			+ 'The offset is world space, so a camera bolted into something that rolls is not expressible. '
			+ 'frameAll() throws while attached rather than being undone a frame later.',
		'three.camera.detach() / three.camera.attached':
			'detach() stops following and answers whether it was, leaving the camera exactly where the '
			+ 'last frame put it. attached is the object being followed, or null — and null is also how '
			+ 'you find out that what you were following was destroyed, because the host drops the '
			+ 'attachment silently rather than throwing from inside a frame nobody called.',
		'three.unloadUnused()':
			'Free every asset no live mesh names, every mesh of a still-used file that nothing draws, and '
			+ 'every texture that goes with them. Answers with { assets, meshes, textures, bytes } — '
			+ 'meshes counts the pieces given back without their file, which is what lets a level swap '
			+ 'which parts of a kit it places without reloading the kit. scene.unload() is this plus '
			+ 'emptying the scene and is what a level transition wants. An asset loaded but never added '
			+ 'has no references either, so it goes too — load the next level after unloading, not before.',
		'three.inventory()':
			'Every .glb and .gltf under the assets directory, described without loading any of it: '
			+ '[{ path, triangles, nodes, skins, meshes: [{ name, triangles }], animations: [name], '
			+ 'bounds: { min, max } }]. Read out of the JSON chunk, so it is cheap on a kit of any size — '
			+ 'ask this before three.load to find out what is worth loading. `path` is what three.load wants. '
			+ 'Empty when three was not started with --assets, since there is then no directory to describe.',
		'scene.export(path)':
			'Write the scene to a .glb, and answer with { path, meshes, entries, materials, images, '
			+ 'nodes, instances, batches, skipped, shaded, layers, bytes }. One mesh per unique (asset, mesh), '
			+ 'so a thousand walls from one kit are one mesh in the file exactly as they are one draw '
			+ 'call in the frame. Sibling copies of one shape are written as a single node carrying an '
			+ 'array of transforms — EXT_mesh_gpu_instancing, which any glTF reader can place — with a '
			+ '_COLOR_0 array beside them holding each copy\'s mesh.color, so a scene of many colours '
			+ 'reloads as the one draw call it drew as. batches counts the nodes written that way. A '
			+ 'copy with no sibling drawing the same shape keeps its name and its own material instead, '
			+ 'which costs no draw call, and groups are never collapsed. Siblings that share a shape '
			+ 'but not a material do not batch either: a colour travels per copy in _COLOR_0, but a '
			+ 'texture, a blend mode and a layer stack have no per-copy channel, so they are two draw '
			+ 'calls in the frame and two nodes in the file, sharing the geometry either way. Copies made with '
			+ 'asset.instantiate() are not siblings — each arrives in a group of its own — so they do '
			+ 'not batch, which only matters if you tinted them: pass { flatten: true } to batch every '
			+ 'copy of a shape in world space instead, giving up the hierarchy and the copies\' names '
			+ 'to do it. Images are written once and '
			+ 'shared across every file they came from. Under --assets the path is inside the game '
			+ 'directory and cannot climb out of it, as three.load\'s is. Helpers and hidden subtrees '
			+ 'are not in the file (skipped counts them) and a ShaderMaterial is not either, because it '
			+ 'is a Slang pipeline and glTF describes surfaces rather than programs — those meshes are '
			+ 'exported with the base colour and texture their geometry carries, and shaded counts them. '
			+ 'A material layer stack is the exception to that last part, whichever way it was built. '
			+ 'A mesh loaded from a .glb carrying CUSTOM_materials_layers is written back with the stack '
			+ 'it came in with, read out of the source document; a three.LayeredMaterial built in a '
			+ 'script is written from the description it was constructed with, with its images read back '
			+ 'off the device. Either way the stack survives even though the material drawing it is a '
			+ 'generated shader, and layers counts the records written. The COLOR_0 a VERTEX_COLOR mask '
			+ 'reads goes into the file beside them. A script stack takes precedence when a mesh has '
			+ 'both, because that is what the frame drew with. Changing a layer\'s map or its animated '
			+ 'tint after construction is picked up: the export reads the material\'s live samplers and '
			+ 'uniforms rather than a copy of what was first passed in. '
			+ 'The scene around the meshes goes too: the camera as a glTF camera and the light as a '
			+ 'KHR_lights_punctual directional light, each on a node of its own, so the file opens '
			+ 'framed and lit the way three had it — both are counted in nodes like any other node. '
			+ 'The light\'s ambient floor has no glTF equivalent and is the one thing lost there. '
			+ 'Materials carry side as doubleSided, repeat and offset as KHR_texture_transform, and a '
			+ 'source material\'s normal, occlusion and emissive maps. Metalness and roughness are not '
			+ 'written, because this renderer has no specular term to have shown them, and lines are '
			+ 'not written yet.',
		'three.renderSize()': '{ width, height } of the offscreen image — what pick() counts in and what the returned PNG is.',
	'three.getApiDocs(options)': 'This, and four ways of asking for it. With no argument you get the INDEX: the summary, every difference from Three.js, the stats block, the key names, the examples, and the NAMES of the classes and functions — about a quarter of the whole and the part that is read every time. { search: "shadow" } is the grep: every entry whose name or prose mentions a word, in full, keyed by the path that asks for it again. { section: "classes.ShaderMaterial" } is one entry or one whole section, and a bare "ShaderMaterial" is found too. { all: true } is everything at once. Over MCP these are get_api_docs\'s arguments, plus a `path` that writes the whole surface to a Markdown file — one heading per entry — which is how you grep it with your own tools instead of asking again.',
	'three.searchDocs(term)': 'Answers the question where does the API mention X, over the WHOLE documentation rather than only the differences: { query, matches, entries }, where entries maps a path like classes.ConvexGeometry or functions.three.load(path) to the text at it. One answer is capped, and anything that did not fit is named in notShown rather than dropped silently. Example: three.searchDocs("keyboard") finds the headless-has-no-keyboard note without dumping the whole documentation object. Same thing as three.getApiDocs({ search: term }).',
	'three.input.isDown(key)':
			'Whether a key is held right now. Poll this in the animation callback for continuous '
			+ 'movement — a held key fires no repeat events.',
		'three.input.pressed(key) / released(key)':
			'Whether the key went down (or up) during the frame being drawn. Meaningful inside the '
			+ 'animation callback; between frames it reports the last frame, which is almost always nothing.',
		'three.input.text':
			'What was typed this frame, as UTF-8, with modifier chords, control characters and the '
			+ 'function-key range filtered out. The layout and the shift key are already applied, so '
			+ 'this is what a text field wants rather than the key map.',
		'three.input.keys()':
			'Every key name there is. The same list the host searches, so it cannot be out of date.',
		'three.onKeyDown(key, fn) / three.onKeyUp(key, fn)':
			'Call fn(keyName) once when the key goes down (or up), from inside the frame. One handler '
			+ 'per key per edge — binding again replaces, null unbinds, and up to 32 exist at a time. '
			+ 'Synchronous only, and stopped for good if it throws, exactly as the animation callback is. '
			+ 'Escape is the host\'s: it closes the window whatever a script binds.',
		'three.input.pointer':
			'{ x, y, dx, dy, inside, down, right, middle, clicked, scroll, scrollX } — the whole mouse '
			+ 'for this frame, as one reading. x and y are in the rendered image\'s pixels counted from '
			+ 'its top-left corner, which is what scene.pick(x, y) takes. dx and dy are how far the '
			+ 'cursor moved since the previous frame, in those same pixels — what a mouse look is built '
			+ 'out of, and NOT the same thing as differencing x yourself, which answers with the frame '
			+ 'before the one being drawn; the browser calls them movementX/movementY. They keep '
			+ 'reporting while the cursor is outside the window and stop at the edge of the screen, '
			+ 'because there is no pointer lock. scroll is the wheel over this frame, positive AWAY from '
			+ 'the user (the opposite of the browser\'s deltaY) in notches or fractions of one from a '
			+ 'trackpad, with scrollX the horizontal half; both are zero on the frames nobody turned it. '
			+ 'down, right and middle are the three buttons as latches rather than edges — clicked is '
			+ 'the one edge. `inside` is false when the cursor has left the window, and everything is '
			+ 'zero when there is no window at all. Read it in the animation callback.',
		'three.controls.enabled':
			'Whether the mouse still reaches the camera. True by default; false stops the drag, the '
			+ 'right-drag pan and the wheel zoom, and stops the coast a flick leaves behind. What it is '
			+ 'for is a scene that drives the camera itself — a follow camera, a first-person look — '
			+ 'which writes yaw, pitch and target every frame and would otherwise have the turntable '
			+ 'writing them again from whatever the hand did. three.camera.orbit() and three.camera.'
			+ 'frameAll() are unaffected, because a script writing the camera on purpose is the thing '
			+ 'being enabled rather than the thing being stopped. A drag in progress is dropped rather '
			+ 'than finished, and turning it back on waits for a fresh press instead of resuming the '
			+ 'old one. It reads back what was written to it with no window open, where it does nothing, '
			+ 'and it survives new three.Scene() — following the camera rather than the background, '
			+ 'because a game that took the mouse for its own camera should not lose it at every level.',
		'three.onClick(fn)':
			'Call fn(hit, x, y) once when the window is clicked, from inside the frame. `hit` is what '
			+ 'is under the cursor — the same intersection scene.pick(x, y) answers with, or null for '
			+ 'a miss — so click-to-select is one call. A click is a press and a release in the same '
			+ 'place: dragging orbits the camera and does not fire this. One handler; binding again '
			+ 'replaces, null unbinds. Synchronous only, and stopped for good if it throws.',
		'three.physics.add(object, options)':
		'Give an object a body and answer with the object. The description is object.body if it has one and `options` wins over it, so a scene can be described once and tweaked at the call: { shape: \'box\' | \'sphere\' | \'capsule\' | \'hull\' | \'heightfield\', mass: 1, friction: 0.5, restitution: 0.2, kinematic: false, trigger: false }. mass 0 means static. The object has to be in the scene already — a body is placed at a world position — and has to be a child of the scene rather than of another object, because the solver works in world space and a parent transform would fight it. A group draws nothing and so has no size to take a collider from; give the body to a mesh.',
	'three.physics.remove(object)':
		'Take the body away, and answer whether there was one. A body removed while it is inside a trigger still emits its exit event, so a script that destroys something in a trigger volume still hears it leave.',
	'three.physics.gravity':
		'[x, y, z], y-up, read and written as an array. Set once at boot; it is a world setting and not a transform, which is why it is not a live Vector3.',
	'three.physics.count':
		'How many bodies the world holds.',
	'three.budget':
		'How long this script may run before the interrupt stops it, in milliseconds. 5,000 by default. '
		+ 'Raise it to SIMULATE, not to build: five seconds is generous for assembling a scene and short '
		+ 'for stepping one — a check that walks a character 30,000 frames against its colliders needs '
		+ 'minutes, and being forced under five seconds means cutting it into pieces that fit the budget '
		+ 'rather than pieces that mean something. Raising it applies to the run that raises it, because '
		+ 'a script does not know it needs longer until it is already running. Ten minutes is the ceiling '
		+ 'and asking for more clamps rather than throws; zero or negative throws, because there is no way '
		+ 'to turn the interrupt off. It does not reach the animation callback, which keeps its own 100 ms '
		+ 'so that one slow frame is a stutter rather than a hang.',
	'three.budget (a COLD scene build over 5s — the exact trap)':
		'A run_script that REBUILDS a scene from scratch often times out at 5,000 ms, and the error is '
		+ 'simply "the script ran for longer than 5000 ms and was stopped" — which reads like a bug when '
		+ 'it is just the budget. On a fresh --mcp backend, the first build pays for shader compiles and '
		+ 'texture uploads that a warm (--script-preloaded) backend already did, so it crosses 5s even when '
		+ 'the SAME script returns in time on a second call. The fix is one line at the TOP of the script, '
		+ 'before any build: "three.budget = 60000;". Better still, preload the scene so the build runs '
		+ 'outside the budget: launch the backend with "--script scenes/mine.js" and let run_script move '
		+ 'the character rather than rebuild. Reading three.budget back answers the current limit.',
	'material.repeat / material.offset':
		'How the map is laid across a surface. repeat is [u, v] — or one number for both — and is how '
		+ 'many times the image is tiled; offset is [u, v] in whole repeats, for shifting it. Without '
		+ 'this a surface maps its texture exactly ONCE, so texel density is a function of how big the '
		+ 'mesh is and a 128px image across 100 units is a smear — the way round it used to be cutting '
		+ 'the surface into hundreds of small meshes. On the MATERIAL, not on the texture as in '
		+ 'Three.js: textures here are deduplicated by content across every file, so a transform on '
		+ 'the texture would change every unrelated surface that used the same picture. Two densities '
		+ 'of one image is two materials, which is what they already had to be. A repeat of zero '
		+ 'throws — it maps the whole surface onto one texel.',
	'texture.read(into)':
		'The pixels, copied back off the device: a Uint8Array of width * height * 4 RGBA bytes. '
		+ 'The bytes that went IN, not the ones the shader sees — the copy converts nothing, so a '
		+ 'DataTexture reads back byte-for-byte identical to the array it was built from and a PNG '
		+ 'reads back as its own pixels; the sRGB decode happens at sample time and is not in here. '
		+ '`into` is optional and lets you reuse a buffer: this copies off the device and waits for '
		+ 'the queue, so it belongs at load or in a test rather than in a frame. It is also what '
		+ 'makes a texture testable and what lets scene.export write a generated one.',
	'three.physics.velocity(object)':
		'[lx, ly, lz, ax, ay, az] — linear in world units per second, angular in radians per second — or '
		+ 'null when the object has no body. Both at once because a script that wants one usually wants '
		+ 'the other; null rather than a throw because this gets asked in a loop over things that may or '
		+ 'may not have bodies.',
	'three.physics.setVelocity(object, [x, y, z])':
		'Assign a body\'s speed, in world units per second. This is what a character uses: set it every '
		+ 'frame from the keys that are down, because what you want is a speed. Only a dynamic body can '
		+ 'be given one — a static body\'s inverse mass is zero so nothing would happen, and a kinematic '
		+ 'body is driven by the transform your script writes so it would be discarded a fraction of a '
		+ 'step later. Both throw and say which. The solver recomputes the velocity from what actually '
		+ 'happened at the end of every step, so this survives one integration by design.',
	'three.physics.setAngularVelocity(object, [x, y, z])':
		'Radians per second about each world axis; the vector\'s length is the rate. Same dynamic-only '
		+ 'rule as setVelocity.',
	'three.physics.applyImpulse(object, [x, y, z], at)':
		'A push, in mass times velocity — so the same impulse moves a heavy thing less, and this is what '
		+ 'a jump, a bat or an explosion wants rather than setVelocity. It ADDS to whatever the body was '
		+ 'already doing. `at` is optional and is an offset from the body\'s centre in world axes, not a '
		+ 'world position: give one and the push tumbles the body as well as shoving it. A sleeping body '
		+ 'is woken first, so a settled crate and a rolling one answer the same push the same way.',
	'three.physics.applyTorqueImpulse(object, [x, y, z])':
		'A spin with no shove, so "make this rotate" does not mean solving for an offset and a force '
		+ 'that happen to produce the spin you wanted.',
	'object.body':
		'What kind of body three.physics.add would give this object, and what it gave it: { shape, mass, friction, restitution, kind }. Set it yourself to describe one, or read it back after add to see the defaults filled in. null once the body is removed.',
	'three.onTrigger(fn)':
		'Call fn({ type: \'enter\' | \'exit\', trigger, other }) when a trigger body starts or stops overlapping something, from inside the frame. `trigger` and `other` are the objects, or null for one whose node has already gone. One handler; binding again replaces, null unbinds. Synchronous only, and stopped for good if it throws — the same rules onClick follows.',
	'three.onContact(fn)':
		'Call fn({ type: \'start\' | \'end\', a, b, normal, point }) when two bodies touch or come apart. Unlike a trigger, a contact also produced a physical response. `normal` and `point` describe the touch and mean something only on a start — by the end there is no contact left to describe. Same registration and same rules as onTrigger.',
	'three.setAnimationLoop(fn)':
			'Run fn(elapsedMs) once per frame, or null to stop. Synchronous only. The next '
			+ 'run_script reports how many frames it ran, whether it is still running, and why it '
			+ 'stopped if it did. Only one callback exists: registering a second replaces the first. '
			+ 'It survives new three.Scene(), so a callback holding meshes from the old scene will '
			+ 'throw on the next frame and be stopped — re-register it after rebuilding. The '
			+ 'milliseconds are the GAME clock (three.clock.time * 1000), so they stop when '
			+ 'three.clock.timeScale is 0 and start at 0 on the first frame rather than carrying '
			+ 'the boot.',
		'three.setFixedLoop(fn)':
			'Run fn(dt) at a fixed rate — zero or more times per frame, as many as the clock owes at '
			+ 'three.clock.fixedRate (60 Hz by default), capped at eight. dt is the SAME number every '
			+ 'call, in seconds, which is what makes gameplay written against it produce the same '
			+ 'result on a slow machine as on a fast one. This is where movement, timers and rules '
			+ 'belong; setAnimationLoop is where drawing the consequence belongs. The accumulator is '
			+ 'the host\'s, not yours: one written in the animation callback spends the script budget '
			+ 'catching up and gets the callback stopped instead of stuttering. Runs after the '
			+ 'frame\'s physics and before the animation callback. Same rules as setAnimationLoop — '
			+ 'synchronous, one of them, null stops it.',
		'three.clock.time / three.clock.dt':
			'The game clock, in SECONDS. time is what the frames have added up to and dt is what the '
			+ 'frame being drawn is worth — 0 before the first frame and 0 while paused, so '
			+ 'x += speed * three.clock.dt needs no check for a pause. dt is clamped: a frame that '
			+ 'took longer than 100 ms of wall time reports 100 ms, so a breakpoint or a long tool '
			+ 'call stutters rather than teleporting the world a second forward. Both are read-only.',
		'three.clock.timeScale / three.clock.paused':
			'Wall time to game time: 1 is real time, 0.25 is slow motion, 3 is fast forward and 0 is '
			+ 'PAUSED. It reaches everything — the clips, the physics, the fixed loop, the follow '
			+ 'camera, the argument setAnimationLoop is handed and p.time in a post body — because '
			+ 'all of them are handed one delta rather than reading a clock of their own. Negative '
			+ 'throws: nothing downstream of it can run backwards. paused is a read-only '
			+ 'timeScale === 0; pause by writing 0 and resume by writing the scale you want back.',
		'three.clock.advance(seconds)':
			'Move the clock by hand, whatever the scale is — which is how a pause is single-stepped: '
			+ 'three.clock.timeScale = 0 and then advance(1 / 60) is exactly one frame of world, '
			+ 'clips and bodies and fixed steps and p.time together. It lands on the NEXT frame '
			+ 'rather than immediately, so under --mcp the order is run_script, a frame, screenshot. '
			+ 'Two runs that ask for the same amount draw the same picture, which is what makes a '
			+ 'screenshot with a post pass reproducible. '
			+ 'CALLS ACCUMULATE INTO ONE FRAME rather than queueing frames, and that is the one way '
			+ 'this verb can lie to you: ten advance(1 / 60) before the next frame boundary is a '
			+ 'single frame worth a sixth of a second, and a frame that long is exactly the one the '
			+ 'physics-fixed-60hz note warns about — the solver catches up at most five steps and '
			+ 'DROPS the rest, and the fixed loop does the same at eight. Measured: ten in one call '
			+ 'moved the clock the full 0.167 s and dropped a falling body 1.41 units where ten '
			+ 'stepped frames drop it about 2.8. The time lands and the world does not. To step n '
			+ 'frames, call it once per frame boundary — under --mcp that is n round trips, and '
			+ 'there is no way to spend them in one.',
		'three.clock.fixedRate / three.clock.fixedDelta':
			'How many fixed steps a second of game time is worth — 60 by default, 1 to 240 — and '
			+ 'the step that follows from it, in seconds. It does NOT change the solver\'s rate, '
			+ 'which is 60 Hz and is the solver\'s business: a script asking for 30 Hz gameplay must '
			+ 'not quietly halve the accuracy of every contact in the scene.',
		'toJSON() / toString()':
			'What JSON.stringify sees, and therefore what comes back in the `value` field when you '
			+ 'return an object from a script. Objects report their name, transform and children; a '
			+ 'Vector3 reports [x, y, z]; a ShaderMaterial reports its fragment and uniforms.',
		'three.texture(path, options)':
			'Decode a PNG or JPEG and upload it, answering with a Texture. Synchronous. The format '
			+ 'comes from the file\'s first bytes rather than its name. Deduplicated by the decoded '
			+ 'image, so the same picture reached by two paths — or by a path and a .glb — is one '
			+ 'upload, and three.stats().textures counts it once. options is '
			+ '{ colorSpace, generateMipmaps } and nothing else; an unknown key throws rather than '
			+ 'being ignored, so a Three.js line carrying magFilter or wrapS is told so instead of '
			+ 'quietly doing something different.',
		'three.SRGBColorSpace / three.LinearSRGBColorSpace / three.NoColorSpace':
			'Which space a texture\'s bytes are in, passed as three.texture(path, { colorSpace }). '
			+ 'THIS IS THE DIFFERENCE BETWEEN A COLOUR MAP AND A NORMAL MAP. SRGBColorSpace is the '
			+ 'default and is right for anything an artist looked at while making it — a base '
			+ 'colour, an albedo, a photograph. LinearSRGBColorSpace is for a map whose channels '
			+ 'are numbers rather than colours: a normal map\'s xyz, a roughness or metalness or '
			+ 'occlusion map, a height field, a lookup table. NoColorSpace is Three.js\'s other '
			+ 'spelling of linear and is the same image here. Neither mistake reports an error: a '
			+ 'colour map loaded linear is washed out and reads as a lighting bug, and a normal map '
			+ 'loaded sRGB goes soft and reads as a bad bake. The colourspace is part of a '
			+ 'texture\'s identity, so the same file loaded both ways is two uploads on purpose.',
		'new three.DataTexture(data, width, height, options)':
			'Upload pixels a script generated. Rows run bottom-to-top, four bytes per pixel. '
			+ 'The bytes are read and copied inside the call, so the array is yours again '
			+ 'immediately. Wrong byte counts are refused with the arithmetic in the message '
			+ 'rather than uploaded skewed. options is three.texture\'s; a generated lookup table '
			+ 'wants { colorSpace: three.LinearSRGBColorSpace, generateMipmaps: false }.',
		'mapped_normal(s, texel) — normal maps in a ShaderMaterial':
			'A tangent-space normal map applied to a surface that carries no tangents. In a '
			+ 'fragment body: `float3 n = mapped_normal(s, bumps.Sample(s.uv).rgb); return '
			+ 's.albedo * lambert(n);` where bumps is one of the material\'s declared textures. '
			+ 'texel is the map\'s rgb exactly as sampled — the decode from [0,1] to a direction '
			+ 'happens inside, which is why the map has to be loaded with '
			+ '{ colorSpace: three.LinearSRGBColorSpace }. No mesh here has a TANGENT stream and '
			+ 'there is nowhere to put one, so the frame is rebuilt per pixel from screen-space '
			+ 'derivatives of the world position and the uv. That is what makes it work on any '
			+ 'textured mesh, including a generated PlaneGeometry, and it is also its two limits: '
			+ 'a mirrored uv island comes out mirrored rather than flipped, and a face with '
			+ 'degenerate uvs gets the interpolated normal back unchanged. Fragment stage only — '
			+ 'calling it from a vertex body is a compile error, because there are no derivatives '
			+ 'there. A ROUGHNESS map has no equivalent yet: the built-in light is lambert with no '
			+ 'specular term, so a roughness or metalness map loads correctly and in the right '
			+ 'colourspace but there is nothing built in to feed it — a body is free to use one '
			+ 'for whatever it likes.',
		'texture.levels and texture.generateMipmaps':
			'How many mip levels the image got, and whether that is more than one. A full chain is '
			+ 'built by default, which is what stops a textured floor shimmering as the camera '
			+ 'moves — without one every sample comes from the full-resolution image however few '
			+ 'pixels the surface covers. Both are read back off the upload rather than echoed from '
			+ 'what you asked for, so a device that cannot filter the format reports false here '
			+ 'having been passed true. Pass { generateMipmaps: false } for pixels meant to be '
			+ 'indexed exactly rather than sampled at a distance.',
		'texture.dispose()':
			'Give back the reference this handle holds. Not a free: the image goes only when nothing '
			+ 'names it, so disposing while a material still draws with it leaves that material '
			+ 'correct. Disposing twice does nothing. Using a disposed texture throws.',
		'new three.MeshLambertMaterial({ map, side })':
			'The built-in shader with an image. Compiles nothing, needs no Slang, and cannot fail '
			+ 'with a shader diagnostic — this is the way to put a picture on a shape. With no map it '
			+ 'is a side and nothing else, which is the cheapest skydome.',
		'material.map':
			'The base colour image, or null. The material\'s map wins over whatever texture the mesh '
			+ 'itself carries, so a glTF\'s own image can be overridden and cannot silently override '
			+ 'yours. A mesh with no uvs shows nothing: every parametric shape and every glTF mesh '
			+ 'has them, a ConvexGeometry does not — on one of those the map is set, correct, and '
			+ 'invisible.',
		'new three.ShaderMaterial({ fragment, uniforms })':
			'Compile a fragment function into a material. Uniforms are at most 68 bytes in total '
			+ '(17 floats); each is a number or an array of up to four numbers.',
		'mesh.material':
			'Assign a MeshLambertMaterial or a ShaderMaterial, or null for the default shader. Meshes '
			+ 'sharing a mesh ref AND a material are one draw call; giving two of them different '
			+ 'materials makes two.',
		'material.dispose()':
			'Give back the reference this handle holds, and with it the pipeline the material was '
			+ 'compiled into. Not a free: the material goes when no mesh names it either, so disposing '
			+ 'while a mesh still draws with it leaves that mesh correct and collects the material when '
			+ 'the mesh goes. Call it on a ShaderMaterial you are done with — an agent iterating on a '
			+ 'shader compiles a new pipeline every run, and without this they accumulate for the life '
			+ 'of the process. Disposing twice does nothing; using a disposed material throws. The '
			+ 'default and line materials are shared and cannot be disposed.',
		'material.uniforms.<name>':
			'Read or write a uniform. Writing takes effect on the next render. Only names declared at '
			+ 'construction exist; assigning to any other name throws. A uniform declared as a table is '
			+ 'written a row at a time — material.uniforms.palette[1] = [0, 1, 0] — or all at once.',
		'three.setPost({ fragment, uniforms, textures })':
			'Run one shader over the whole finished frame. fragment is a Slang function '
			+ '`float3 post(Post p)` returning linear rgb; Post has color (this pixel of what ran before '
			+ 'this pass, already decoded to linear — the rendered scene, for the first pass of a chain), '
			+ 'scene (this pixel of the rendered scene whatever has run since; equal to color on the '
			+ 'first pass), uv (0..1 across the frame, (0,0) top left), resolution '
			+ '(the frame in pixels — 1.0 / p.resolution is one texel, which is what a blur steps by), '
			+ 'time (seconds since this shader was set, on the GAME clock, so a paused world has a still '
			+ 'chain) and depth (how far this pixel is from the camera, in WORLD UNITS along the view '
			+ 'direction — p.depth > 20 is twenty units away, and a pixel nothing was drawn into reads as '
			+ 'the far plane). depth is already linearized for you, which is the point of it: the raw '
			+ 'device depth spends half its range on the first few percent of the frustum, so fog, depth '
			+ 'of field and distance-aware edges written against it bunch up against the camera. There '
			+ 'are no normals and no motion vectors. There is also tap, another pass\'s output, which '
			+ 'only three.addPass can fill — see its `reads`. p gives you '
			+ 'this pixel; the two images behind color and scene are also in scope as samplers named prev '
			+ 'and scene, so a body that needs the NEIGHBOURS reads prev.Sample(p.uv + off) — which is '
			+ 'what the texel step is for, and the whole of how a blur is written. Each '
			+ 'uniform is readable in the body by its own name; they are at most 104 bytes in total (26 '
			+ 'floats), each a number or an array of up to four numbers, and NOT a table — a post pass '
			+ 'draws one triangle over the whole frame, so there are no instances for a row to belong to. '
			+ 'textures is a ShaderMaterial\'s: { grade_lut: tex } declares a Sampler2D the body reads by '
			+ 'that name, up to four, with no binding number written anywhere. They are what a frame '
			+ 'cannot supply about itself — a ramp to grade through with grade_lut.Sample(float2(p.color.r, '
			+ '0.5)), a noise field to distort or dither by, a mask that says where the effect applies. '
			+ 'Tile one by the frame rather than by uv, p.uv * p.resolution / 256, or it stretches with '
			+ 'the window. A sampler you leave null reads white. '
			+ 'Compiles on the call, so a bad body throws here carrying the Slang diagnostic with '
			+ 'post:<line> counting the lines you wrote; a failed set leaves the previous chain running, '
			+ 'so it is the old shaders or the new one and never neither. Needs a GPU device. '
			+ 'It applies identically to the window, to three.render() and to every screenshot — there is '
			+ 'one recording path and the branch is inside it — so what you see is what a PNG comes back '
			+ 'as. post() returns rgb and never alpha, for shade()\'s reason and one more: a screenshot '
			+ 'forces alpha opaque anyway, so a body that could dim it would make the window and the file '
			+ 'disagree. setPost REPLACES the whole chain (the old pipelines are retired for you) and '
			+ 'three.addPass adds to it. The chain belongs to the renderer rather than to the scene, so '
			+ 'it survives new three.Scene() and outlives the script that set it. three.setPost(null) is '
			+ 'the only thing that clears it.',
		'three.addPass({ fragment, uniforms, textures, reads })':
			'Put another full-screen pass at the end of the chain. The same spec three.setPost takes and '
			+ 'the same handle back, and the difference is what the body reads: p.color is what the pass '
			+ 'BEFORE this one wrote, and p.scene is the frame as the geometry left it, whatever has run '
			+ 'since. Those two are the dependency model — a pass reads its predecessor and it '
			+ 'reads the original picture — and between them they cover most of what a multi-pass effect '
			+ 'wants: bloom is blur(bright(scene)) + scene, which is p.scene three passes later. '
			+ 'reads is the THIRD source, for what they do not cover: hand it the handle an earlier '
			+ 'addPass gave you and that pass\'s output arrives as p.tap. That is the pass in the MIDDLE of a chain that '
			+ 'two later passes both want, or a mask one pass built for another to apply — '
			+ 'const bright = three.addPass({ fragment: threshold }); ... three.addPass({ fragment: '
			+ 'combine, reads: bright }). The sampler is in scope as tap_image (not tap, which is a word '
			+ 'bodies use) for reading a different pixel of it. It costs the tapped pass an image of its own (the chain '
			+ 'ping-pongs two between passes and a tapped one cannot be overwritten), so it is one '
			+ 'allocation per distinct pass tapped and nothing for a chain that taps none. reads must '
			+ 'name a pass ALREADY in the chain — a later index or a cycle throws — and it belongs on '
			+ 'addPass, never on setPost, which is always the first pass and has nothing before it. '
			+ 'Leave it out and p.tap is the rendered scene, the same as p.scene. For the first '
			+ 'pass in a chain the two are the same image, so a body written for setPost keeps working '
			+ 'unchanged. Everything between passes is linear float rather than 8-bit, so a pass may '
			+ 'return values above 1 and the next one still sees them; the display encode happens once, '
			+ 'after the last pass, and is not yours to write. Adding to an empty chain is exactly a '
			+ 'setPost. It does NOT invalidate handles you already hold — earlier passes keep their '
			+ 'index and their shader — which is what lets a script animate every pass at once. There is '
			+ 'no removePass: dropping one out of the middle would renumber the handles after it, and a '
			+ 'setPost followed by the addPass calls you want is the same effect said in a way that '
			+ 'cannot leave a handle pointing at somebody else\'s shader.',
		'the handle three.setPost() and three.addPass() answer with':
			'{ fragment, index, uniforms, textures } — the body that is running, where in the chain it '
			+ 'runs, and live uniforms and textures objects exactly like a material\'s: '
			+ 'post.uniforms.gain = 2 is a 4-byte write that takes effect on the next frame with no '
			+ 'compile and no pipeline, which is what makes an animated post pass free, and '
			+ 'post.textures.grade_lut = other swaps an image the same way. Only names given at the call '
			+ 'exist; assigning any other throws. A later setPost replaces the whole chain, and writing '
			+ 'through a handle from before it throws rather than steering whatever is at that index '
			+ 'now. addPass leaves earlier handles working.',
		'mesh.color':
			'This copy\'s own tint, multiplied into albedo. [r, g, b], [r, g, b, a], {r, g, b} or a hex '
			+ 'number like 0xff8800. Costs no draw call: copies of one mesh may all differ. Works with no '
			+ 'material at all, and reaches a shade() body as s.color with albedo already tinted. '
			+ 'The fourth channel fades this copy when — and only when — its material was built '
			+ 'transparent: it multiplies the material\'s own opacity, so one of a thousand copies '
			+ 'sharing a draw call can be half there while the rest are solid. On an opaque material '
			+ 'the alpha is discarded by the pipeline and changes nothing.',
		'mesh.variant':
			'Which row of the material\'s uniform table this copy draws with, as s.variant in the body. '
			+ 'Costs no draw call either. Zero and meaningless until the material declares a table; past '
			+ 'the end it is clamped to the last row rather than reading rubbish.',
		'scene.pick(x, y)':
			'What is under a pixel of the rendered image, counted from its top-left corner. ' +
			'Answers with an intersection (below) or null. Needs a GPU device.',
		'scene.raycast(origin, direction)':
			'What a world-space ray hits. Either vector may be a Vector3, an {x, y, z} or an [x, y, z], ' +
			'and the direction need not be normalised. Answers with an intersection (below) or null.',
		'three.camera.orbit(yaw, pitch, distance)': 'Degrees, degrees, world units. Any argument may be omitted to leave it alone.',
		'three.camera.lookAt(x, y, z)': 'Point the turntable at a world position.',
		'three.camera.frameAll()': 'Aim at everything in the scene and back off far enough to see it.',
		'three.camera.position()':
			'The camera eye, in world space — the point a boom of `distance` puts it. Not `target` (what it '
			+ 'orbits) and not writable. This is the fix for "which way is the camera looking": you cannot '
			+ 'read it from the camera itself otherwise, because camera.position and getWorldPosition() do '
			+ 'not exist, so a controller had to hand-roll the orbit trig. The convention: yaw is degrees '
			+ 'about +Y from +Z, so orbit(0,0) puts the camera at +Z looking toward -Z and orbit(90,0) at +X '
			+ 'looking toward -X.',
		'three.camera.forward()':
			'Where the camera looks, as a unit Vector3 in world space, pitch included. Compute the '
			+ 'camera-relative move frame as forward() and right() rather than by hand — the signs are '
			+ 'easy to get wrong and read back as the character walking sideways.',
		'three.camera.right()':
			'The camera\'s right on the ground plane, unit Vector3, y=0 — the "D" key. Flattened so it '
			+ 'stays a strafe direction while the camera is pitched down at a character.',
		'three.camera.planarMove(fwd, strafe)':
			'The world-space direction for a camera-relative input: fwd is the W/S axis (+1 to -1), '
			+ 'strafe the D/A axis (+1 to -1). Returns a unit Vector3 (y=0), or the zero vector for 0,0. '
			+ 'One call that keeps a character glued to the camera\'s forward line instead of drifting '
			+ 'sideways — `player.position.x += v.x * speed * dt; player.position.z += v.z * speed * dt`.',
		'three.camera.near / three.camera.far':
			'Where the depth range starts and ends, in world units. Read-only: both are derived, from '
			+ 'the orbit distance and from the scene\'s own bounds, every time the camera moves. They '
			+ 'are worth reading when something has stopped being drawn — geometry beyond far is not '
			+ 'dim, it is absent, and it is culled as well as clipped, so stats().culledLastFrame moves too.',
		'three.light.direction / three.light.ambient':
			'The one directional light. direction is a world-space surface-to-light vector — the way a '
			+ 'face has to point to be fully lit — and is a live Vector3, so three.light.direction.y = -1 '
			+ 'writes through. It is not normalized, so it reads back as you wrote it, and a zero one '
			+ 'throws rather than making every shaded pixel a NaN. ambient is the floor a face turned '
			+ 'right away from the light gets, 0 to 1: at 0 it is black, at 1 there is no shading at all '
			+ 'and everything is its own flat colour. Defaults to [0.35, 0.8, 0.45] and 0.25.',
		'three.light.set(direction, ambient)':
			'Both at once. ambient may be omitted to leave it alone. There is no second light and no '
			+ 'colour per light, which is why this is not scene.add(new DirectionalLight(...)) — '
			+ 'a name Three.js has would be read as a promise of the two things it cannot do.',
		'three.light.shadow':
			'The shadow this light casts, off until you ask. three.light.shadow = true turns it on; '
			+ 'three.light.shadow = { enabled: true, size: 4096 } sets several at once; and the five '
			+ 'properties — enabled, size, bias, intensity, distance — read and write one at a time. size is '
			+ 'texels per side, clamped to 256..8192 and rounded DOWN to a power of two, so it reads '
			+ 'back as what will be allocated rather than as what you typed. bias is an extra depth '
			+ 'offset in the light\'s clip space and defaults to 0, because each sample is already '
			+ 'lifted two texels along its own normal, which is what actually removes self-shadowing '
			+ 'stripes; reach for it in small numbers like 0.0005 if a scene still shows them. '
			+ 'intensity is how dark, 0 to 1, and 1 takes the whole directional term away and leaves '
			+ 'three.light.ambient — so a shadow is never black unless the ambient floor is. '
			+ 'distance is how far down the view direction the map is fitted, in world units, and 0 '
			+ '(the default) now means five times the camera\'s own orbit distance, derived every '
			+ 'frame. It used to mean the camera\'s far plane, which is 1000 units by default and is '
			+ 'not a number about your scene at all. It is the sharpness knob, and it beats size: the '
			+ 'map covers a square this wide, so halving distance is worth quadrupling size and costs '
			+ 'nothing. Setting it still beats the derived number — try roughly the distance shadows '
			+ 'are worth having, and watch for the line across the ground where they stop. '
			+ 'three.light.shadow.fit reads back where the map actually landed: '
			+ '{ live, center, extent, near, far, texel }, in world units, for the last frame. Read '
			+ 'extent first — extent / size is the world size of a texel, and that is what decides '
			+ 'whether an edge reads as a shadow or as a staircase; live false means no pass ran, '
			+ 'which is a frame with no shadows in it that needs no further explanation. '
			+ 'Nothing is allocated and no shader compiled until the first frame with it on, turning '
			+ 'it off costs nothing and keeps the map for next time, and new three.Scene() turns it '
			+ 'off. Everything opaque casts and everything shaded receives: there is no castShadow or '
			+ 'receiveShadow, because two copies of one mesh disagreeing about it would be two draw '
			+ 'calls. Glass casts nothing and neither do debug helpers. There is ONE map, fitted '
			+ 'around the whole scene every frame, so blocky shadows mean a large scene rather than a '
			+ 'small map — and while the pass is on the camera frustum stops culling, because a '
			+ 'caster you cannot see still throws a shadow into the frame, so stats().culledLastFrame '
			+ 'reads 0 and stats().shadowDraws is what the pass cost. The way to make that pass cheap '
			+ 'is object.static = true on whatever will not move again: static casters go into the map '
			+ 'once and are kept, and each frame after draws only the movers. It costs no draw call in '
			+ 'the colour pass. Ask three.docs({ topic: \'static-casters\' }) for the rest.',
		'three.debug':
			'What the renderer draws instead of the scene, when you ask. three.debug.view is one of '
			+ '\'off\' (the default), \'shadow\' or \'shadowMap\'. It exists because a frame with no '
			+ 'visible shadows in it has three explanations — the pass did not run, the pass ran and '
			+ 'the map is fitted somewhere else, or everything in shot is genuinely inside one big '
			+ 'shadow — and until this existed the renderer distinguished none of them. \'shadow\' '
			+ 'draws how much light reaches each surface as greyscale: white is lit, black is fully '
			+ 'shadowed. Uniformly white is a pass that did not run or a fit nothing landed in; '
			+ 'uniformly dark is the answer that takes longest to reach by looking, and it usually '
			+ 'means the sun is low enough that a wall is shadowing the whole scene. \'shadowMap\' '
			+ 'draws the depth the lookup reads at each surface, near-to-far greyscale — the map '
			+ 'itself, seen through the geometry that samples it. Magenta is outside the fitted box, '
			+ 'so a mostly-magenta frame is a three.light.shadow.distance fitted somewhere other than '
			+ 'where you are looking; dark purple is no shadow pass this frame. The sky is not a '
			+ 'surface and has no shadow, so a debug view colours only what the geometry covers. It '
			+ 'is deliberately NOT scene state: new three.Scene() does not clear it, for the same '
			+ 'reason it does not move the camera. Pair it with three.light.shadow.fit for the '
			+ 'numbers, and with --frames if you are running headless.',
		'three.NoBlending / three.NormalBlending / three.AdditiveBlending':
			'The values material.blending takes — 0, 1 and 2, Three.js\'s numbers again. '
			+ 'NormalBlending is what { transparent: true } means and is what glass, water and a '
			+ 'foliage card want; AdditiveBlending never darkens what is behind it and is what fire, '
			+ 'a glow and a beam want. Both are decided when the material is constructed and neither '
			+ 'can be assigned afterwards: this device bakes blending into the pipeline, so changing '
			+ 'it is building another material, which is one line. Three things follow and are worth '
			+ 'knowing before a scene is built on them. Transparent draws are sorted farthest-first '
			+ 'against the near plane and drawn after every opaque one, so glass shows the wall '
			+ 'behind it. Copies inside ONE instanced bucket are not sorted against each other — '
			+ 'they are one draw call, and the depth order within it is whatever the vertex order '
			+ 'is; Three.js\'s per-object sort has the same limit, and the fix in both is to space '
			+ 'the panes out or split them. And a transparent frame may issue more draw calls than '
			+ 'stats().drawCalls reports, deliberately: depth interleaving splits buckets and the '
			+ 'split depends on where the camera is, so stats() answers what the scene costs rather '
			+ 'than what this angle cost. The number is a floor, never an over-estimate.',
		'three.FrontSide / three.BackSide / three.DoubleSide':
			'The values material.side takes — 0, 1 and 2, the same numbers Three.js gives them. '
			+ 'BackSide keeps the back faces, which is what makes a sphere visible from inside: it is '
			+ 'how a skydome is built, and scaling one by -1 instead does nothing, because a negative '
			+ 'scale does not reverse a triangle\'s winding. DoubleSide keeps both and is what a plane '
			+ 'seen from either direction wants — a flag, a leaf card, a piece of a wall you can walk past.',
	},
	// The whole key table, from the host, so the names an agent reads and the
	// names the host searches are one list. Aliases included: ctrl, cmd, esc.
	// No numpad and no mouse buttons — mesh.pick and the mouse are the
	// camera's, and a latched mouse button is a trap the window has already
	// been caught by once.
	keys: H.keyNames(),
	stats: {
		drawCalls: 'vkCmdDrawIndexed calls for one frame of this scene.',
		uniqueMeshes: 'Distinct (asset, mesh) pairs drawn.',
		instances: 'Total placed meshes. The M2 claim is that 1000 of these can be 1 drawCall.',
		nodes: 'Live nodes, groups and the root included.',
		assets: 'Loaded files and generated shapes resident on the device. This is the number a level transition has to bring back down; watch it across scene.unload().',
		triangles: 'Summed over instances, so 1000 copies of a 500-triangle mesh is 500000.',
		vertices: 'Likewise.',
		textures: 'Unique images on the device, deduplicated by content across every loaded file.',
		textureBytes: 'What those cost.',
		culledLastFrame: 'Instances the camera frustum dropped in the last render(). Meaningful with shadows on too: the shadow pass has its own draw list against the light\'s box, so turning shadows on no longer costs the camera its cull.',
		shadowCulled: 'Instances neither pass drew — outside the camera frustum AND outside the light\'s box. 0 with shadows off. A caster the camera cannot see is still drawn into the map, so this is smaller than culledLastFrame, not equal to it.',
		shadowDraws: 'Draw calls the last frame\'s shadow pass made, and 0 with shadows off. Roughly drawCalls minus the transparent buckets and the helpers, so this is what shadows cost in draws. With static casters in the scene it counts the movers alone — the rest were drawn once and kept.',
		shadowStaticDraws: 'Draw calls that went into the cached half of the shadow map, and 0 on every frame that did not rebuild it — which should be almost all of them. Zero here with objects marked static is the saving working: the map held from one frame to the next. If it equals the caster count every frame, something is invalidating the cache — a camera that has not settled, or a node marked static that is still being moved.',
		skinnedDraws: 'Draw calls whose geometry is posed by a skeleton.',
		skinnedInstances: 'Characters in those draws. A hundred here with skinnedDraws at 1 is the crowd working as intended.',
		preskinnedInstances: 'Of those, the ones routed through the compute pass — instantiate({ skinning: \'compute\' }). '
			+ 'The expensive kind: each holds a posed copy of its mesh per frame in flight, and each is a draw call of its own.',
		poseBytes: 'Device memory holding baked animation poses, uploaded once per rigged file and shared by every '
			+ 'copy of it. This is what a rigged file costs that an unrigged one does not — there is no per-frame '
			+ 'palette upload behind a baked character, which is why a hundred of them is affordable.',
		gpuMs: 'Milliseconds the GPU spent on the frame you just asked for, measured on the GPU\'s own '
			+ 'clock rather than timed from here. three.render() and a screenshot each leave their own '
			+ 'measurement behind, so render first and read this after. 0 before anything has been drawn, '
			+ 'and 0 for the whole run in a context with no device — the same zero either way, so use '
			+ 'renderSize() if you need to tell "nothing drawn" from "nothing to draw with". The span is '
			+ 'the whole submission, including the blit or the readback copy that puts the frame where you '
			+ 'can see it, so it answers what the frame cost rather than what the draws cost.',
		prepareMs: 'Of gpuMs: uploads, the frame\'s buffer writes and compute skinning. Everything before '
			+ 'the first pass begins.',
		shadowMs: 'Of gpuMs: the shadow map. 0 with shadows off. This is the one worth looking at first in '
			+ 'an outdoor scene — the map is fitted around the whole scene, so a wide level pays for texels '
			+ 'nowhere near the camera, and three.light.shadow.size is the knob.',
		sceneMs: 'Of gpuMs: the pass that draws the picture.',
		postMs: 'Of gpuMs: the post chain, and 0 with no post shader.',
		presentMs: 'Of gpuMs: getting the finished image out — the blit to the window, or the readback copy '
			+ 'behind a screenshot. The five add up to gpuMs, so anything unaccounted for is a bug rather '
			+ 'than a gap.',
	},
	intersection: {
		object: 'The Mesh that was hit. Null only for a node this script did not build — one opened from the command line.',
		name: 'Its name, which identifies it even when object is null.',
		distance: 'World units along the ray. Comparable across objects however each of them is scaled.',
		point: 'Where the ray met the surface, world space, as a Vector3.',
		normal: 'The surface normal there, world space, unit length.',
	},
	example: [
		'const scene = new three.Scene();',
		'',
		'// One geometry per mesh is fine — the same numbers are the same asset,',
		'// so this whole grid is a single instanced draw call.',
		'for (let x = -4; x <= 4; x++) {',
		'  for (let z = -4; z <= 4; z++) {',
		'    const cube = new three.Mesh(new three.BoxGeometry(1, 1, 1));',
		'    cube.position.set(x * 1.5, 0, z * 1.5);',
		'    cube.scale.y = 1 + Math.abs(x + z) * 0.4;   // scale is free, a new size is not',
		'    scene.add(cube);',
		'  }',
		'}',
		'',
		'const ball = new three.Mesh(',
		'  new three.SphereGeometry(1.2, 48, 24),',
		'  new three.ShaderMaterial({',
		'    uniforms: { tint: [1, 0.4, 0.2] },',
		'    fragment: "float3 shade(Surface s) { return lambert(s.normal) * tint; }",',
		'  }),',
		');',
		'ball.position.y = 3;',
		'scene.add(ball);',
		'',
		'three.camera.frameAll();',
		'three.render(scene, three.camera);',
		'return scene.stats();   // { drawCalls: 2, uniqueMeshes: 2, instances: 82, ... }',
	].join('\n'),
	exampleFromFile: [
		'const kit = three.load("assets/kit.glb");',
		'const wall = kit.mesh("wall_corner_02");',
		'const scene = new three.Scene();',
		'for (let i = 0; i < 12; i++) {',
		'  const m = new three.Mesh(wall);',
		'  m.position.set(i * 2, 0, 0);',
		'  m.rotation.y = Math.PI / 2;',
		'  scene.add(m);',
		'}',
		'three.camera.frameAll();',
		'three.render(scene, three.camera);',
		'return scene.stats();   // { drawCalls: 1, instances: 12, ... }',
	].join('\n'),
};

// -----------------------------------------------------------------------
// Reading the docs rather than swallowing them
//
// `DOCS` is about 113 KB of JSON — thirty thousand tokens an agent pays
// before it has written a line — and from anywhere but this repository it
// is ungreppable: these strings are embedded in the binary, so there is no
// file for the usual tools to search. An agent that wanted one fact had to
// take all of them or none.
//
// So the docs answer four questions instead of one. `docsIndex()` is what a
// bare ask gets: everything short in full, and the NAMES of everything long.
// `docsSearch(term)` is the grep — every entry whose path or prose mentions
// a word, with its text. `findSection(path)` is the drill-down after either.
// `docsMarkdown()` is the whole surface as a file, one heading per entry,
// for the agent that would rather grep it with its own tools and never call
// this again. The full dump is still there behind `{ all: true }`, because
// an agent with the room for it should be able to say so.

// Dumped whole in the index. Each is short, and each is read on nearly every
// task: `differences` is the section that stops scripts failing, and `stats`
// is the block that comes back from every `run_script` whether asked for or
// not. `classes` and `functions` are the 83 KB that becomes a name list.
const INDEX_WHOLE = [
	'version', 'summary', 'differences', 'keys', 'stats', 'intersection',
	'example', 'exampleFromFile',
];

const HOW =
	'This is the INDEX, not the whole documentation: `classes` and `functions` are name lists '
	+ 'here and the prose behind a name is one call away. { search: "shadow" } is the grep — every '
	+ 'entry whose name or text mentions a word, in full. { section: "classes.ShaderMaterial" } is '
	+ 'one entry or one whole section, and a bare name like "ShaderMaterial" is found too. '
	+ '{ path: "api.md" } also writes the whole surface to a file, which is how you grep it with '
	+ 'ordinary tools instead of calling this again. { all: true } is everything at once, the way '
	+ 'this used to answer. From a script the same four are three.getApiDocs({ ... }).';

// One answer is capped at roughly this many characters of prose. A search for
// a common word matches half the API, and an answer that quietly became the
// whole dump again would defeat the point of asking narrowly.
const SEARCH_BUDGET = 20000;

// The compact answer: everything short, and the names of everything long.
export function docsIndex() {
	const index = { how: HOW };
	for (const [key, value] of Object.entries(DOCS)) {
		index[key] = INDEX_WHOLE.includes(key) ? value : Object.keys(value);
	}
	return index;
}

// Every entry whose path or prose mentions `term`, case-insensitively.
//
// Entries come back whole and keyed by the path `section` takes, so a hit is
// both the answer and the way to ask for its neighbours.
export function docsSearch(term) {
	const query = String(term == null ? '' : term).trim();
	if (query.length === 0) return { query, matches: 0, entries: {} };

	const wanted = query.toLowerCase();
	const hits = [];
	for (const [path, value] of docsEntries()) {
		if (path.toLowerCase().includes(wanted) || entryText(value).toLowerCase().includes(wanted)) {
			hits.push([path, value]);
		}
	}

	const answer = { query, matches: hits.length, entries: {} };
	const notShown = [];
	let spent = 0;
	for (const [path, value] of hits) {
		const cost = path.length + entryText(value).length;
		// `spent > 0` so the first hit is always answered with, however long it
		// is: an answer that dropped everything would be worse than a long one.
		if (spent > 0 && spent + cost > SEARCH_BUDGET) { notShown.push(path); continue; }
		answer.entries[path] = value;
		spent += cost;
	}
	if (notShown.length > 0) {
		answer.notShown = notShown;
		answer.note = `${notShown.length} more entries matched than fit in one answer. They are named `
			+ 'in notShown — ask for one with { section } — or search for something narrower.';
	}
	return answer;
}

// One entry or one whole section, by the path `docsSearch` keys its hits with.
//
// Answers { path, value } for what was found, or null.
export function findSection(path) {
	let node = DOCS;
	let rest = String(path == null ? '' : path).trim();
	const walked = [];

	while (rest.length > 0) {
		if (node === null || typeof node !== 'object') return null;
		const key = longestKey(node, rest);
		if (key === null) return bareName(String(path).trim());
		walked.push(key);
		node = node[key];
		rest = rest.slice(key.length + 1);
	}
	if (walked.length === 0) return null;
	return { path: walked.join('.'), value: node };
}

// The whole surface as Markdown, one heading per entry.
//
// A file rather than an answer: the headings are the paths `section` takes, so
// a grep hit names the thing to ask about next as well as answering.
export function docsMarkdown() {
	const out = [
		'# three.c3 — the scripting API',
		'',
		`Version ${DOCS.version}. ${DOCS.summary}`,
		'',
		'Written out of the docs embedded in the binary; `get_api_docs` answers out of the same '
		+ 'object, so this file and the tool cannot disagree. Every heading below is a path that '
		+ '`three.getApiDocs({ section: "..." })` accepts.',
		'',
	];

	let section = null;
	for (const [path, value] of docsEntries()) {
		const head = path.split('.')[0];
		if (head !== section) { section = head; out.push(`## ${head}`, ''); }
		if (path !== head) out.push(`### ${path}`, '');
		out.push(entryMarkdown(value), '');
	}
	return out.join('\n');
}

// The one entry the host calls, and what `three.getApiDocs(options)` is.
//
// `options` is a search string, or { search, section, all, markdown }, or
// nothing at all — which is the index.
export function docsQuery(options) {
	if (options === null || options === undefined) return docsIndex();
	if (typeof options === 'string') return docsSearch(options);
	if (options.all === true) return DOCS;
	if (options.markdown === true) return docsMarkdown();

	const search = typeof options.search === 'string' ? options.search.trim() : '';
	if (search.length > 0) return docsSearch(search);

	const section = typeof options.section === 'string' ? options.section.trim() : '';
	if (section.length > 0) {
		const found = findSection(section);
		if (found === null) {
			return {
				section,
				found: false,
				sections: Object.keys(DOCS),
				note: 'No entry by that name. The top-level sections are in `sections`, and '
					+ '{ search } finds an entry whose name you only half remember.',
			};
		}
		return { section: found.path, entry: found.value };
	}
	return docsIndex();
}

// The longest key of `node` that `rest` begins with, on a '.' boundary and
// case-insensitively. Longest rather than first because a function is keyed by
// its whole call — `three.load(path)` — so not every dot in a path is a
// separator, and the greedy match is the only one that tells the two apart.
function longestKey(node, rest) {
	const wanted = rest.toLowerCase();
	let best = null;
	for (const key of Object.keys(node)) {
		const lower = key.toLowerCase();
		if (wanted === lower || (wanted.startsWith(lower) && wanted[lower.length] === '.')) {
			if (best === null || key.length > best.length) best = key;
		}
	}
	return best;
}

// `section: "ShaderMaterial"` rather than `"classes.ShaderMaterial"`. An agent
// that read a class name out of the index and asked for it by that name asked
// a reasonable question, and one level of looking is the whole answer.
function bareName(name) {
	const wanted = name.toLowerCase();
	for (const [group, value] of Object.entries(DOCS)) {
		if (value === null || typeof value !== 'object' || Array.isArray(value)) continue;
		for (const key of Object.keys(value)) {
			if (key.toLowerCase() === wanted) return { path: `${group}.${key}`, value: value[key] };
		}
	}
	return null;
}

// Every entry of the docs as [path, value].
//
// The shape is two deep and this walk knows it: a top-level plain object is a
// SECTION, everything one level inside one is an entry, and nothing deeper is.
// That is the line that matters, and no test on the values finds it — a class
// record's { construct, note, properties, methods } is four halves of one
// answer and has to stay whole, while `differences` is a map of the same shape
// holding fifty separate answers that must not be glued into one.
function docsEntries() {
	const out = [];
	for (const [key, value] of Object.entries(DOCS)) {
		if (isSection(value)) {
			for (const [name, entry] of Object.entries(value)) out.push([`${key}.${name}`, entry]);
			continue;
		}
		out.push([key, value]);
	}
	return out;
}

function isSection(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function entryText(value) {
	if (value === null || value === undefined) return '';
	if (typeof value === 'string') return value;
	if (Array.isArray(value)) return value.join('\n');
	if (typeof value !== 'object') return String(value);
	return Object.entries(value).map(([key, field]) => `${key} ${entryText(field)}`).join('\n');
}

function entryMarkdown(value) {
	if (value === null || value === undefined) return '';
	if (typeof value === 'string') return value.includes('\n') ? '```\n' + value + '\n```' : value;
	if (Array.isArray(value)) return value.map(item => `- ${item}`).join('\n');
	if (typeof value !== 'object') return String(value);
	return Object.entries(value)
		.map(([key, field]) => `**${key}**\n\n${entryMarkdown(field)}`)
		.join('\n\n');
}
