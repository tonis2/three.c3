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
      own `GetClientRect` equivalent. `notes.md` §10 has why fixing the
      live-resize delta instead is the wrong move.
- [ ] **Pointer lock on Linux.** Built on darwin and win32, and reported as
      absent on both Linux backends rather than faked — `three.input.pointerLock`
      reads back false there, which is the signal a script branches on. x11 wants
      `XDefineCursor` with a 1x1 transparent pixmap and `XWarpPointer` back to
      the centre, which is the same recentre darwin does and simpler because
      there is no local-event suppression to defeat. Wayland wants
      `zwp_pointer_constraints_v1` plus `zwp_relative_pointer_v1`, and that is a
      protocol binding rather than an x11 shortcut: a Wayland client cannot move
      the cursor at all, by design. `linux/xdg_shell.c3` is the shape a second
      one would take. Both are blind work until the entry above happens.
- [ ] **Pointer lock in the browser.** `wasm/main.c3` reports it absent too. The
      browser has the best version of it — `requestPointerLock` and
      `movementX`/`movementY` straight out of the platform — but the request must
      come from a user gesture and resolves through an event, so it is a change
      to `wasm/bridge.c3` and the JavaScript beside it rather than a function in
      the backend.

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
      **`material.metalness` is what wants this now**: a metal reflects and does
      not scatter, so with nothing around it to reflect it renders dark. The four
      punctual lights give it a highlight and nothing else.

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
- [ ] **Timers, `structuredClone`,** and whatever else a real game hits.

## 7. Physics — bindings that do not exist

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
- [ ] **A scene round-trips to zero.** Build one, `dispose()` it, call
      `three.unloadUnused()`, and assert `stats().scenes` is back to 1 and
      `stats().assets` to 0. Nothing covers this, and §23's leak is what it would
      have caught.

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
- [ ] **The PBR half is per material and not per layer.** `material.roughness`,
      `.metalness` and `.reflectance` exist and the specular term reads them; a
      *layer's* pair is still refused, and `subsurface` has no light transport
      behind it either way. Blending roughness per texel is a second set of maps
      and a second blend chain in the body `layers.js` generates — worth doing
      when something wants moss rougher than the stone under it.
- [ ] **The importer does not apply the file's `metallicFactor` and
      `roughnessFactor`.** `GpuMaterial` carries both and a script can read them,
      but `instantiate({ materials: true })` leaves them alone: glTF's defaults
      are 1 and 1, so a file that says nothing is a fully metallic surface, and a
      metal with no environment to reflect renders dark. Do this with §4's sky.

## 15. The draw buffer

- [ ] **`vkCmdDrawIndexedIndirect`. Trigger:** a consolidated geometry arena and
      bindless textures. Until both, an indirect draw is the same commands plus a
      buffer read, minus the validation layer's ability to check the arguments.
      GPU culling wants the same two first.

## 16. Export

- [ ] **Lines do not export.** Two structural changes for the least valuable of
      the six; `mode: LINES` is waiting in the writer.

## 17. Gameplay

**Everything here but the two below was built.** What each of them settled, and
what it measured, is `notes.md` §17; the ordering argument that used to head this
section went with them, because the order was the argument and it has been
followed.

- [ ] **Animation blending**, and **clip events** with it: a sorted time list per
      clip compared against the player's clock, fired into a JS callback. Cheap on
      both paths.
- [ ] **Inverse kinematics.** `collision::ik::solve_chain`
      (`lib/collision.c3l/src/ik.c3`) exists with a `shortest_arc` beside it and
      nothing in `src/` calls either. Live skinning already lets a script write a
      bone, so foot planting, a look-at and a weapon aim are a binding away.
      
- [ ] Give JS api a way to increase window size      


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
- [ ] **Say what `size` costs when it is set.** Two D32 images at `size` squared,
      `image` and `static_image` (`render/shadow.c3:310`, `:331`), so 2048 is
      34 MB, 4096 is 134 MB and 8192 is 536 MB — and the clamp is the only thing
      between a script and the last of those. The setter knows the format and
      that there are two of them. §23's memory block is where the number belongs.

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

## 21. Systems and a cast

**Built.** `notes.md` §21 has the shape, the three decisions it forced and what
the example it was measured against looked like before and after.

