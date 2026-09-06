# three.c3 — what is left

**A task list, and nothing else.** 
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
- [ ] **A texture in the interface, by path.** cui has the field already —
      `RectStyle.texture` and `CircleStyle.texture`
      (`lib/cui.c3l/src/core/ui.c3:2169`, `:2181`), both an index into
      `CanvasPass.textures` and fed by `CanvasPass.load_image(path)`
      (`.../vulkan/canvas_pass.c3:390`). What is missing is a `texture` field on
      `UiNodeSpec` (`src/render/ui.c3:532`, which has `color` and `border_color`
      and nothing else) and a style key to set it. UI art is authored and lives
      in a file, so a path goes straight across and no bridge is needed.
- [ ] **A *scene* texture in the interface is the harder half, and is not this
      one.** `CanvasPass.textures` is a different descriptor table from
      `pass.assets`, so a `three.Texture` cannot be named across. The obvious
      bridge — read the pixels back with `textureRead` and re-upload through
      `CanvasPass.load_pixels` — was always a queue idle plus a second copy, and
      §23 killed it outright: `textureRead` now refuses a block texture, so that
      route would silently exclude every texture loaded from a `.ktx2`. Sharing
      one descriptor table between the two passes is the only version that works
      for every texture, and it wants a use case first — a generated or
      rendered image on a rect, which nothing has asked for yet. `UI.md` §9.
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

- [ ] **Clip events**: a sorted time list per clip compared against the player's
      clock, fired into a JS callback. Cheap on both paths. The blending it was
      bundled with is built — §3.
- [ ] **Inverse kinematics.** `collision::ik::solve_chain`
      (`lib/collision.c3l/src/ik.c3`) exists with a `shortest_arc` beside it and
      nothing in `src/` calls either. Live skinning already lets a script write a
      bone, so foot planting, a look-at and a weapon aim are a binding away.
- [ ] GPU Particles

## 19. Shadows at game scale

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
      free.** Two lines in `MeshPass.plan_shadow`; the measurement came out
      backwards on this device, so the numbers to beat want taking again.
- [ ] **Take the turntable measurement again.** `Camera.view_sphere` and
      `shadow.follow` were built against the numbers in the report — Evil Forest
      at 1080p, 2048 map, `shadow.distance = 24`, 20 rebuilds in 300 frames of a
      dragged turntable — and are checked in `three_tests::shadow` against a
      simulated drag rather than against that scene. The scene is where the
      claim was made and is where it wants confirming, on the two numbers that
      matter: rebuilds per drag, and what the sphere costs a *first-person*
      camera, whose target sits at the eye and whose fit is therefore the widest
      this shape produces.

**Not doing:** the depth prepass (measured — pay 0.59 ms to save at most 0.23),
and deferred shading (it breaks the material contract). The measurement is what
answers the idea; the argument is not.

## 20. Authoring a level

- [ ] **`Heightmap.furthest_point` still returns the four corners of the map.**
      Harmless now that the dispatch never sends a heightfield to GJK, and wrong
      the moment anything else calls it.
- [ ] **A heightfield is finite, so a body that slides off the edge falls.**
      Honest, and undocumented anywhere a script can see it.
- [ ] **The large bucket's threshold of 64 cells is a guess with an argument
      rather than a measurement.**

---

## 21. Systems and a cast

- [ ] **`three.systems.report()` has no way to reach a HUD.** It is the CPU half
      of `three.stats()` and there is nowhere to draw either — §5's text work is
      what unblocks it, and until then the numbers reach a person through
      `console.log` and a probe.

---

## 22. Shipping a game

What a bundle needs that a viewer does not. Audio is §6. Steamworks and macOS
notarisation are deliberately absent: neither can be done from this repo.

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

## 23. Compressed textures

None of this is blocking:

- [ ] **The BC7 fallback has never run.** `Gpu.supports` decides it and a test
      asserts it agrees with itself, but this machine samples BC7, so the branch
      that decodes to RGBA8 instead has only ever been reached by files that were
      not blocks to begin with. It wants a device that actually refuses BC7.

- [ ] **A compressed texture cannot be exported.** `encode_from_device` reads
      pixels back and a block texture has none, so a `.ktx2` a script loaded by
      path is counted in `report.skipped` and left out of the glTF. An image that
      came out of a `.glb` still round-trips, because that path copies the source
      bytes and never asks the device.

