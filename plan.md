# three.c3 — what is left

**A task list, and nothing else.** How a mechanism works, why a decision went the
way it did, and what has already cost somebody a session are all in `notes.md`.

**An entry leaves this file the moment it stops being work somebody has to do** —
into `notes.md` if it explains something, into `git log -p -- plan.md` if it does
not. That deletion is a habit, not a one-off event, and it is the only thing
keeping this file short enough to read in one sitting.

---

## 1. Platform defects

Two of these want a machine this repo has never had and will stay open until
somebody has one. The third wants ten minutes with a mouse.

- [ ] **Run the win32 backend.** It type-checks and has not had a window on
      screen since any of the mouse, cursor and DPI work. Compiling catches a
      missing symbol and none of the faults that matter — a wrong sign, an event
      that never arrives, a DPI declaration fighting something else.
- [ ] **Handle `WM_DPICHANGED`** (win32). A window dragged between displays of
      different densities keeps the size it was given.
- [ ] **Finish the Linux hand-check.** Both backends have now been run with a
      window on screen, and `tools/linux_input_check.js` is the harness that did
      it: the size, the wake, the wheel and its horizontal half, the left and
      middle latches and the x11 pointer lock all work. Three things it has not
      confirmed, because a desktop keeps stealing synthetic clicks from the tool
      that sends them — **the right-button latch**, `mouse4`/`mouse5`, and
      whether a Wayland compositor actually *grants* the lock, which it only does
      for a surface that holds pointer focus. The request reaches it: both
      globals bind and both objects are created.
- [ ] **Pointer lock in the browser.** `wasm/main.c3` reports it absent too. The
      browser has the best version of it — `requestPointerLock` and
      `movementX`/`movementY` straight out of the platform — but the request must
      come from a user gesture and resolves through an event, so it is a change
      to `wasm/bridge.c3` and the JavaScript beside it rather than a function in
      the backend.

## 3. Skinning

Crossfading, morph targets and sockets are built. What they left open:

- [ ] **A glTF node with several primitives only morphs its first.** Each
      primitive became its own scene node and only one of them carries the glTF
      index a WEIGHTS channel names. A face is one primitive in every file that
      exists; a face split across two materials is where this shows.
- [ ] **Nothing exercises a morph and a skin on one mesh.** The order is written
      into all four shaders and into `write_morph_weights`, and no fixture has
      both — so the property that a rigged face morphs *then* poses is argued for
      and not measured. It wants a fixture, not a design.
- [ ] **Re-run the compute→vertex barrier injection on a machine with a fuller
      validation layer.** Deleting that barrier left the suite green here, under
      the ordinary layer and under synchronization validation both. The check that
      measured it is gone — this machine's loader refuses
      `VK_EXT_validation_features`, so it failed for the machine rather than for
      the code — which means the suite no longer asks the question at all, and
      re-running it somewhere else starts by writing the check back.

## 5. UI and text

- [ ] **A scene has no way to say which keys it binds.** Seven keys bound to a
      character had to be delivered in a chat message. Smallest possible version
      of this section, and already missed — the interface can display the list
      now, so what is left is a scene API for declaring it.
- [ ] **A texture in the interface.** `RectStyle.texture` is one field away, and
      the handle question is what blocks it: `CanvasPass` samplers are a
      different table from `pass.assets`, so a scene texture cannot be named
      across. `UI.md` §9.
- [ ] **Styling stops at a theme.** Six colours and two text fields cross per
      node, layered over each widget's own default. Enough to restyle, not enough
      to reproduce a design. One field per knob to widen. `UI.md` §9.

## 6. Audio, saving, and the rest

- [ ] **Audio.** A new dependency and a new thread. `three.sound(path)`, `play`,
      `stop`, volume; positional audio is a cheap addition to `tick`. The
      dependency worth trying first is **miniaudio** — one public-domain header
      carrying CoreAudio, WASAPI and ALSA/PulseAudio, with WAV, MP3 and FLAC
      decoding already in it — built as a `lib/audio.c3l` the way `quickjs.c3l`
      builds its archive per target. `stb_vorbis` beside it if `.ogg` is wanted.
- [ ] **Timers, `structuredClone`,** and whatever else a real game hits.

## 7. Physics — bindings that do not exist

- [ ] **`snapshot`/`restore`.** `solver/lockstep.c3:125` — "what if" as a tool
      call, and what lockstep networking would need.

## 9. Open questions

