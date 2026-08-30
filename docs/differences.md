# Differences from Three.js

## load-is-synchronous

three.load(path) is synchronous; await works but is not needed.

## measure-everything

Everything placeable can be MEASURED, and you should measure rather than guess.
asset.mesh(name).bounds and geometry.bounds are a Box3 in the piece's own space, read out of the
glTF JSON so it costs no upload; object.boundingBox() is the world-space box of a subtree, from the
host; object.boundsInParent() is the same box in the parent's frame and works before add(). A kit
piece's origin is wherever its exporter left it, so a size table written by hand into a script is
the thing that goes stale and sinks pieces into walls.

## align

object.align(axis, edge, at) moves an object until one face of its box sits at a coordinate —
align('y', 'min', 0) stands a piece on the ground, align('z', 'min', wallZ) puts its back flush with
a wall. object.alignTo(other, {axis, mine, theirs, offset}) says the same thing against a sibling.
Both work in the PARENT's frame, because that is the frame a script writes positions in; alignTo
refuses objects with different parents rather than being wrong by whatever the parents differ by.
Set rotation and scale first — they are inputs to where the box is.

## debug-draw

There is DEBUG DRAW, and reaching for it is the cheap move: three.BoxHelper(object) boxes what an
object actually occupies, three.Box3Helper(box) boxes a Box3 you worked out yourself,
three.AxesHelper(size) shows where a pivot is and which way it faces, three.GridHelper(size,
divisions) says where the ground is, and three.WireframeHelper(mesh) draws a mesh's own edges —
which is how two faces 0.01 apart are found, because a z-fighting starburst is invisible in a solid
render. They are ordinary meshes: a thousand of them are one draw call, helper.color is per copy and
free, scene.remove(helper) works, and they are NOT pickable, so a click goes through the box onto
the thing inside it.

## helpers-draw-over

Helpers draw OVER everything — the line pipeline tests no depth, unlike Three.js's helpers. That is
deliberate: the times you ask where something is are the times it is inside a wall, and a
depth-tested helper would be hidden by exactly the geometry being asked about. The cost of being
ordinary meshes is the other direction: a helper draws, so it is inside boundingBox(), inside the
boundsInParent() of whatever it hangs from, and inside three.camera.frameAll(). Align first and add
helpers after, or hang them from a Group of their own.

## helper-material

A helper cannot be given a ShaderMaterial. A material is a pipeline and every pipeline you can build
draws triangles, while a helper's indices are pairs — assigning one would read the pairs as
triangles rather than fail, so it throws instead. helper.color is the knob a helper has.

## geometry-kinds

Geometry is BoxGeometry, SphereGeometry, PlaneGeometry, CylinderGeometry, ConeGeometry,
TorusGeometry and ConvexGeometry, built for you with Three.js's signatures, defaults and
orientations. There is no BufferGeometry, no attribute access and no way to read or write a vertex —
that refusal is what makes every scene one instanced draw per unique shape.

## convex-geometry

new three.ConvexGeometry(points) is the way to make a shape that is not one of the six parametric
ones: hand over a cloud of points and get its convex hull. Rocks, crystals, gems, debris, the bound
of a scan. It takes Vector3s, [x, y, z]s or a flat array of coordinates, needs at least 4 points,
and is capped at 65536. It is flat shaded, because a hull's faces meet at hard creases, and it is
textured face by face: each facet gets its own planar projection at one uv unit per unit of local
space, so a map is the same size on a hull as on a box beside it. The points are a description the
hull is computed from, not the mesh's vertices — most of them are discarded and none can be read
back.

## geometry-identity

Two geometries with the same numbers are ONE asset and one draw call, however many times you
construct them. Two different sizes are two. Prefer mesh.scale over a new size when you want variety
cheaply.

## mesh-construct

new three.Mesh(geometry, material) takes either a generated shape or asset.mesh(name); material is
optional, as in Three.js.

## color-and-variant-only

mesh.color and mesh.variant are the ONLY two things copies sharing a geometry and a material may
differ in without becoming separate draw calls. A thousand meshes in a thousand colours is one call;
giving two of them different materials is two. There is no InstancedMesh because every mesh is
already an instance.

## uniform-tables

A ShaderMaterial uniform may be a table — { palette: [[1,0,0], [0,1,0]] } becomes float3 palette[2]
and mesh.variant picks the row. That is how one material gives many meshes many looks. s.variant is
clamped to the table, so an index past the end is the last row. A table is not capped at the push
block: past 104 bytes the array columns move to a device buffer on their own and the body is
unchanged, so hundreds of rows is an ordinary thing to ask for (up to 256 KiB, which is thousands).
PLAIN uniforms — the ones with no rows — do stay in the push block and are still held to that 104.

## vertex-stage

A ShaderMaterial has a vertex stage as well as a fragment one: { vertex: `void displace(inout Vertex
v) { v.position.y += sin(v.local.x * 3 + t) * 0.4; }` } moves geometry per vertex with no draw call,
no upload and no geometry change — the mesh is still the same asset and a thousand copies of it are
still one call. Vertex is the varyings: position (world), normal, uv, color and variant are read
back after your body runs, and local (object space) and index (the vertex number) are inputs. The
normal is not recomputed for you. Always pass `bounds` with a vertex body — the number of world
units it can displace by — because culling tests the mesh's undisplaced box and geometry outside it
is dropped while still on screen.