- [ ] **A second Cast in an example, to check the claim.** §21's own acceptance
      test was "adding a second kind of enemy is a second Cast and its own
      systems, and nothing else changes", and `examples/wumpa_run.js` now
      demonstrates one Cast rather than two — so the claim is argued rather than
      shown. A flying enemy would settle it, and it is the cheapest possible
      check of a design that is otherwise only reasoned about.
- [ ] **`three.systems.report()` has no way to reach a HUD.** It is the CPU half
      of `three.stats()` and there is nowhere to draw either — §5's text work is
      what unblocks it, and until then the numbers reach a person through
      `console.log` and a probe.

---

## 22. Kinds, assemble, and composing a game

**Built.** `three.kind`, `three.kindOf`, `three.assemble` and `Cast.of`;
`notes.md` §22 has how they work and what was decided. `examples/wumpa_run.js`
is converted and its header has the before/after.

- [ ] **An event/rules system — `three.on(a, verb, b, fn)` — still being
      designed.** The sketch and the honest answer to "who fires the events" are
      in the session that built §22 and are not settled enough to write down as
      a task. `three.kindOf(object)` exists because whatever it turns out to be
      needs to answer "what are these two things" before it can dispatch on
      them; nothing else in §22 assumes it.

---

## 23. The agent surface

What an agent driving `--mcp` can find out, and what it cannot. Every item here
came out of one session building a beach through `run_script`. The renderer
diagnosed most of it correctly at the time and had nowhere to say so.

- [ ] **Advisories reach the agent, not just the terminal.** All 17 `io::eprintfn`
      sites in `src/` are invisible over MCP, including the three that diagnose a
      real leak: live scenes (`render/pass.c3:555`), live materials (`:639`), and
      the shadow shader that would not compile (`render/shadow.c3:701`). All three
      fired during that session; none was read. Route them through a sink and fold
      it into the `run_script` reply as a `warnings` array *beside* `log` rather
      than inside it, so an agent can tell advice from its own output.
      `JsRuntime.collect_validation` (`js/runtime.c3:675`) already does this for
      the validation layer and is the shape to copy. **Do this one first:** it is
      one piece of plumbing, and it makes every heuristic already written start
      reaching the only consumer that needed it.
- [ ] **Name the fix in the timeout message.** `JsRuntime.timeout_message`
      (`js/runtime.c3:646`) says the script was stopped and not that
      `three.budget` is how to stop it happening again. The docs carry a whole
      entry about this trap, which exists only because the error is silent about
      the one-line answer.
- [ ] **Give the MCP path its own budget.** `tool_run_script`
      (`mcp/server.c3:130`) is the single call site, so this is one line. An agent
      assembling a scene is not the case the 5 s default protects: that argument
      (`js/runtime.c3:68`) is about a wedged loop hanging an interactive window,
      and an MCP call is already asynchronous to the user, under a client timeout
      of its own. 30–60 s there, `JS_BUDGET_MS` unchanged everywhere else, and the
      frame callback keeps its own 100 ms. Narrower than raising the global
      default, and it does not weaken the guarantee for the case that wanted one.
- [ ] **`three.scenes` and `three.scene(id)`.** A `Scene` in JavaScript is a
      wrapper around `_sid` (`js/prelude/scene.js`), so a scene whose wrapper was
      dropped — built inside a `run_script` scope that then ended — is alive,
      counted, holding a node pool and asset references, and unreachable by any
      handle in existence. The host can name it the whole time:
      `MeshPass.scene_by_id` and `dispose_scene` (`render/pass.c3:500`, `:523`)
      both work by id, and `dispose_scene` already refuses the active one. Binding
      plus prelude, over a list that is already there.
- [ ] **`three.disposeInactive()`.** The transition ritual — activate, dispose the
      rest, `unloadUnused` — is three steps an agent gets wrong by forgetting the
      middle one. Safe by construction once the loop is written, for
      `dispose_scene`'s reason.
- [ ] **`stats()` reports the images the renderer owns.** `textureBytes` and
      `poseBytes` are the only memory numbers there, and they are not where the
      memory is: a 1080p frame is ~17 MB of target and ~25 MB of post chain, a
      scene of 361k vertices is ~18 MB on the device and ~12 MB more kept resident
      on the CPU (`scene/asset.c3:22`), and one `shadow.size = 4096` is 134 MB by
      itself. Four fields — `shadowBytes`, `targetBytes`, `postBytes`,
      `geometryBytes`. It is also the measurement §19's `size` needs before it can
      earn a default under the standing constraint below.

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
