# three.c3 — what is left

**A task list, and nothing else.** How a mechanism works, why a decision went the
way it did, and what has already cost somebody a session are all in `notes.md`.

**An entry leaves this file the moment it stops being work somebody has to do** —
into `notes.md` if it explains something, into `git log -p -- plan.md` if it does
not. That deletion is a habit, not a one-off event, and it is the only thing
keeping this file short enough to read in one sitting.

**Section numbers are load-bearing.** Fifty-odd source comments cite them — §4's
half-match rule, §12's specular decision, §15's draw record — so a number stays
even when one line is left under it. **`notes.md` uses the same numbers**, so a
citation to §N resolves against whichever of the two files still has material
under it; a section missing from *this* file has no work left in it.

---

## 1. Platform defects

All three want a machine this repo has never had, and will stay open until
somebody has one.

- [ ] **Run the Linux and Windows backends.** Both type-check; neither has had a
      window on screen since any of the mouse, cursor and DPI work. Compiling
      catches a missing symbol and none of the faults that matter — a wrong sign,
      an event that never arrives, a DPI declaration fighting something else.
      `get_scroll_x` and the right/middle latches are the newest blind surface.
- [ ] **Handle `WM_DPICHANGED`** (win32). A window dragged between displays of
      different densities keeps the size it was given.
- [ ] **`Window.width`/`height` go stale on Linux.** x11 and wayland need their
      own `GetClientRect` equivalent. **Do this with pointer lock**, not before —
      the live-resize delta is the half that hurts, and `notes.md` §10 has why
      fixing the delta instead is the wrong move.

## 2. Deferred by design

- [ ] **A material nobody disposes is immortal**, exactly as a texture nobody
      disposes is. `material.dispose()` exists; a script that never calls it
      accumulates one pipeline per distinct shader source. **Trigger:** evidence
      that scripts in practice do not dispose — and the answer is then probably a
      warning naming the count, not a `FinalizationRegistry`.
- [ ] **A stale asset handle is refused at `add()`, not at `new three.Mesh()`.**
      Documented rather than hidden; not a task unless somebody finds it
      confusing in practice.

## 3. Skinning

- [ ] **Blending / crossfade between clips.** §17 has the two answers — ordinary
      work on the live path, a shader change with a named lie on the baked one.
- [ ] **Morph targets.**
- [ ] **Sockets.** A bone's world transform is `pose * bind` and `AssetSkin.bind`
      is kept for it; nothing reads it yet.
- [ ] **Re-run the compute→vertex barrier injection on a machine with a fuller
      validation layer.** Deleting that barrier leaves the suite green here, under
      the ordinary layer and under synchronization validation both.

## 4. Textures, async load, and a sky

- [ ] **KTX2 decode — do this first and out of order.** `image.c3l` does PNG and
      JPEG only, so **every shipped `.glb` using `KHR_texture_basisu` loads with
      its textures missing** (`src/scene/asset.c3:2039`). Small, self-contained,
      independent of the sky, and it changes this section's value from "skyboxes"
      to "shipped assets work".
- [ ] **`test/ktx_test.c3` does not exist.** `ktx` is in `project.json` and
      imported by nobody.
- [ ] **`asset.imageAt(i)`.** A `.glb` mesh carries its texture on the `GpuMesh`
      and exposes no `Texture` handle, so `texture.read()` has nothing to be
      called on for it.
- [ ] **Async `asset.mesh(...)` / `asset.instantiate()`** — per mesh, not per
      file. The promise resolves from the job queue `drain_frame_jobs` already
      drains.
- [ ] **The sky.** A cubemap or an equirect, a pipeline drawing at far depth with
      depth-write off, and an environment term if it is to light anything.

## 5. UI and text

- [ ] **The whole of it.** There is a UI rendering library to bind rather than
      write; `notes.md` §5 has the three decisions that decide whether the
      binding is pleasant, and they are made.
- [ ] **The consume flag is the hard part.** A click on a button must not also
      shoot the gun, and `three.controls.enabled` does not answer it.
      `MouseTracker`'s edge machinery in `scene/input.c3` is where it belongs.
- [ ] **A scene has no way to say which keys it binds.** Seven keys bound to a
      character had to be delivered in a chat message. Smallest possible version
      of this section, and already missed.

## 6. Audio, saving, and the rest

- [ ] **Audio.** A new dependency and a new thread. `three.sound(path)`, `play`,
      `stop`, volume; positional audio is a cheap addition to `tick`.