Cheap to decide, expensive to discover.

- [ ] **What `main.js` and `run_script` share.** They share globals by design, so
      what happens when an agent's script redefines something the game holds a
      reference to? Probably nothing good and probably acceptable — but a known
      answer rather than a discovered one. **No longer gates §8**: a reload is a
      new context, so the hazard is not on that path.

## 11. Verification

- [ ] **The physics world is deterministic.** Two worlds given the same inputs
      produce the same `state_hash` after N steps, and a `snapshot`/`restore`
      round trip reproduces it. The library supplies the mechanism; the binding is
      what could break it, by stepping at a rate that depends on the frame.
- [ ] **Move `test/resize_test.c3` into `lib/window.c3l`.** Its `@test` is
      commented out here, so the swapchain resize path is covered by nothing.

## 13. The pass system

What the chain does not cover, roughly in the order it would grow:

- [ ] **Downsampled intermediates.** A bloom pyramid at ½, ¼, ⅛ means per-pass
      extents, so P0/P1 become a pool keyed by extent. The piece that grows first.
- [ ] **A second `reads` tap per pass**, or a pass fanning out to two consumers.
- [ ] **MRT** — a pass writing two attachments.
- [ ] **Normals and motion vectors in a post body.** Depth is built.
- [ ] **IBL bake**, on `texture.c3`'s one-shot path. `hostImageCopy` lands here.
- [ ] **Fuse the pointwise passes** into one local read, measured against the
      chain rather than assumed. The first step whose value is a number and not a
      shape.

**Trigger for a render graph:** script-authored *edges* — a script naming which
pass's output another pass reads, where the answer is not its predecessor. Pass
count is not the trigger and never was.

## 15. The draw buffer

- [ ] **`vkCmdDrawIndexedIndirect`. Trigger:** a consolidated geometry arena and
      bindless textures. Until both, an indirect draw is the same commands plus a
      buffer read, minus the validation layer's ability to check the arguments.
      GPU culling wants the same two first.

## 16. Export

- [ ] **Lines do not export.** Two structural changes for the least valuable of
      the six; `mode: LINES` is waiting in the writer.
- [ ] **A morph animation does not export.** Rigs, clips and blend shapes go out;
      a WEIGHTS channel does not, because it drives a mesh through the node the
      mesh hangs on and that node is not a joint in any skeleton's map. What each
      copy's weights *are* is in the file — the curve that would move them is not.
- [ ] **A reloaded copy does not get the file's morph weights back.**
      `MorphWeights` seeds every copy to zero whatever the file said, so a `.glb`
      written with `node.weights` reads back at rest. The parser now reads them —
      `Node.weights` — so what is left is `instantiate` applying them.

## 17. Gameplay

**Everything here but the three below was built.** What each of them settled, and
what it measured, is `notes.md` §17; the ordering argument that used to head this
section went with them, because the order was the argument and it has been
followed.

- [ ] **Clip events**: a sorted time list per clip compared against the player's
      clock, fired into a JS callback. Cheap on both paths. The blending it was
      bundled with is built — §3.
- [ ] **Inverse kinematics.** `collision::ik::solve_chain`
      (`lib/collision.c3l/src/ik.c3`) exists with a `shortest_arc` beside it and
      nothing in `src/` calls either. Live skinning already lets a script write a
      bone, so foot planting, a look-at and a weapon aim are a binding away.
- [ ] GPU Particles


## 19. Shadows at game scale

- [ ] **The instance array is written twice.** `build_draw_list` fills a
      `List{Instance}` (~635 KB on the village) that only `write_instances` reads,
      which then `mem::copy`s the whole of it into the mapped buffer. The count is
      known before the coalescing loop, so the loop could write straight into the
      slot's buffer the way `write_live_poses` and `build_draw_records` already
      do. The last of §19.5's five and the cheapest thing on this list.
- [ ] **A shadow atlas and a casting budget.** One depth image, tiles allocated
      per light by screen-space importance; "four casters this frame" rather than
      a per-light bool; cascades for the sun become atlas tiles like everything
      else. **Do it when the second casting light arrives**, and before point
      lights — a cubemap is six fits and six passes, and the atlas makes that a
      tiling question rather than an allocation question.
- [ ] **Forward+ (clustered forward).** A compute pass bins lights into
      screen-space clusters, the frame block carries the grid, `lambert` loops the
      cluster's list, and **not one material body has to change**. **Trigger:** the
      fifth light. The shading side is not what is hurting.
