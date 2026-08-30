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

- [ ] **The whole of it.** There is a UI rendering library to bind rather than
      write; `notes.md` §5 has the three decisions that decide whether the
      binding is pleasant, and they are made.
- [ ] **The consume flag is the hard part.** A click on a button must not also
      shoot the gun, and `three.controls.enabled` does not answer it.
      `MouseTracker`'s edge machinery in `scene/input.c3` is where it belongs.
- [ ] **A scene has no way to say which keys it binds.** Seven keys bound to a
      character had to be delivered in a chat message. Smallest possible version
      of this section, and already missed.
- [ ] **Draw the one-line overlay.** `three.debug.overlay(string)` exists and
      reaches `console.log` and the run's `debug` array only; the window still
      shows no text. One line, this frame, gone the next — not widgets, so the
      consume question does not arise. §21's `systems.report()` waits on the
      same pixel.

## 6. Audio, saving, and the rest

- [ ] **Audio.** A new dependency and a new thread. `three.sound(path)`, `play`,
      `stop`, volume; positional audio is a cheap addition to `tick`.
- [ ] **Saving.** A write verb confined to a single state directory — never the
      assets root, never an arbitrary path. **The one place in this plan where the
      sandbox widens on purpose**, so say it in the doc comment.
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
