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
      free.** Two lines in `MeshPass.plan_shadow`; the measurement came out
      backwards on this device, so the numbers to beat want taking again.
- [ ] **An orbiting camera refits the cached shadow map; a walking one never
      does.** `ShadowMap.static_fit`'s own comment says what is deliberately not
      a key: "anything about the camera... a character walking through the
      village must not cost the village its map, and a camera that turns must
      not either." It turns out a camera that *turns* is the only one that does.
      The key is `light_view_projection`, fitted around `Camera.view_bounds`,
      which is the AABB of the frustum corners — so it follows the eye, and
      `SHADOW_FIT_SLACK` absorbs 7.5% of the box width of eye travel per refit.
      Walking moves the eye 2.4 m/s; a turntable dragged at 180 deg/s on a 15.5 m
      boom moves it 48 m/s, twenty times faster, and an AABB around an oriented
      frustum also changes *extent* as it yaws, so the box escapes the slack by
      growing as well as by drifting. Measured on the Evil Forest scene at 1080p,
      2048 map, `shadow.distance = 24`: dragged, 20 rebuilds in 300 frames at
      0.27 ms against a 0.10 ms steady pass; camera still, 0 in 300; walking in
      first person, 0 in 300. Reported from a window as a lag spike that stops
      the moment the view changes to first person. The cost of a rebuild is
      39 draw calls over ~4,800 static instances, most of them crossed cards
      casting their whole quads because the depth pass has no fragment stage —
      so it scales with the scenery and it is the scene with grass in it that
      feels it. Two candidate fixes, and the measurement above does not say
      which: apply the slack to the fit's extent and not only to its centre, or
      fit the focus around a bounding *sphere*, which is rotation-invariant by
      construction and costs texel density in exchange.

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

## 25. A trim sheet from a function

`render/bake.c3` already runs a material body in uv space and reads the pixels
back, which is most of a material authoring tool built for another reason. Two
things are missing: it emits albedo and nothing else, and a body has no
vocabulary to write a pattern with. Substance Designer is the shape to copy —
procedural, no high-poly, no cage, no transfer bake.

`examples/trimsheet.js` is the whole feature done *around* the bake — a post pass
draws one channel, `three.screenshot` writes it, and the next lines load them
back with `three.texture` — so the sheet, the maps and the scene wearing them
exist and the items below are about moving that inside.

- [ ] **The bake emits one channel and there are four.** `Surface.height`, a
      channel index in the bake push, and a switch under `THREE_BAKE`. One
      pipeline and N submissions: MRT (§13) buys nothing here and costs a
      pass-system change. Everything below waits on this.
- [ ] **Normal is baked, not derived.** Central differences on `h` in the body,
      at float precision. Storing height and differentiating *that* quantizes
      first, and no operator recovers what the quantization threw away —
      terracing is the symptom. Three things decide the quality: ε is one texel
      at bake resolution, `heightScale` is in texels per metre or the relief
      reads at the wrong depth, and a 2x bake box-downsampled and renormalized
      antialiases the hard edges. RGBA8 is adequate; it is what a normal map
      ships as.
- [ ] **AO and curvature are derived, and for them that is right.** Both are low
      frequency and forgive the precision. A horizon sweep over the readback, on
      the CPU, testable without a device. Height packs 16 bits across R+G so the
      RGBA8 target does not have to change.
- [ ] **Roughness.** Nearly free once the channel index exists, and stone
      without it reads as plastic.
- [ ] **A body has no vocabulary.** Hashes, value/perlin/worley/fbm, brick and
      hex lattices, 2D SDFs, smooth-min and the blend operators, domain warp,
      molding profiles. It goes in as *more template*, not a Slang `import`:
      `shader/material_source.c3` splices markers into `shaders/material.slang`
      and brackets the body with `#line`. `shader/assemble.c3` counts `physical`
      rather than computing it, so the restore arithmetic should absorb the
      shift — should, and that is worth one test rather than one assumption.