- [ ] **Revisit `SHADOW_PLAN_STATIC` on a device where the full-image copy is not
      free.** Two lines in `MeshPass.plan_shadow`; `notes.md` §19.3 has the
      numbers to beat and why the measurement came out backwards here.

**Not doing:** the depth prepass (measured — pay 0.59 ms to save at most 0.23),
and deferred shading (it breaks the material contract). Both are in `notes.md`
so that the next person to have the idea finds the measurement rather than the
argument.

## 20. Authoring a level

All four items are built. What they left open:

- [ ] **`Heightmap.furthest_point` still returns the four corners of the map.**
      Harmless now that the dispatch never sends a heightfield to GJK, and wrong
      the moment anything else calls it.
- [ ] **A heightfield is finite, so a body that slides off the edge falls.**
      Honest, and undocumented anywhere a script can see it.
- [ ] **The large bucket's threshold of 64 cells is a guess with an argument
      rather than a measurement.**

---

## 21. Systems and a cast

**Built.** `notes.md` §21 has the shape, the three decisions it forced and what
the example it was measured against looked like before and after.

- [ ] **`three.systems.report()` has no way to reach a HUD.** It is the CPU half
      of `three.stats()` and there is nowhere to draw either — §5's text work is
      what unblocks it, and until then the numbers reach a person through
      `console.log` and a probe.

---

## 22. Shipping a game

What a bundle needs that a viewer does not. Most of it is built: the cache no
longer follows the launcher around, a game names itself and its save folder
through `three.configure`, the window can be titled and made fullscreen, the
picture follows the window, and saves have a directory of their own —
`test/shipping_test.c3` is the whole of it in one file. Audio is §6. Steamworks
and macOS notarisation are deliberately absent: neither can be done from this
repo.

- [ ] **No gamepad.** Steam Input presents every controller as XInput or evdev,
      so this is the whole of controller support without Steamworks:
      `XInputGetState`, `/dev/input/js*`, and GameController on macOS. Shape it
      like `three.input` — `three.gamepad(0)`, buttons by name, axes as floats.
- [ ] **The fullscreen and title backends have only been run on macOS.** The
      other three compile — `c3c build test-win` in `lib/window.c3l` links a
      Windows binary and `--target linux-x64` type-checks both Linux backends —
      and compiling is what §1 already says is not enough. What is unverified is
      four calls: `SetWindowTextW` and the borderless `WS_POPUP` swap,
      `_NET_WM_NAME` and the `_NET_WM_STATE` message, and Wayland's two
      `xdg_toplevel` requests.
- [ ] **A save is bytes and text and nothing else.** No `three.save` verb moves
      a file *into* the folder from elsewhere, which is what importing a save
      would want. Leave it until somebody asks; the shape would be a path
      argument, and a path argument is the thing this whole file refuses.

---

## 23. Authoring a kit

A kit is a `.glb` of named pieces a scene script places on a grid, and
`asset.node(name)` is the door onto it. None of the five below breaks the thesis:
a script still describes shapes and never touches a vertex. Smallest first.

- [ ] **A failed load names the path the script asked for, not the path it looked for.**
      Under `--assets` a leading `/` roots into the assets directory, so
      `three.load("/home/tonis/Documents/runescape/kit/buildings.glb")` searches
      `<assets>/home/tonis/...` and then reports `could not load
      /home/tonis/Documents/runescape/kit/buildings.glb: gltf::FILE_NOT_FOUND` — naming a
      file that is on disk, readable, and exactly where the sentence says it is. Whoever
      reads that error checks the file, finds it, and has learned nothing. Everything
      needed to say the true thing is in hand at the throw site: the root, the path as
      written, and the path as resolved. Four doors resolve this way, not one —
      `three.load`, `three.readText`, `three.texture` and a `fileBrowser`'s start
      folder — so the sentence is built once, beside `resolve_asset`, and the four
      say the same thing rather than each drifting on its own. The rooting rule is
      right; only the sentence is wrong.