- [ ] **`three.texture` cannot ask for a family.** The space is a caller's
      choice and the family is the file's, which is right for loading and wrong
      for `DataTexture` — a script with BC7 blocks in hand has no way to hand
      them over. Wants a real use before it gets an argument.

## 24. Exporting compressed textures

- [ ] **`lib/gltf.c3l` is ahead of its committed pointer.** The extension
      declaration lives in the submodule — a constant in `src/main.c3` and the
      `extensionsRequired` emitter in `src/writer.c3`. Its own 67 tests pass, but
      the change has to be committed *there* and the pointer bumped *here* or a
      fresh clone builds a `.glb` nothing can read back.

- [ ] **One format for everything is the wrong default, and §26 was the wait.**
      BC7 is right for colour and wrong for two common maps: a normal map wants
      BC5, which spends its bits on the two channels that survive, and a
      single-channel occlusion map wants BC4 at *half* BC7's size (already in
      `ktx.c3l` as `vk::BC4_UNORM`, encode and decode both wired; this side wants
      it in `TextureFamily`). The renderer samples both maps now, so this is a
      storage policy for data that is read rather than for data nothing looks at.

- [ ] **A bake is encoded at whatever size it was baked.** `{ bake: 2048,
      textures: 'ktx2' }` is two expensive things in a row and nothing warns that
      the second one is about to take minutes. A progress signal or a count up
      front would cost little.

- [ ] **Nothing re-encodes an existing PNG asset in place.** The option covers
      what a scene *generated*; a kit that shipped as PNG stays PNG through an
      export because its source bytes are copied verbatim, which is right for
      fidelity and wrong for anyone wanting to convert a project. That is a
      different verb and it does not exist.

**When the bake grows the other three channels**, the check it has to reproduce
is `examples/trimsheet.js`'s: bake `h = 0.5 + 0.5 sin(2pi k u)`, whose slope is
closed-form, and compare every texel of the resulting normal against it — worst
error 0/255 across 1024, at float precision, scaled by a relief in texels and
pre-encoded past the target's sRGB write.

**Not doing:** matching a reference image automatically. An agent looking at a
reference and writing the function is the whole of the feature; sampling the
reference *into* the bake is a different one and wants a use first.

**The thesis holds.** A body is not a vertex, so none of this touches §Standing
constraints — the agent writes a function and the geometry stays a quad.

## 26. Shading the maps that already load

None of this is blocking:

- [ ] **The GGX block is still duplicated character for character.** `lambert`,
      `specular_light`, `environment_light`, `environment_uv`, `shadow_factor`
      and `srgb_to_linear` are two copies held together by a comment, and the
      mechanism that would end that now exists. What stopped them moving with
      §26 is that `material.slang`'s copies carry `#ifdef THREE_BAKE` branches
      `mesh.slang`'s do not, so unifying them is a change to the bake as well.

- [ ] **Nothing samples a height map on the built-in pipeline.** `parallax_uv`
      is a `ShaderMaterial`'s and a `LayeredMaterial`'s; a fifth slot would be an
      eighth binding and a fifth flag, and it waits for §25 to have something to
      put in it.

## 27. Hiding the repeat

Three separate tricks rather than one:

- **break the grid** — vary per *copy*: turn, flip or slide the uv, drift the
  tint, so a row of one shape stops being a row of one picture;
- **break the tile** — vary per *texel* inside one draw: stochastic sampling,
  triplanar, a macro noise at a tenth of the scale;
- **break the uniformity** — put things on top that do not repeat at all:
  decals, painted grime, edge wear.

**Stochastic sampling cannot be used on a trim sheet strip:** the offsets go on
*after* `uv_transform`, so a band an eighth of a sheet tall is left several
strips behind, and a brick band comes back showing the tile band. It assumes the
whole image tiles over the surface, which is the case it exists for.
`uvVariants` is the one that is safe on a sheet.

None of this is blocking:

- [ ] **A strip-safe scatter.** The gap the paragraph above opens. Inside a strip
      there is nowhere to move but along it, so the offset would have to be one
      axis rather than two — and which axis is a statement about what the
      material *means*, not something to derive from a repeat below 1, which is
      also what a material showing half of one picture looks like. It wants a
      use and a spelling before it wants an implementation.