- [ ] **A sheet is a layout, not a texture.** Strips at known v ranges, and
      geometry that uvs into them. Without a descriptor both sides agree on this
      produces materials and never trim sheets. The piece most likely to be
      skipped and then missed. `examples/trimsheet.js` has the shape of one —
      a strip table spliced into the generator and read by the scene, and a
      `wearStrip` that derives the tiling from the piece — so what is left is
      deciding whether the engine owns it or the script does.
- [ ] **Export writes one image per material.** glTF wants `normalTexture` and
      `occlusionTexture` beside the base colour.
- [ ] **The agent cannot see its own work.** `screenshot` returns the frame;
      authoring wants the sheet flat *and* on a lit test mesh. This is the half
      that decides whether an agent's iteration converges or wanders.

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

- [ ] **A built-in material's maps do not export.** `scene/export.c3` writes
      `normalTexture` out of a `LayeredMaterial`'s stack and knows nothing about
      the three slots on a `MeshLambertMaterial`, so a script that sets one and
      exports loses it silently.

- [ ] **The glTF importer still does not apply them.**
      `instantiate({ materials: true })` drops `aoMap` and
      `metalnessRoughnessMap` and routes a normal map through a
      `LayeredMaterial`, which now compiles a shader for something the built-in
      pipeline does. Both are one edit in `js/prelude/asset.js`, and both change
      what every existing import looks like — so they want a before-and-after of
      their own rather than a line in this one.

- [ ] **Nothing samples a height map on the built-in pipeline.** `parallax_uv`
      is a `ShaderMaterial`'s and a `LayeredMaterial`'s; a fourth slot would be a
      sixth binding and a fourth flag, and it waits for §25 to have something to
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

**Alpha-tested shadows: decided, not built.** A fragment stage and a sampler on
the shadow pipeline would stop grass, foliage, chain and rope casting
rectangles. Reading the code says it is the *second* half of a feature whose
first half does not exist: there is no `material.alphaTest` anywhere,
`mesh.slang` never reads the base colour map's alpha, and a transparent material
casts no shadow at all — so today a leaf card either casts the shadow of its
quad while being drawn as a blended quad, or casts nothing. Building the shadow
half alone would be building the half nothing can use. The whole feature is one
change: an `alphaTest` on the material, a `discard` in `mesh.slang`, and a
second shadow pipeline with a fragment stage used only by the materials that ask
— a second pipeline rather than a sampler on the one every caster shares, so a
scene with no cut-outs pays one pipeline object and nothing per draw. The
trigger is `render/shadow.c3`'s own: the first scene where foliage is the
subject rather than the scenery.

None of this is blocking:

- [ ] **The alpha test itself**, as the paragraph above spells it: `alphaTest` on
      the material, a `discard` in `mesh.slang`, and a cut-out shadow pipeline
      beside the one every other caster shares. One feature, two halves, and the
      shadow half is the cheaper of them once the first exists.

- [ ] **`emissiveMap` does not export**, which is §26's open entry about the
      built-in material's maps with a fourth one on the end. The *factor* crosses
      — `emissiveFactor` is written from `material.emissive` — and the image does
      not, because `scene/export.c3` writes maps out of a `LayeredMaterial`'s
      stack and knows nothing about the slots on a `MeshLambertMaterial`.

- [ ] **The importer still routes a glow through a `LayeredMaterial`.**
      `instantiate({ materials: true })` turns an `emissiveFactor` and an
      `emissiveTexture` into a layer at zero opacity, which now compiles a shader
      for something the built-in pipeline does. It is one edit in
      `js/prelude/asset.js` and it changes what every existing import looks like,
      so it wants the before-and-after §26 asks for on the same file.

- [ ] **A point light casts nothing**, and cannot: the shadow map is fitted around
      light zero, which is a direction. A lamp that shadows wants a cube map or a
      second fit, and `plan.md` §19's atlas is what turns that into a tiling
      question rather than an allocation one.

- [ ] **Four lights is still four.** A point light spends one of the same four
      slots a directional one does, so a room with three lamps has one left for
      the sun. §19 already names the fifth light as clustered forward's trigger;
      point lights are what make reaching it plausible.

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