- [ ] **`BoxGeometry` and `ConvexGeometry` disagree about uvs.** A hull maps one
      uv unit per unit of local space; every parametric shape maps 0..1 per face.
      Two pieces of one roof — a slope that is a box, a hip that is a hull — then
      need different `material.repeat` to wear one texture at one size, which is
      how a 34-piece kit came to ship 29 materials and a `mat(texture, u, v)`
      cache to build them, with the thin edge of every wall panel stretched
      anyway. A `{ uv: 'local' }` mode is two multiplications where
      `primitive.c3:434` already holds the face's own `u_length` and `v_length`.
      Not `'world'`: a geometry cannot see the scale of the mesh that draws it,
      so the unit is the geometry's own, and the name says so before a scaled
      piece proves it. On a hull the mode is what a hull already does, and the
      doc says that too, so nobody waits for a change that is not coming. The
      mode has to travel in `parameters`: two geometries with the same numbers
      are one asset, so a global would collide a face-mapped box with a
      local-mapped one of the same size. `repeat` then means texels per unit
      and one material serves every piece. Keep `'face'` the default — it is
      Three.js's layout and every existing script reads it.
- [ ] **Snapping stops working where the mating surface is not a face of the box.**
      Two roof slopes meeting along a pitch overlap by the slab's thickness, so
      snapping their boxes is wrong by it, and the pitch cannot be recovered from
      bounds either — a 0.7 rise reads back as 0.798 over 1.069 with the thickness
      and the overhang mixed in. What a kit wants here is what a Blender kit
      already ships: **empty marker nodes** for connection points. glTF carries
      them as nodes with no mesh, `instantiate` already builds them as plain
      `Object3D`s and `node(name)` already finds them. `snapTo` has the slot for
      one — the side argument — so `slope.snapTo(other, 'ridge')`, both pieces
      carrying a node of that name, reads the way the six faces do. What decides
      whether this is a doc or a feature: a marker carries an orientation, a
      pitch is a rotation problem, and `snapTo` never rotates. Either a marker
      snap turns the piece until the two markers' frames coincide, or it moves
      only and the script sets the rotation first, as it does today. Decide
      before a piece is authored that needs one. And `inventory()` lists the
      markers with their positions, so the agent placing a kit sees them before
      it loads anything.
- [ ] **A shape cannot have a hole in it.** A wall with a window is four boxes,
      with coincident faces where they meet that nothing will ever see, and a
      `merge` only glues those into one mesh. Three.js's answer is
      `ExtrudeGeometry` over a `Shape` with `holes`: a 2D outline, the holes
      cut out of it, swept to a depth — one closed mesh with no interior faces.
      It is the piece a kit is mostly made of. The outline is data rather than
      numbers, which is what a hull's points already are, so `parameters`
      carries a count and the shape travels beside it as the hull's does.
- [ ] **There is no `merge`, only `split`.** Ten buildings out of one kit are
      2,463 nodes, because every piece is a hierarchy of boxes rather than a
      mesh. `MeshRef.split()` already reads geometry back on the host and
      uploads an asset per piece; `three.merge([...]) → Geometry` is that path
      in reverse and is what lets a piece *be* a mesh. Merge is concatenation
      and nothing cleverer: transforms are baked into the vertices, the result
      carries data rather than parameters the way `TerrainGeometry` already
      does, and pieces of differing materials are refused rather than flattened
      onto one — the interior faces the entry above removes are still there
      after a merge, only in one mesh. The largest of these and the one that
      most changes what a kit costs.

---

## 24. An editor

**A script, not a C3 program.** Placing a kit by hand is picking, a panel and a
file, and the JavaScript surface already has all three — a second editor written
in C3 would be a second UI stack over a second copy of the scene model, to reach
verbs a script can already call. It runs the way a game does, under `--assets`,
and `three.reload()` is its edit loop.

**What it already stands on**, so that none of it gets built twice: `scene.pick(x, y)`
answers what is under a pixel — the object and the world normal of the face under
the cursor — and `scene.raycast(origin, direction)` what a ray hits;
`three.input.pointer` is the mouse for the frame, position, click edge, held
buttons, deltas and wheel, and `three.input.isDown(key)` is the held key; `snapTo`,
`alignTo`, `row` and `boundsInParent` are the placement verbs; `three.ui.set` has
`button`, `checkbox`, `slider`, `select`, `tree`, `textfield`, `menu`, `dialog`,
`confirmDialog` and `fileBrowser` with handlers, which is a properties panel, a
file menu and an asset browser already; `three.inventory()` lists the `.glb`s
under the assets directory with their nodes and bounds, and `asset.nodes` plus
`node(name)` open one of them piece by piece; `BoxHelper` and `GridHelper` draw a
selection box and a ground grid over the frame; `three.save` reads and writes
JSON; and `scene.export(path)` publishes what was placed. Undo is an array in the
script.