- [ ] **Decals.** `three.DecalGeometry(target, { position, normal, size,
      rotation })`, which is `ConvexGeometry`'s shape of API and its precedent: a
      script hands over a description and the engine makes the vertices, so the
      thesis holds. Clip the receiver's triangles against the six planes of the
      decal box, take the uv from the projection, and lift the result along the
      normal.

      **The renderer half is small and it is the only real gap.**
      `PipelineDescription` has no depth bias — `gpu/pipeline.c3` builds
      `defaultRasterizationState` and never touches it — so a decal either
      z-fights with its receiver or wants a normal offset large enough to peel
      away from it at a grazing angle. One field on the description, one bit in
      the cache key.

      Batching is already solved: `three.merge` takes a chunk's decals into one
      asset, they share one material by construction, and each one's
      `mesh.color` bakes into the merged vertex colours, so they can still
      differ.

      `examples/trimsheet.js` has the flat-receiver half of this today and needed
      nothing from the engine for it — a quad two millimetres proud of the wall,
      a body that draws a crack and discards elsewhere, seeded per copy from
      `s.origin` so four of them are one draw call and four different cracks.
      What that cannot do is lie across a corner, which is the whole of what the
      clipping buys.

- [ ] **Per-pixel alpha in a body.** The limit the crack decal ran into: `shade`
      returns rgb, and how much of a surface shows is the material's opacity
      times the copy's, both per copy. So a decal's shape is a `discard` and its
      edge is hard. That is what an alpha-tested decal has always been and it is
      not urgent, but a soft-edged decal, a fading scorch and a dissolve that
      does not stipple all want the same missing channel.

- [ ] **`uvSource: 'world' | 'object'` on a LayeredMaterial layer.** Macro
      variation works today — a layer with no mask covers everything and
      `uvScale` tiles it independently of the base, so
      `{ map: noise, blend: 'multiply', uvScale: 0.05 }` is the classic
      low-frequency break-up with no engine change. But it is sampled in the
      *mesh's* uv, so every piece of a kit resets the macro pattern at its own
      origin, which is the repetition it was supposed to hide, one level up. The
      generated body already has `s.position`; this is a couple of lines in
      `js/prelude/layers.js`.

- [ ] **Nothing paints a vertex colour.** `maskSource: 'vertexColor'` is half of
      painted grime and the other half only ever arrives from a `.glb`. The
      in-keeping version is generated rather than painted — the engine
      evaluating a function per vertex — because a script that writes a vertex
      is the one thing the standing constraint forbids.

**Not doing: projected decals.** A decal that reads the depth buffer and paints
the surface it finds wants a G-buffer or a depth prepass this renderer does not
have, and it buys curved receivers that the mesh decal already gets by clipping.
The mesh decal is what covers cracks, leaks, posters and edge grime, and it is
the one that composes with instancing and with the exporter.

## 28. Wearing a sheet on somebody else's mesh

None of this is blocking:

- [ ] **A point light casts nothing**, and cannot: the shadow map is fitted around
      light zero, which is a direction. A lamp that shadows wants a cube map or a
      second fit, and `plan.md` §19's atlas is what turns that into a tiling
      question rather than an allocation one.

- [ ] **Four lights is still four.** A point light spends one of the same four
      slots a directional one does, so a room with three lamps has one left for
      the sun. §19 already names the fifth light as clustered forward's trigger;
      point lights are what make reaching it plausible.

## 29. The Evil Forest glb

`~/Documents/FF9/evil_forest.glb` is the first level authored end to end in
Blender and exported by the `blender_gltf` addon: 63 meshes, 21 materials, eight
of them `CUSTOM_materials_layers` stacks masked by painted `COLOR_0`, 61 KTX2
images, seven `KHR_lights_punctual` lights and a camera. Loading it as it is
draws the wrong picture, and every reason is below. The scripts that show each
one are in `~/Documents/FF9/build/`: `render_glb.js` is the file loaded the
plain way (`glb_plain.png`), `render_layered2.js` is the same frame with the
stacks imported by hand (`glb_layered2.png`), and the `diag_*.js` beside them
are the probes. Run any of them with

```sh
./build/three --assets ~/Documents/FF9 --no-boot --script ~/Documents/FF9/build/render_glb.js --frames 3
```

The order is the order the picture gets fixed in.

- [ ] **The nearest-to-camera rule leaves the crack unlit.** `{ lights: true }`
      fills the three point slots by distance from the file's camera, and in
      this file `hull_glow` — the cold light inside the breach — is the
      farthest of the six, so the breach draws 10% darker than the hand-lit
      frame. Ranking by `intensity / d²` from the eye or the target does not
      change the pick either. The warning names it and `asset.lights` puts it
      back in a line; if that stays the answer, say so in the docs beside the
      rule, and if not, an `except`/`prefer` list on the option is the smallest
      knob.