- [ ] **Saving.** A write verb confined to a single state directory — never the
      assets root, never an arbitrary path. **The one place in this plan where the
      sandbox widens on purpose**, so say it in the doc comment.
- [ ] **A seeded RNG.** Twenty lines, and it is the difference between a replay
      that works and one that nearly does: `state_hash` proves determinism that
      one `Math.random()` throws away.
- [ ] **Timers, `structuredClone`,** and whatever else a real game hits.

## 7. Physics — bindings that do not exist

- [ ] **A character controller.** Ingredients are all in `collision.c3l` — swept
      CCD, GJK/EPA, a capsule, `Physics.transformed`. Sweep, slide along the
      contact normal, step up ledges under a threshold, report `grounded`, the
      slope and what was hit. Otherwise every game rewrites the same 120 lines in
      JavaScript at 60 Hz.
- [ ] **Joints from a script.** `add_constraint` (`solver/resolver.c3:441`) and
      `GenericJoint3D` exist; there is no `three.physics.joint(...)`.
- [ ] **`snapshot`/`restore`.** `solver/lockstep.c3:125` — "what if" as a tool
      call, and what lockstep networking would need.
- [ ] **Soft bodies.** The library has them; nothing binds them.

## 8. Hot reload

- [ ] **Re-evaluate `main.js` on a file change.** Small, and unlocked by
      unloading. Combined with `--mcp` it means an agent edits a `.js`, the game
      reloads, and the screenshot shows the result. **Gated on §9** — do not land
      it before the semantics are decided.

## 9. Open questions

Cheap to decide, expensive to discover. Both gate §8.

- [ ] **Hot reload semantics.** What happens to a running `setAnimationLoop`, to
      live physics bodies, to the camera.
- [ ] **What `main.js` and `run_script` share.** They share globals by design, so
      what happens when an agent's script redefines something the game holds a
      reference to? Probably nothing good and probably acceptable — but a known
      answer rather than a discovered one.

## 11. Verification

- [ ] **The physics world is deterministic.** Two worlds given the same inputs
      produce the same `state_hash` after N steps, and a `snapshot`/`restore`
      round trip reproduces it. The library supplies the mechanism; the binding is
      what could break it, by stepping at a rate that depends on the frame.
- [ ] **Move `test/resize_test.c3` into `lib/window.c3l`.** Its `@test` is
      commented out here, so the swapchain resize path is covered by nothing.

## 12. Lighting

- [ ] **A second light, or a list.**
- [ ] **A colour per light rather than white.**
- [ ] **A specular term.** **This is the gate on roughness and metalness
      everywhere** — §4's maps, §14's PBR fields, §16's export. Do not add a
      roughness field anywhere before the term that reads it exists, or it is a
      material property that provably changes no pixel.
- [ ] **The exporter writes no light.** One directional light and an ambient
      floor map onto a glTF `directional` light and nothing else.

## 13. The pass system

What the chain does not cover, roughly in the order it would grow:

- [ ] **Downsampled intermediates.** A bloom pyramid at ½, ¼, ⅛ means per-pass
      extents, so P0/P1 become a pool keyed by extent. The piece that grows first.
- [ ] **A second `reads` tap per pass**, or a pass fanning out to two consumers.
- [ ] **MRT** — a pass writing two attachments.
- [ ] **Normals and motion vectors in a post body.** Depth is built.
- [ ] **The material unit.** The actual PBR work — §2's blocker, and it touches
      nothing above it. Separable from the pass work; only the format rule sits
      across both.
- [ ] **IBL bake**, on `texture.c3`'s one-shot path. `hostImageCopy` lands here.
- [ ] **Fuse the pointwise passes** into one local read, measured against the
      chain rather than assumed. The first step whose value is a number and not a
      shape.

**Trigger for a render graph:** script-authored *edges* — a script naming which
pass's output another pass reads, where the answer is not its predecessor. Pass
count is not the trigger and never was.

## 14. Material layers

- [ ] **Parallax**, from the height data the extension already carries and the
      importer already drops. `heightTexture` and `bump` are refused by name.
- [ ] **The PBR half is §12's.** `metalness`, `roughness`,
      `metallicRoughnessTexture` and `subsurface` are parsed, dropped at the
      importer and refused at the JS boundary. When the specular term exists,
      `GpuLayer` in `scene/asset.c3` is where they go back in and the refusals in
      `js/prelude/layers.js` are what get deleted.

## 15. The draw buffer