## one-module

The vertex body and the fragment body compile into ONE Slang module, vertex first. So a helper
function may be declared in only one of them — declaring `float3 ripple(float2 q)` in both is
`error[E30201]: function 'ripple' already has a body`, which is correct and surprising. Put shared
helpers in `vertex`, which comes first, and call them from `fragment`.

## material-samplers

A ShaderMaterial or a post pass may declare up to four samplers of its own: { textures: { noise_map:
tex } } makes noise_map.Sample(uv) work in the body. You never write a binding number — the shader
is generated with the bindings in it and the host resolves each name through the compiled module's
reflection, so adding one at the front of the list renumbers nothing. material.map is separate and
is still the base colour image. A sampler declared and left null reads 1x1 white rather than reading
nothing, and both objects are live: mat.textures.noise_map = other swaps the image with no compile.

## no-colour-management

Colours are linear rgb in 0..1 (hex is divided by 255, not de-gamma'd): there is no colour
management here, and half of one would be worse than none.

## many-scenes

A Scene is an ordinary object and you can hold as many as you like. new three.Scene() makes one and
shows it; it does NOT empty or free the one before it, which keeps its objects, its bodies and its
nav bake until you call dispose() on it. Exactly one scene is rendered at a time — scene.activate()
is the switch, scene.isActive says which — and only that one is drawn, culled, queried and stepped.
That is the level transition: build the next scene while the current one is on screen, activate it,
dispose the old one, then three.unloadUnused(). The look travels with the scene — scene.background,
every light in three.lights and three.light.shadow are the ACTIVE scene's, and activating a scene
again brings back the ones it had, all four lights included, so a level does not come home to the
default sky. Two consequences worth knowing before you rely on it. Bodies you add to a scene that is
not active are correct and MOTIONLESS, because the frame steps one world; a nav bake is not, because
baking is voxelization over that scene's own triangles and needs no frame at all, so the next
level's pathfinding can be solved before anybody sees it. And nothing frees a scene for you:
stats().scenes is the count, three.scenes is the list behind it — one entry per world, with held
saying whether three.sceneById(id) hands back that Scene or a bare handle onto it — and
three.disposeInactive() frees every world except the one being rendered and sweeps afterwards, which
is the whole transition minus the activate. A game that transitions eight times and never disposes
holds eight worlds.

## manual-free

Nothing is freed until you say so. scene.unload() empties the scene and gives back every asset and
texture nothing else holds; scene.dispose() frees the whole scene, its bodies and its bake with it;
three.unloadUnused() does the freeing without the emptying. None of them is a garbage collector —
resident memory that depended on when the interpreter felt like collecting would be the worst
possible property for the one number a game watches — and stats().assets is how you watch it work.

## stale-handles

An asset handle goes stale when the asset is unloaded, because the host reuses the slot. Naming one
throws a sentence saying so, and it throws at the new three.Mesh() that named it rather than waiting
for the scene.add() that would have drawn it — so the line that is wrong is the line that is blamed,
which matters in a script that builds a subtree and adds it at the end. Loading the file again gives
a fresh handle. Object handles go stale the same way, and the event is scene.dispose() rather than
new three.Scene() — a scene you stopped rendering still holds its objects, so its handles still
resolve.

## camera-is-a-turntable

There is one camera, a turntable: three.camera.orbit(yaw, pitch, distance) and
three.camera.frameAll(). It is read-ONLY through accessors —
camera.yaw/.pitch/.distance/.fov/.near/.far read back, camera.position()/forward()/right() give the
eye and the look/strafe directions in world space, and camera.planarMove(fwd, strafe) turns a
W/A/S/D input into a world direction. There is no camera.position to assign, and yaw/pitch/distance
throw if assigned.

## spatial-queries

There are BULK SPATIAL QUERIES, and they go through an index rather than a scan:
three.query.sphere(point, radius), three.query.box(box), three.query.raycastAll(origin, direction)
and three.query.sweep(from, to, { radius, height }). scene.raycast goes through the same index,
which is why it stopped being linear in the node count — it used to test EVERY node in the scene
before it reached any BVH, and a hundred agents casting one ground ray apiece cost 2.1 ms in a
500-node demo. The index is refreshed by the first query after anything moved and by nothing else,
so a frame that asks nothing pays nothing and the hundredth ray in a frame costs a cell walk. MOVING
SOMETHING AND THEN ASKING ABOUT IT IS FINE: a moved node has its entry re-filed rather than the
whole index rebuilt, so a gameplay step that moves eleven characters between its sweeps costs what
one that moved none does. Toggling object.visible costs the index nothing at all — an invisible node
is skipped when a query ANSWERS, so hiding things is the free way to keep them out of a sweep. What
does still rebuild it is structure: adding a node, removing one, re-parenting one, or setting
object.collides. Every verb comes in two forms: three.query.sphere(p, r) allocates an Array of
objects and is right for a click or a one-off, and three.query.sphere(p, r, buffer) fills a
three.query.buffer(n) you keep and answers with a count, which is right for the loop. box and sphere
are BROAD phase — box against box — so a node whose box overlaps and whose triangles do not is
included; raycastAll and sweep are exact.

## not-collision-geometry

Every drawable mesh is swept and raycast against, so a pickup lying on a path is a bollard and a
field of grass is a fence. object.collides = false is the fix: it takes that ONE mesh out of the
spatial index entirely — three.moveAndSlide walks through it, three.query.sphere does not report it,
scene.raycast misses it — while it still draws exactly as before. three.physics is untouched by it,
so a mesh with collides = false and a { trigger: true } body is the ordinary way to write a pickup
you can walk INTO and cannot walk into; before this the shape that worked was two nodes, the thing
you see and an invisible volume beside it. It is NOT inherited: set it on the meshes rather than on
a Group, because it says what one piece of geometry is. Hiding a whole character from ONE sweep is {
ignore } on that call, and hiding something from the frame is object.visible = false — which is free
and costs the index nothing, where toggling collides costs an index rebuild. It is an authoring
flag, not a per-frame one. stats().colliders is how many meshes are in the index, and reading it
beside stats().nodes is how you find out that a level is mostly scenery pretending to be walls.

## systems-and-casts

A BIG ANIMATION LOOP IS THE PROBLEM THIS SOLVES, not a slow one. three.systems.step(name, fn) and
three.systems.frame(name, fn) are an ordered, named list that replaces the one callback
setAnimationLoop and setFixedLoop each take — the verb is the clock, they run in the order you
register them, and { before: 'other' } moves the one that has to break that, with
three.systems.report() giving per-system milliseconds over three.clock.wall — which is the CPU half
of what three.stats() has done for the GPU half all along. setAnimationLoop and setFixedLoop are
systems under reserved names, so nothing a script already wrote changes, and a system that throws
does not stop the others. three.cooldown(duration, { recover, phase }) is a second rider on the same
registry: a scalar timer — active, ready, recovering, remaining, progress — ticked by a
lazily-registered system rather than read off three.clock, because the clock only advances once per
host tick and a coyote-sized window can span several fixed steps of that one tick. The STORAGE half
is three.Entity — see entities-and-rules — and it registers a compaction of its own on the same
registry. None of this makes a frame faster: every JavaScript-side data layout measured inside the
noise floor. What it buys is a frame that reads as a list of named things and a slow one you can
attribute.

## entities-and-rules

A GAME IS ENTITIES AND THE RULES BETWEEN THEM, and class Critter extends three.Entity is how a plain
JavaScript class becomes one. There is no registration call beside the declaration: the class
registers itself on first use, reading static capacity / columns / parent / body / volume / trigger
/ collides off itself, and super() in the constructor is where a bare new Critter() is refused.
three.track(Class, options) is the same registration for a class that already has a parent and
cannot extend this one; it takes the options as an argument instead. It owns the object -> instance
map, the spawn ritual, the physics body, the collision volume, the live list and the deferred
compaction, so Class.of(hit.object) is the instance and c.remove() is the whole removal: body,
volume, node and map entry, on this tick. static volume = { shape: 'capsule', radius, height, offset
} is an invisible kinematic body beside the drawn node, carried by `<Class>.follow`, and static
trigger is the same declaration with trigger: true — which is what gives a player moved by
three.moveAndSlide something to trip a trigger with, and what a near rule measures against. c.hp = 3
is an ordinary field on an ordinary object. The two or three fields a BULK VERB reads are declared
as { columns: { position: 3 }, capacity: N } and the instance holds a subarray WINDOW onto the
shared column, so three.steer(Critter.column('position'), ...) is handed the storage itself and
nothing is ever gathered — which is the whole difference between this and copying entities into a
staging array every frame. Class.spawn(...) rather than new Class(...), because the slot has to
exist before the constructor runs. The rules are the other half: Class.on(event, matcher, fn,
options) dispatches on a PAIR, SUBJECT FIRST — the rule lives on Critter, so the handler is handed
(critter, player) in that order and the class IS the argument-order declaration. The matcher is a
tracked class, an Object3D, '*', or a class name as a string for a forward reference. Events:
enter/exit from a trigger, touch/separate from a contact, click from the raycast, near from { within
} — a distance test the engine runs, and the one physics never raises, because three.moveAndSlide
produces no contact at all. Anything else is the game's own, through three.emit(a, verb, b). Engine
events QUEUE and are drained by one system named rules; three.emit dispatches at once, because the
game knows when it is safe to delete something and the solver does not. Rules replace by name so a
hot reload does not double them, and one that throws is contained, named and counted rather than
stopping the rest. It replaces three.cast and three.kind, whose defect was that the storage choice
was made at declaration time and was irreversible at every call site.

## crowds-in-one-crossing

THE THREE VERBS THAT SCALE WITH A PACK, and the rule behind them is that a verb called once per
agent per frame answers into memory you already own. three.steer(positions, velocities, options) is
seek, arrive and separation for the whole crowd. three.moveAndSlideAll(positions, motions, options)
is the character controller for the whole crowd, updating positions IN PLACE, with self as the
column of handles that keeps each agent out of its own mesh and an optional three.moveBuffer(n) for
the grounded/slope/normal answers. field.sample(positions, { costs, directions }) is the flow field
for the whole crowd. three.batch(objects, { euler: true }).flush() then draws them in one more
crossing. Measured at 200 agents: the same frame written with the single-agent verbs is 2.20 ms and
written with these is 0.51 ms, and the difference is almost entirely the per-agent JavaScript
objects the single forms build. The single forms are not deprecated and are the right choice for one
character — the player, the thing riding the moving platform — because they answer with node handles
and a readable object; the bulk ones are the right choice the moment there is a loop around the
call. A NEGATIVE COST IS UNREACHABLE in the bulk sampler where field.cost answers Infinity, and that
is the one place the two disagree.

## move-and-slide

three.moveAndSlide(position, motion, options) is the character controller: it sweeps a capsule,
slides along what it hits, climbs a ledge under the step height and reports whether it is standing
on anything. It takes a POSITION and answers with a position — it does not own an object, integrates
nothing and remembers nothing between calls, so gravity, the velocity and the jump stay yours.
Options are { radius, height, step, slope, skin, snap, ignore }; height is the whole capsule, and
slope in degrees decides grounded, whether a ledge is climbed and whether a contact is a floor or a
wall, all from one number so three cannot disagree. Pass the character's own object as ignore or it
collides with its own mesh, and pass the GROUP rather than one mesh out of it — ignore leaves the
whole SUBTREE out, so a character built from a body, a head and four limbs does not collide with its
own chest. It takes an array too, for up to eight things. It is kinematic and touches no rigidbody:
a character built out of physics is pushed by contacts, tips over and answers a frame late.

## navigation

three.nav.bake({ cell, radius, height, slope }) voxelizes the scene's standing room, and NOTHING
bakes it for you — call it after the level is built. Then TWO verbs, and the split is the design:
three.nav.path(from, to) is one agent's route, and three.nav.field(goals) is a solve KEPT that a
whole crowd samples. A path solves the entire reachable set and throws it away, so a hundred agents
heading for one door is a hundred solves for one field. A field has direction(point), cost(point) —
Infinity for unreachable — and dispose(). Paths come back shortened against the actual geometry with
a capsule sweep at the agent's own size, so they do not look like they are walking cell centres, and
their waypoints sit on the floor. cell decides everything: it is the resolution AND the largest step
that can be climbed, because two cells are connected when they are adjacent and one cell up.
three.nav.stats() reports voxels, walkable and bakeMs so you can find out whether the bake is a
level-boundary operation or a loading screen.

## steering

three.steer(positions, velocities, options) fills a Float32Array with a desired velocity per agent —
seek, arrive and separation, for the whole crowd, in ONE crossing. positions is three floats per
agent and is read; velocities is three floats per agent and is written. Options are { field, goal,
maxSpeed, arrive, separation, separationWeight }; a field wins over a goal, because a field already
knows the way round a wall. What comes back is a DESIRED velocity, not a position: integrating it
and deciding whether an agent may actually go there are yours, which is what lets the same call feed
three.moveAndSlide for agents that collide and a plain add for agents that do not.

## batched-transforms

three.batch(objects) moves many nodes in one crossing, through a Float32Array. It is NOT a faster
way to move a dozen things and should not be reached for as one — five hundred ordinary
mesh.position.set calls measure 0.245 ms a frame, three per cent of the budget, and the trigger for
this is about two thousand nodes a frame. It is for the case where the write is already a loop over
numbers: a crowd steered by three.steer, a particle field, a chunked terrain. batch.positions is a
Float32Array seeded from where the objects are now; batch.flush() writes them and answers with how
many landed. With { trs: true } the stride is ten floats — position, an xyzw QUATERNION, then scale.

## window-is-not-the-picture

three.window.resize(width, height) makes the WINDOW bigger and does not make the picture bigger.
Everything renders into an offscreen target fixed at what --width/--height asked for when the
process started, and the swapchain stretches the whole of that onto the whole window — so a wider
window is the same pixels spread wider, and three.renderSize(), the PNG a screenshot comes back as
and the coordinates scene.pick(x, y) counts in are all unchanged. Nothing in the JS API moves the
render size; it is a boot argument. three.window.width and .height are device pixels read off the
drawable rather than off the window, so they are current through a live resize drag, and .scale is
device pixels per logical point. Resizing is a REQUEST: X11's window manager may adjust it and
Wayland answers with a configure some frames later, so the new size arrives on a later frame. Under
--headless there is no window, the sizes read zero and resize() returns false rather than throwing —
the same shape three.input.pointerLock uses, so a game that sizes its window still starts where
there is none. And on WAYLAND the size never reads back at all: that surface answers 'whatever the
swapchain asks for' instead of a size, so the drawable stays what the process booted at whatever the
window does.

## the-interface

There is a UI, and it is DRAWN INTO THE FRAME rather than over the window: three.ui.set(tree)
describes a panel, three.ui.patch(key, props) changes one value in it, and three.ui.draw(ops) is the
screen-space layer a crosshair and a health bar live in. It goes into the same offscreen target the
scene does, after the post chain, so --screenshot and the MCP screenshot tool carry it and an agent
reads the interface a person sees. It is RETAINED: a node that did not change costs nothing to
redraw, so the guidance is set when the shape changed and patch when a number did, not rebuild every
frame. It ARBITRATES the pointer: a click on a button does not also orbit the camera or reach
three.onClick, and typing in a text field is not also WASD — while a caption, a panel background and
a drawing are transparent to the pointer, so nothing you put over the viewport becomes a dead zone
unless it says solid: true. Give anything you type into, scroll or open a key, because set rebuilds
the tree and a key is what carries the text, the scroll position, the open popup and the keyboard
focus across the rebuild. THE SET/PATCH SPLIT IS BOOKKEEPING AND three.Widget DOES IT: class Hud
extends three.Widget with one render() method describing the interface as it is now, composed out of
the node classes on three.ui (Panel, Label, Button, ...), and assigning a field re-renders and sends
only what changed. Colours are linear like everything else here — see no-colour-management — so
0x808080 is the same grey a material would be.

## pointer-lock

three.input.pointerLock = true takes the mouse pointer out of the user's hands, and what it buys is
a look that does not STOP. Without it three.input.pointer.dx is a difference of cursor positions,
and a cursor stops at the edge of the screen while a hand does not — so a mouse look turns until the
pointer reaches the edge and then quietly refuses to turn further. Reading the property back tells
you whether the platform gave it, not what you asked for: a headless run has no window and always
reads false, and so does a backend with no implementation. Nothing throws, so a game can fall back
to a drag-look rather than refuse to start. three.input.pointer.locked is the same fact reported
beside the deltas it is about.

## scalar-math

The MathUtils block is on three itself: clamp, clamp01 (GLSL's saturate), lerp, inverseLerp,
mapLinear, smoothstep, smootherstep, band, pingpong, euclideanModulo, degToRad, radToDeg,
moveTowards, plus wrapAngle / angleDelta / moveTowardsAngle for the seam at +/-pi and mixColor /
tintColor for colours. Three.js's names and Three.js's ARGUMENT ORDER, which matters for exactly one
of them: smoothstep here is (x, min, max) and GLSL's is (edge0, edge1, x), so the shader body and
the script a few lines above it take the same three numbers in different orders and swapping them is
silent. Randomness is three.randFloat / randInt / randFloatSpread and they do NOT use Math.random —
they draw from a seeded stream three.seed(n) resets, because one Math.random() in the gameplay layer
throws away the determinism the fixed step and state_hash exist for. Noise is three.hash / noise2 /
fbm2, sampled at a point, with a period option that makes a texture tile. None of this crosses to
the host: a host call that allocates to answer arithmetic measures 185 ns against the 70 ns of the
JavaScript it replaced, and it is slower on every call forever.

## damping-and-curves

three.damp(current, target, lambda, dt) and three.smoothDamp(current, target, state, smoothTime, dt)
are the two verbs between "where it is" and "where it should be", and both are frame-rate
independent — which is the whole reason they are named rather than written inline. `x += (target -
x) * 0.1` closes a tenth of the gap per FRAME, so it is twice as fast at 120 Hz as at 60 and a chase
tuned on one machine is a different chase on another. damp is a decay, right for a camera easing
onto a target; smoothDamp is a critically damped spring with momentum, right for a turret slew or a
sliding panel, and its state object must OUTLIVE the frame or it is re-launched from rest every
tick. three.dampAngle takes the short way round a circle, which is what a heading needs. dt is in
SECONDS, and so is three.clock.dt — pass it straight through, or the dt a three.systems system is
handed, which is the same number. new three.CatmullRomCurve3(points) is the three-dimensional curve
a loop samples — getPointAt(u) walks its LENGTH and getPoint(t) walks its own parameter, and the
difference is what makes hand-written rail code look wrong.

## camera-follow

The camera can FOLLOW something: three.camera.attach(object, { offset, distance, lag }) puts the
orbit point on that object every frame, after the animation, the physics and your animation callback
have all moved it — so the camera is never a frame behind, which is what makes a trailing camera
look like the character sliding. three.camera.detach() stops, three.camera.attached is what it is
following or null. A drag still orbits and the wheel still zooms while attached; a PAN is the one
gesture that stops working, because a pan writes the orbit point and the next frame writes it back.
There is one camera and it follows something in the scene being RENDERED: attaching it to an object
in a scene that is not throws, and activating a scene detaches it, because a follow into a graph
nobody is drawing would silently stop following.

## camera-first-person

FIRST PERSON is distance 0, and it is not a mode: the eye sits on the point it orbits, so
three.camera.attach(character, { offset: [0, 1.7, 0], distance: 0 }) is a person and scrolling back
out is a third-person camera again with nothing to switch. The offset is where the head is, in WORLD
space — [0, 1.7, 0] is the same vector whichever way a character faces. Aim it with
three.camera.orbit(yaw, pitch), leaving the distance argument off, and three.input.pointer.dx/dy is
what a mouse look feeds it.

## camera-planes-derived

The near and far planes are derived, not set: from the orbit distance and from the scene's own
bounds, every time the camera moves. Three.js makes them constructor arguments to PerspectiveCamera.
Read them — three.camera.near and .far — when something has stopped being drawn, because geometry
past far is absent rather than dim and is culled as well as clipped. Assigning either throws rather
than being ignored.

## lights

Up to FOUR directional lights, and none of them is an Object3D. three.lights is the list and
three.lights[0] === three.light is the sun — the only one that casts a shadow, which is why the
shadow settings hang off it. Each has direction (a world-space surface-to-light vector, live:
three.light.direction.y = -1 writes through), color (white by default) and intensity (1 by default,
and it multiplies the colour, so it is how a light goes brighter than white). three.lights.add([1,
0, 0], 0x4060ff, 0.5) fills the next slot and answers with it; three.lights.remove(i) closes the
gap; light 0 cannot be removed, set its intensity to 0 instead. Not scene.add(new
DirectionalLight(...)), because a light here has no position, nothing can be parented to it and
scene.remove does not reach it — a name Three.js has would promise all three. A direction is not
normalized, so it reads back as you wrote it, and a zero one throws rather than turning every shaded
pixel into a NaN. Adding a fifth throws.

## ambient

three.light.ambient is the floor a face turned right away from EVERY light gets, 0 to 1: at 0 it is
black, at 1 there is no shading at all and everything is its own flat colour. It is on three.light
rather than on each light because it is not a light — it stands in for every bounce this renderer
does not simulate, and four of them summed would be four times the same fudge.
three.light.set(direction, ambient) sets the sun and the floor at once; the second argument is the
floor and not a colour, which it was before lights had colours. Defaults to 0.25, and a new Scene
restores it.

## specular

There is a specular term, and it is off on every material until you ask. material.reflectance is the
switch: 0 by default (no highlight at all — the surface every material here had before the term
existed) and 0.5 is the 4% that ordinary dielectrics reflect, which is what to use for anything wet,
polished or glazed. material.roughness spreads the highlight out, 1 by default and perfectly
diffuse. material.metalness moves a surface's colour out of the diffuse and into the highlight — and
with no environment map to reflect, a fully metallic surface is its highlights and the ambient floor
and nothing else, which is correct and is dark. In a ShaderMaterial body, standard(s) is the whole
built-in shading, specular(s) is the highlight alone, and lambert(s.normal) is the diffuse alone — a
body written against lambert is matte and stays matte.

## shadows-off-by-default

It does cast a shadow, and it is off until you ask: three.light.shadow = true, or three.light.shadow
= { enabled: true, size: 4096 }. The four properties are enabled, size (texels per side, clamped to
256..8192 and rounded down to a power of two), bias (extra depth offset in the light's clip space, 0
by default) and intensity (how dark, 0 to 1). Nothing is allocated and no shader is compiled until
the first frame with it on, and a new Scene turns it back off.

## shadow-cast-receive

Everything opaque casts and everything shaded receives — there is no castShadow or receiveShadow per
object, because two copies of one mesh disagreeing about it would be two draw calls and this
renderer is built to refuse that trade. A transparent material casts nothing (a shadow map holds one
depth per texel, so glass would have to be either solid or absent, and absent is the better wrong
answer) and neither does a debug helper. A ShaderMaterial receives shadows with no change to its
body: lambert() already has the shadow folded into the direct term, and s.shadow is the raw factor
for a body that wants it separately.

## shadow-one-map

One map, fitted around the whole scene every frame, so its resolution is size divided by however
wide the scene is. If shadows look blocky the scene is large, not the map small: raise
three.light.shadow.size, or draw the part that matters and leave the rest out. There are no
cascades. Self-shadowing stripes should not appear — each sample is lifted two texels along its own
normal first — and if they do, three.light.shadow.bias is the knob, in small numbers like 0.0005.

## shadow-costs-a-draw

A shadow pass costs a second draw call per opaque bucket — stats().shadowDraws is the count — and it
turns frustum culling off for the frame, because a caster the camera cannot see still throws a
shadow into the frame. So stats().culledLastFrame reads 0 while shadows are on. Neither costs draw
calls: culling here drops instances from buckets, never buckets. Mark the scenery object.static =
true and that second pass all but disappears — see the static-casters topic.

## background-is-a-colour

scene.background is a colour or null, never a Texture: [r,g,b], 0x87ceeb, or null for the default.
There is no environment map and no scene.environment. A gradient sky is still geometry — what this
removes is having to build one to escape the default near-black.

## colours-are-srgb

Every colour you state is sRGB — the components a colour picker gives. mesh.color = 0xff8040 renders
as 0xff8040 under a full light, scene.background = 0x2060a0 screenshots as 0x2060a0, and a texture's
bytes come back out as the bytes that went in. The shading arithmetic in between is linear and the
conversion is the renderer's job, so nothing in a script should ever apply a gamma of its own; a
scene that pre-corrects its own textures will now be twice corrected.

## side-is-on-the-material

material.side is on the material and not on the mesh, because it is a property of the pipeline: two
meshes sharing a geometry and a material are one draw call and would stop being one if they could
disagree about it. three.BackSide is how a skydome is made visible from inside; scaling a sphere by
-1 does not work, because a negative scale does not reverse a triangle's winding.

## add-to-add

An object is not in the scene until it is add()ed, and removing it makes it a detached description
that can be added again.

## group-for-belonging

A Group is how several objects stay one object. Nothing else records that they belong together:
siblings built by one loop and placed by the same arithmetic have no relationship the scene graph
can see, so a later edit that moves one leaves the others where they were. Parent the pieces of a
thing to a Group, place them relative to it once, and move the Group instead. It costs a node and no
draw call.

## name-things

name is empty until a script sets it and getObjectByName answers null for a miss, both as in
Three.js — so a node nobody named is reachable only through traverse, and a misspelled one is a null
that throws somewhere else. Name whatever a later script will look for. asset.instantiate() trees
need no help: the root takes the file name and every node under it keeps the name the file gave it.

## fragment-not-program

ShaderMaterial takes a fragment function, not a whole program: you write float3 shade(Surface s) and
three.c3 supplies the vertex stage, the Surface and the uniform block. Uniforms are flat values, not
Three.js's { value } wrappers.

## post-is-a-chain

There is post-processing and it is a CHAIN, not an EffectComposer: three.setPost({ fragment }) runs
a float3 post(Post p) over the finished frame, three.addPass({ fragment }) puts another after it,
and three.setPost(null) stops all of them. There are no render targets to manage and no dependency
declarations — a pass reads what the pass before it wrote as p.color and the frame as the geometry
left it as p.scene, and those two are the whole model. The chain runs in linear float, so a pass may
return values above 1 and the next one still sees them, which is what a bright pass followed by a
blur needs; the encode to the display happens once, at the end, and is the engine's. It applies to
the window, to render() and to screenshots alike, and it belongs to the renderer rather than to the
scene, so it survives new three.Scene() and outlives the script that set it.

## mesh-no-material

A mesh with no material draws with the base colour and texture its glTF material carried.

## no-raycaster

There is no Raycaster. scene.pick(x, y) takes pixels of the rendered image and scene.raycast(origin,
direction) takes a world ray; both answer with the closest hit or null, not with an array.

## script-scope

Each run_script call runs in its own function scope. Use globalThis to keep state between calls.

## warnings-beside-log

A run_script reply carries a warnings ARRAY beside log when the renderer noticed something, and the
two are different things: log is what your script printed, warnings is what the host has to say
about it. It is absent on nearly every run, which is what makes it worth reading on the runs it
appears in — live scenes climbing, live materials climbing, a shadow map that just cost 134 MB, a
shader that would not compile, a disk cache that could not be written. Advice, not errors: the run
still succeeded. They are deduplicated and they arrive one run late when they happened between
calls, so a warning about the frame you just rendered shows up on your next call.

## animation-loop

three.setAnimationLoop(fn) runs fn once per frame, with the elapsed milliseconds, until
three.setAnimationLoop(null). It is how a scene moves without an agent in the loop. The callback
must be synchronous, is stopped for good if it throws or runs longer than 100ms in one frame, and
what it logs comes back with the next run_script under an [animation loop] marker.

## game-clock

There is a GAME CLOCK, which Three.js has nothing quite like: three.clock.dt is what the frame being
drawn is worth in seconds, three.clock.time is what the frames have added up to, and
three.clock.timeScale is the multiplier — 0 is paused. It is not a convenience over differencing the
callback's argument yourself. Everything in a frame that moves is downstream of it — the clips, the
physics, the fixed loop, the follow camera, the argument setAnimationLoop is handed and p.time in a
post body — so timeScale = 0 stops the WORLD, which no amount of a script stopping its own
arithmetic can do.

## fixed-loop-for-gameplay

Gameplay belongs in three.setFixedLoop(fn), which runs at three.clock.fixedRate (60 Hz) however fast
frames arrive and hands the callback the same dt every call. Drawing the consequence belongs in
setAnimationLoop. The accumulator is the host's: one written in the animation callback spends the
script budget catching up and gets the callback stopped for good instead of merely stuttering.

## animation-loop-freezes-render

A running animation loop makes render() and screenshot() no longer repeatable — the scene has moved
between them. three.clock.timeScale = 0 is the finer instrument: it freezes the world without
unregistering anything, and three.clock.advance(seconds) then steps it by exactly as much as you
ask, so two runs asking for the same amount draw the same frame. setAnimationLoop(null) still stops
the callback outright.

## keyboard

There is a keyboard, which Three.js has no equivalent of at all: three.input.isDown(key) for held
keys, three.input.pressed(key)/released(key) for this frame's edges, and three.onKeyDown(key,
fn)/onKeyUp(key, fn) to bind an action. Key names are the browser's KeyboardEvent.key lowercased —
three.input.keys() lists every one. It only reports anything while a window is open: --headless has
no keyboard.

## script-can-press-keys

A script can press keys itself: three.input.press(key), three.input.release(key) and
three.input.releaseAll(). A pressed key stays down until released, exactly as a finger does, and
goes through the same path a real one does — so isDown, pressed, released and every onKeyDown
handler cannot tell the two apart. It adds to the real keyboard rather than replacing it. This is
what makes an input-driven scene testable at all: a headless boot has no keyboard, so without it the
only way to exercise a character was for the scene to hand its internals to a global.

## keys-read-per-frame

Keys are read once per frame, so three.input.pressed() and three.input.text mean something inside
the animation callback and almost never outside one. isDown() is fine anywhere.

## mouse-is-one-thing

There is a mouse, and it is one thing: three.onClick(fn) calls fn(hit, x, y) with what is under the
cursor already picked. three.input.pointer is everything else about it for this frame — position,
movement, all three buttons and the wheel. There is no mouseDown and no drag events: the left button
orbits the camera, a press that travels or is held is a drag rather than a click, and the buttons
are latches a script polls rather than edges anything dispatches.

## mouse-look-and-no-pointer-lock

A mouse look is three.input.pointer.dx and .dy, not a difference you take yourself between frames —
the host differences the reading the frame is actually drawing with, while two calls from a script
straddle it. There is NO POINTER LOCK, so the movement stops at the edge of the screen where the
platform stops the cursor: a look that must keep turning forever needs the cursor recentred, and
nothing here can do that yet.

## controls-can-be-taken

The camera's hand on the window can be taken away: three.controls.enabled = false stops the mouse
orbiting, panning and zooming, and is what a scene that drives its own camera every frame needs —
otherwise the turntable writes yaw and pitch again underneath it and the two fight over one matrix
sixty times a second. It does not stop three.camera.orbit(), which is a script moving the camera on
purpose. Turn it back on when the mode ends: a window nobody can move the camera in is a bad way to
leave one, and there is no gesture that undoes it.

## pointer-is-in-image-pixels

three.input.pointer and the click are in the rendered image's pixels, not the window's. The window
shows the image stretched to fit it, so the two differ on a retina display and after any resize;
scene.pick(x, y) and the PNG use the same pixels the click does, whatever size the window is.

## physics-world

There is a physics world PER SCENE, which Three.js has no equivalent of at all: object.body = {
shape, mass } describes a body and three.physics.add(object) gives the object one. scene.physics is
the world that belongs to a scene and three.physics is whichever scene is being rendered — so the
next level's bodies can be built while the current one is on screen, and they stand still until you
activate it, because the frame steps one world. It is XPBD with real contacts, friction,
restitution, joints and triggers — not a demo. Y is down: three.physics.gravity is [0, -9.8, 0] and
there is no axis to configure.

## physics-steer-a-body

A dynamic body is steered with three.physics.setVelocity(object, [x, y, z]) and pushed with
three.physics.applyImpulse(object, [x, y, z]) — set a speed for a character, add an impulse for a
jump or a hit. Between them a dynamic capsule with a velocity set each frame is a character
controller: it walks and it collides, which no combination of the other verbs can do. Reading back
is three.physics.velocity(object). Static and kinematic bodies refuse both by name, because for
those the transform is the only thing that moves them.

## physics-owns-transform

The solver owns a dynamic body's transform, and writing to it throws. That is the one place in this
API where two writers are not resolved by last-writer-wins — a solver and a script writing the same
transform every frame produce jitter rather than a compromise. Give the body kind 'kinematic' to
drive it from a script, or three.physics.remove(object) to take the body away. A body with mass 0 is
static and is not owned, because it never moves.

## physics-fixed-60hz

Physics runs at a fixed 60 Hz whatever rate frames arrive at, and the accumulator is the host's
rather than the animation callback's — so a slow frame stutters instead of spending the script
budget and stopping the callback for good. A frame that ran very long catches up at most five steps
and drops the rest, which is the difference between a stutter and a spiral. What it steps by is GAME
time, so three.clock.timeScale scales the world and 0 stops it falling; three.clock.fixedRate is the
gameplay rate and does not touch the solver's.

## collider-from-mesh

A collider comes from the mesh, not from numbers you supply: 'box' and 'sphere' are its own bounds,
'capsule' is the bounds about Y, 'heightfield' is a TerrainGeometry's own grid of heights — one
shape for a whole landscape, at any slope, where the alternative is a chain of invisible boxes and a
path forced flat to have them — and 'hull' is the convex hull of its points — which is the same
collision::quickhull that built a ConvexGeometry, so a convex rock's collider is exactly its own
geometry rather than an approximation of it.

## export-round-trips

The scene comes back OUT with scene.export(path, options) — a .glb with one mesh per unique
geometry, so what the file says about sharing is what the frame says. Round-trips: export it,
three.load it, and the draw-call count is the same, per-copy colours included. Sibling copies of one
shape are written as a single node carrying an array of transforms (EXT_mesh_gpu_instancing, which
any glTF reader can place) with a `_COLOR_0` array beside them holding each copy's mesh.color; a
reader that does not know `_COLOR_0` gets them in the material's own colour rather than in the wrong
place. A copy with no sibling drawing the same shape keeps its name and its own material instead,
which costs no draw call, and groups are never collapsed. Siblings that share a shape but not a
material do not batch either — a colour travels per copy in `_COLOR_0`, a texture or a blend mode has
no per-copy channel — so they come back as the two draws they were. Two things are left out on
purpose — helpers and hidden subtrees, because the export is what the frame shows, and
ShaderMaterials, because a material here is a Slang pipeline and glTF describes surfaces rather than
programs — unless you pass { bake: true }, which runs each shader body over its mesh's uv layout and
writes the answer as a baseColorTexture or a baseColorFactor, and is the difference between a file
that is your scene and a file that is your scene in one grey.

## static-casters

A shadow pass rasterises every caster every frame, which for a village is the largest thing in the
frame. Say object.static = true on whatever will not move again — buildings, ground, walls, scenery
— and those are drawn into the shadow map once and kept; each frame after that draws only what
moved. It costs no draw call in the colour pass, so marking ten thousand crates is free, and moving
one afterwards is safe (the map is rebuilt) rather than wrong. scene.traverse(o => o.static = true)
is the usual way to say it. Watch three.stats().shadowStaticDraws: 0 on most frames means the cache
is holding. Refused on skinned meshes — a pose changes the silhouette without the transform moving —
and reading .static back is how you see that.