- [ ] **What a round trip now loses, visibly.** `scene.export` writes a stack's
      base normal as the core `normalTexture` and stops: the base occlusion,
      emissive and metallic-roughness maps item four gave the stack are not
      written back (`gltf::GltfBuilder` has no `metallicRoughnessTexture`), and
      a light exported by this renderer carries `three.lights`'s own multiplier
      where the import reads Watts, so a file that goes out and comes back is
      lit differently. Neither is a regression — nothing was carried before —
      but both are now gaps a reader can see.

Not defects, and worth knowing before someone files them: the soldiers and the
moogle are in the export on purpose; the dry-branch bundles are pale, not white
(`diag_branches.png` draws one five ways beside a rock and all five are the same
bark); the cut-outs (`alphaMode MASK` on the ferns, shrubs, weeds and vine leaves)
and `EXT_mesh_gpu_instancing` both work, 580 meshes in 76 draw calls; and 1.0 of
the frame's 1.2 million triangles are the 414 weed instances, all LOD0, which is a
question for the scatter and not for the renderer.

## 30. The Evil Forest in play

`./build/three --assets ~/Documents/FF9` boots the file as §29 left it. The load
and the freeze on touch are gone — 2.4 s to the first frame with mip chains, 4 s
without, 60 fps in the window — and what is left is the frame's tail, a texture
export that could be half the size, and a picture that is not the one Blender
draws. Every number below was measured on 2026-09-06 with the scripts in
`~/Documents/FF9/build/`: `probe_frames.js` is the frame harness, `probe_freeze.js`
and `probe_sweep.js` the collision one, and the picture is `blender_ref.png`
beside `game_shot.png` with `compare_shots.py` reading both. The groups are independent;
inside a group the order is the order to do them in.

- [ ] **`three.frame.ms` says what the host spent.** The split is `{ handlers,
      fixed, frame, jobs }` and `solver`, all script or solver; the frame's own host
      work — `MeshPass.prepare`, the draw list, the shadow fit, the upload — has no
      number. Measured 2026-09-06 on the Evil Forest at -O0: a 54 ms frame whose
      `ms.total` read 2.2 and `gpuMs` 1.2, so the 50 ms in `Scene.bounds` was visible
      only to a stack sampler. Add `host` (wall minus script, solver and the present
      wait) so `probe_frames.js`'s "wall minus script minus GPU" is a field.
- [ ] **A fixed step lands on a frame, not between two.** The character moves in
      the 60 Hz fixed loop and `Player.pose` copies its position into the object once
      a frame, with no interpolation; the display is 59.98 Hz. Measured windowed at
      -O3, 670 frames at a steady 16.6 ms: 656 took one step, 9 took none, 5 took
      two — fourteen frames where the character, and the camera on him, moved by
      zero or twice the usual, each a visible tick. Either the follow camera and
      `pose` read a position blended between the last two fixed states by the
      accumulator's remainder, or the fixed rate follows the display when they are
      within a percent of each other.