- [ ] **`vkCmdDrawIndexedIndirect`. Trigger:** a consolidated geometry arena and
      bindless textures. Until both, an indirect draw is the same commands plus a
      buffer read, minus the validation layer's ability to check the arguments.
      GPU culling wants the same two first.

## 16. Export

- [ ] **Lines do not export.** Two structural changes for the least valuable of
      the six; `mode: LINES` is waiting in the writer.

## 17. Gameplay

**Order, and what it is gated on.** The numbering is kept with the struck entry
in place, because the order was an argument and renumbering would quietly claim
the argument was different.

1. **Pointer lock**, with §1's live-resize delta.
2. ~~The clock~~ — built.
3. **The character controller**, then **animation blending**.
4. **Navigation**, then the **queries** and **steering** that make it a crowd.

- [ ] **Pointer lock. It is not a binding.** A look that keeps turning needs the
      cursor recentred and hidden every frame, and `window.c3l` exposes no cursor
      warp and no associate-mouse call on any of its four backends:
      `CGWarpMouseCursorPosition` / `CGAssociateMouseAndCursorPosition` on darwin,
      `XWarpPointer` or pointer-constraints on linux, `SetCursorPos`/`ClipCursor`
      on win32. Window-library work first, a binding afterwards.
- [ ] **A camera that rolls.** `camera.attach`'s offset is added in world space,
      which is right for a head and a shoulder camera and cannot express a cockpit
      or a turret. One 3×3 multiply and a flag — except that a rolled camera also
      wants the view's up vector to roll, and `Camera.view` hardcodes +Y.
      **Trigger:** the first vehicle.
- [ ] **The character controller** — §7 has it.
- [ ] **Animation blending**, and **clip events** with it: a sorted time list per
      clip compared against the player's clock, fired into a JS callback. Cheap on
      both paths.
- [ ] **Navigation.** Both halves have their inputs in the repo already: every
      uploaded mesh keeps `hull_positions`, `hull_triangles` and a `TriBVHNode`
      (`scene/asset.c3:230`), and `lib/collision.c3l/src/voxel.c3` is a written,
      unimported distance-field solver — `solve_field`, `sample`,
      `nearest_solved`, and a multi-source `solve_sources` / `nearest_sourced` /
      `sample_sources` that is a crowd flow field by another name. Nothing in
      `src/` imports it. The one piece genuinely missing is the
      *complement*: `create_voxel_grid` voxelizes the **inside** of a closed mesh
      and navigation wants free space above a floor.
      **Two verbs, not one, and the split is the whole design** — `nav.path(from,
      to)` for one agent, `nav.field(goals)` returning a handle a script samples
      per agent. An API that only offers `path()` guarantees somebody writes the
      second one badly. Shorten the extracted path against the BVH: a game that
      walks cell centres looks like it is walking cell centres.
      **Measure the bake cost first** at a 0.5 m cell over a 100 m town — that
      number decides whether this is a level-boundary operation or a
      loading-screen one.
- [ ] **Bulk spatial queries.** `overlapSphere(p, r)`, `queryBox(box)`,
      `raycastAll`, `sweep(shape, from, to)` over the `SpatialHash3D` that already
      exists, each returning node ids into a caller-owned typed array.
      **This pays for two entries**: `Scene.raycast` (`scene/pick.c3:63`) walks
      every node in the scene at 42 ns each before it reaches any BVH, so a
      hundred agents casting one ground ray apiece is 2.1 ms in a 500-node demo.
- [ ] **Steering** — seek, arrive, separation, or RVO if avoidance has to be real.
      Arrives with navigation and is pointless without it.
- [ ] **Inverse kinematics.** `collision::ik::solve_chain`
      (`lib/collision.c3l/src/ik.c3`) exists with a `shortest_arc` beside it and
      nothing in `src/` calls either. Live skinning already lets a script write a
      bone, so foot planting, a look-at and a weapon aim are a binding away.
- [ ] **Curves and damping** — Catmull-Rom, and `damp`/`smoothDamp` with the
      frame-rate-independent exponential. **In `math.js`, not in C3**: they are
      arithmetic on a handful of numbers and crossing for them would cost more
      than doing them.
- [ ] **Batched transforms.** A `Float32Array`-shaped bulk write is the right
      eventual shape and buys nothing anybody can see yet. **Trigger:** a scene
      moving more than about two thousand nodes a frame.

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
- [ ] **Delete the `size().length_sq() > 0.1` lower bound** in
      `spatial_hash.c3` whenever somebody is next in that file. A one-cell box
      costs one cell; there is nothing for a floor under it to protect.

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