- [ ] **A level can now be read beside its kit but not written there.** `three.readText`
      answers text out of the assets directory, and `scene.export` already writes a `.glb`
      into it through `resolve_write` — so what is missing between them is text going the
      other way. Until it exists an editor reads its placement list from the repo and has
      to save it to `<application data>/three.c3/<name>/`, which is precisely the split the
      read door was opened to close, and a save button that lands somewhere the user cannot
      commit is not a save button. A text twin of `scene.export`: one verb, the
      `resolve_write` sandbox that is already there, no new rule.
- [ ] **Four widgets the editor needs are not in the docs.** The prelude and the
      host know `menu`, `dialog`, `confirmDialog` and `fileBrowser`; the entry for
      `three.ui.set` lists six interactive kinds and stops. An agent building the
      editor from `get_api_docs` never finds the file menu, the save-as dialog,
      the delete confirmation or the kit chooser, and builds worse ones out of
      `button`s. Four entries in `functions.md`, each saying what its handler is
      told, before the first consumer of them is written.
- [ ] **The level is a list of placements, and a row remembers how it was placed.**
      A `.glb` bakes the geometry in, so re-exporting the kit does not update a
      level made from it, and the link back to the piece a placement *is* is
      gone. A list — a piece and a transform per row — is diffable, greppable
      and writable by an agent, which is the point: the same file is what an
      agent generates and what a person then adjusts by hand, and it is the
      only place those two meet. But a transform alone bakes the placement the
      way the `.glb` baked the geometry, one level up: re-export the kit with a
      taller wall and the storey above it stays where it was. So a row placed by
      a snap also carries the snap — the target row, the side, the axes — and a
      re-fit replays those rows in order against the kit as it is now, while a
      plain load takes the transforms as written and asks nothing. A freehand
      row carries no snap and never moves. JSON, read through `three.readText`
      and written through the door above; and the loader that replays a list
      into a scene is part of this entry, since a list exists only once
      something reads it. `scene.export` stays what turns a finished one into a
      file anybody else can open.
- [ ] **The editor itself.** Select, move, rotate in quarter turns, delete,
      duplicate, an asset browser off `inventory()` and `asset.nodes`, undo,
      load and save of the list above, and a camera — `camera.orbit` is a
      setter, so orbit, pan and zoom out of the pointer's deltas and wheel are
      built here. Placing is where its accuracy comes from, and a kit dropped
      freehand is wrong in a way that shows at every join — a gap where two
      walls meet, a z-fighting overlap where they meet too well, a roof course
      half a tile off its eave — so three snaps, in the order they earn their
      place. **Grid**: every piece's footprint is a whole number of tiles, so a
      placement is an integer cell, a quarter turn and a storey, and that alone
      covers a wall run, a floor and a fence line; `three.query.box` tells the
      dropped piece what it touches. **Face**: the pick already holds the
      neighbour and the world normal of the face under the cursor, the normal's
      dominant axis is the side, and `snapTo(hit.object, side)` is the whole
      snap — the two axes it does not name stay where the cursor put them, which
      is what that rule is for. **Marker**: the joins a box cannot express, which
      is §23's marker entry and what two roof slopes meeting along a pitch need.
      All three want a *preview* before they commit — a ghost where the drop
      would land, because a snap that has already happened is one you have to
      undo to disagree with. A `BoxHelper` at the drop point is the cheap ghost:
      free, drawn on top, not pickable. A translucent copy of the piece is the
      dear one and wants a material built transparent up front, since `opacity`
      does nothing on an opaque pipeline. And a held key places freehand anyway,
      because the exception always turns up. The scripts that placed this kit
      by hand hit precisely the errors snapping removes: a lean-to turned so its
      roof rose away from the wall it leaned on, a wall built twice where two
      wings shared a tile edge, and a verge nudged 0.06 by hand to stop it
      fighting the roof under it.

---

## Standing constraints

Neither of these is a task. They are the two things a task is allowed to break
only by saying so out loud.

**The thesis.** A script describes shapes and never touches a vertex, and every
copy of one shape sharing one material is one draw call. Two named channels vary
per copy — `color` and `variant` — and nothing else. When a milestone cannot hold
that, it says so and argues for the exception; it does not just stop being true.

**No default gets invented from one scene.** `shadow.size` has no default because
the village wants 2048 for being wide and flat and a room wants a different
number that nobody has measured. The right time to give a knob a default is when
the answer stops depending on how big the level is.