- [ ] **The exporter picks the block format from the map's use.** `export/
      texture.py` already knows `usage` — colour, normal, height — when it chooses
      the codec; a native BC export should choose the family too: BC1 for opaque
      colour (half a byte a texel), BC4 for a single channel (height, roughness,
      occlusion, a mask), BC5 for a normal's two channels, BC7 where BC1's
      artefacts show or alpha is carried, with RDO (`bc7enc_rdo`'s method) for the
      Zstd that follows once the encoder has it. That halves the 93 MiB on the
      device and would bring a native export of this scene to roughly 40 MiB. The
      shader side has to come first, because it is why `transcode_ktx2_blocks`
      refused BC5 and BC4: a BC5 normal has no z and a BC4 mask only red, so
      `material.slang` reconstructs z and broadcasts red for those families
      before any file ships them. Second, after the transcoder, and only if a
      native export is wanted at all — the transcoder makes the Basis file both
      small and quick.
- [ ] **A sweep against geometry still costs a frame at -O0.** The ten-second
      freeze is gone, but `probe_frames.js` on 2026-09-06 still finds the tail of the
      frame in `Player.step`: 27 ms at its peak and one frame in twenty over 15 ms at
      -O0, 2.6 ms at its peak at -O3, with 6.9 sweeps a frame gathering about 100
      triangles each. The per-triangle SAT in `query_all_triangles`
      (`lib/collision.c3l`), run on each of up to `SWEEP_MAX_STEPS` (24) advancement
      steps, is where the time is.

**The picture is not Blender's, by a little.** `build/blender_ref.png` is EEVEE
through the file's camera at 1920×1080, rendered headless by
`build/dump_render_settings.py` (`blender -b evil_forest.blend --python …`, 3 s),
and `build/game_shot.png` is the engine's frame at the same size. `python3
build/compare_shots.py` prints both, and every item below moves one of its rows.
Measured 2026-09-07, after the camera, the tonemap, the units, the world light,
the reflectance and the emissive strength all landed:

| | engine | reference |
| --- | --- | --- |
| mean luminance | 30.5 | 30.6 |
| luminance histogram, five bins % | 75, 25, 0, 0, 0 | 85, 15, 0, 0, 0 |
| sky | 51, 77, 75 | 41, 64, 62 |
| wall, moonlit | 17, 22, 19 | 18, 25, 22 |
| wall, in the tree's shadow | 4, 7, 5 | 9, 14, 12 |
| ground | 58, 58, 43 | 48, 52, 42 |
| barrel | 68, 46, 16 | 62, 46, 20 |
| lantern bulb | 188, 189, 187 | 227, 224, 217 |
| wheel | 10, 14, 9 | 34, 41, 34 |

The sky is ten units light because three.js's AgX is a polynomial fit that runs
light in the deep shadows — Blender's own curve would land it, and that is a
choice, not an item. Only lanterns 1–3 light: `MAX_LIGHTS` is 4, the importer
keeps the three nearest the camera and `main.js` swaps `hull_glow` in over the
farthest; the reference lights all seven, but at Blender's units a lantern is dim
beyond a couple of metres. None of the world colour, the view transform, the
exposure or EEVEE's shadow and GI settings are in the glb, because glTF has no
words for them: they are constants in `main.js`, read off the dump, exactly as
`scene.background` is — no `extras` and no extension for what a script can state
in three lines.

- [ ] **The importer reads the angle back the same way.** `import_/scene.py` line
      355 still does `cam.angle_y = persp.yfov`, so a glb → Blender import now
      narrows the camera: set `sensor_fit = 'VERTICAL'` beside it, or derive the
      fit-axis angle from `aspectRatio` when the file carries one.
- [ ] **The chain carries light above 1.** Image A, the post chain's intermediate
      (`TARGET_COLOR_FORMAT`), is `R8G8B8A8_SRGB`, so the scene pass clamps at 1.0
      before the tonemap reads it: an emissive at 8 reaches AgX as 1, and the
      roll-off measured on it (255 → 202) was of a clamped value. A float image A
      (`R16G16B16A16_SFLOAT`) for the target and the script passes, the sRGB encode
      kept for the blit, is what lets the bulbs, the barrels and the lantern pools
      roll off instead of clip. `postBytes` and `targetBytes` double; `docs/stats.md`
      says so. The bulb row above is what it moves.
- [ ] **The bounce.** The wall in the tree's shadow reads `[4, 7, 5]` against
      Blender's `[9, 14, 12]`, and the wheel `[10, 14, 9]` against `[34, 41, 34]`:
      EEVEE's fast GI carries the moonlit wall's light into the shadow, and the
      world term alone is a fifth of that. The cheap spelling is grading —
      `three.light.world` at two to three times the world colour in `main.js`, which
      the compare script will confirm or refuse; the correct one is an irradiance
      term from the environment, which `environment_light` half has. Decide with
      the SSAO item, since the two pull the same pixels in opposite directions.
- [ ] **Shadows from the lanterns, if the reference says they matter.** A cube
      map per point slot, or one spot-shaped map per light, is the largest engine
      item in this section; measure the wall under lanterns 1–3 in both renders
      before deciding it earns its place.
- [ ] **The crevices.** Blender's horizon scan is an occlusion on the world term.
      The cheapest spelling is a script pass in `main.js` — `three.addPass` bodies
      already read `p.depth`, linearised — that estimates occlusion from depth and
      multiplies the picture; an engine pass that multiplies only the world term
      is the correct one and comes second. Check the corner where the wall meets
      the ground against the reference.
- [ ] **Eight light slots**, if lanterns 0 and 4 read as missing beside the reference:
      `MAX_LIGHTS` 4 → 8, and `lights` is the last fixed field in `FrameBlock` for
      exactly this reason.

Not defects, and worth knowing: the instancing and the cut-outs match; the
ground's 31,720 triangles cost a sweep 46 µs, which is fine.

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
