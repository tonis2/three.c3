# three.c3 — what is left

**A task list, and nothing else.**

---

## 1. Quest performance

`examples/vr_lights.js` (32 lamps, AO on) was about 50 ms of GPU time a frame on
Quest 3 and is now about 15 ms; with AO off 8.4 ms, and the sun alone 2.5 ms. The
display runs at 120 Hz, 8.3 ms a frame. `tools/vr_profile.js` measures it.

What the numbers showed: Adreno pays for every line of the mesh shader in
registers whether it runs or not, so the cost is how much code the shader has, not
how much a pixel executes. That is why the frame's unused features are compiled out.

- [x] **Time each pass on the headset.** `FrameTiming` splits AO's depth pass and
      the prepass out of the scene, and the XR log prints every phase.
- [x] **Every pixel looped over every light to find the directional ones.** The
      sun is lit on its own; other directionals are listed in the frame block and
      share the local lights' loop.
- [x] **Compile out the features a frame does not use.** Area, spot, extra
      directional, local shadow, baked, environment, light map, occlusion and sun
      shadow are spec constants; `MeshPass.unused_features` picks a pipeline
      variant per frame. `three.debug.view = 'features'` shows which were kept.
- [x] **AO cost about 6 ms with 32 lamps; now about 1.1 ms.** The 12 taps
      left the mesh shader for a pass of their own at half resolution, from a
      half-resolution depth pass, and the mesh shader reads the answer once
      after the light loop. Holding even one value across that loop cost it
      1-2 ms; the read at the end costs about 0.4.
- [ ] **AO's depth pass could reuse the prepass's depth.** About 0.1 ms at
      half resolution, so only worth it alongside other depth changes.
- [ ] **`@relaxed` in the lighting.** Measured once the features were compiled
      out: no gain (9.58 against 9.54 ms). It only helped while the shader was
      starved of registers. Leave it until a scene that needs every feature is slow.
- [x] **Foveated rendering.** A fragment density map of 32x32-pixel texels
      around each lens centre, on the scene and the prepass renderings and
      their pipelines; `three.xr.foveation` is 'off', 'low', 'medium' (the
      default) or 'high'. vr_lights with 32 lamps and AO went from about 10 ms
      to 7.4 and holds 120 Hz. The prepass and the scene share the map, and
      the EQUAL test still matches.
- [x] **Tonemap straight into the XR image.** The tonemap writes the acquired
      swapchain image; the blit and `target.color` are skipped unless an
      interface is drawn over the frame. About 0.2 ms.
- [x] **Depth is stored when nothing reads it.** The scene's depth is not
      written back when no post pass reads it and the scene cache is off, and
      a post body that never reads `p.depth` no longer declares the depth
      buffer. No measurable change on Quest 3, whose driver seems to render
      these passes straight to memory.
- [x] **CPU/GPU levels.** `XR_EXT_performance_settings` asks for sustained high
      at session start; light scenes got about 30% faster.
- [x] **A refresh-rate knob for scripts.** `three.xr.refreshRate` and
      `three.xr.refreshRates`. The runtime had been ignoring requests because the
      headset's `debug.oculus.refreshRate` property forces a rate; without it an
      app starts at 72 Hz.
- [x] **Multiview.** Both eyes in one pass through `viewMask` and a two-layer
      target; the tonemap writes them side by side into the swapchain image.
      `vr_lights` went from 7.29 to 7.10 ms GPU at 120 Hz; it has few draws, so
      the CPU and vertex savings show on heavier scenes. The prepass is drawn
      inside the scene rendering: carried across renderings with foveation on,
      Quest 3 loads the depth back wrong along each density ring's edge.
- [ ] **AO result in one multiview rendering.** The result pass still runs once
      per eye, which made AO 0.09 ms dearer than side by side. The inverse
      matrices could come from the frame blocks instead of the push block.
- [ ] **Script post passes on a multiview target** read the eyes copied side by
      side into A, a full-frame copy that only they pay for. Running the chain
      per layer would drop the copy and the seam bleed below.
- [ ] **Tonemap in the scene pass.** Without script post passes the RGBA16F image
      exists only to be tonemapped; the mesh shaders could write display colour
      directly.

## 2. shady

- [x] **`@relaxed` on functions.** RelaxedPrecision on every 32-bit float result
      inside a function that carries it, so Adreno can use fp16. Shady has no
      precision decoration at all today.
- [x] **Struct copies Adreno reads wrong.** A whole-struct load or copy of a laid
      out struct whose offsets differ from std430 reads shifted data, and
      OpCompositeConstruct of a Block-decorated struct fails in the driver. The
      engine's own shaders are worked around by hand (`InstanceData`,
      `instance_at`); a script material's struct is not. Values and locals want
      an undecorated twin of the type, and memory is read member by member.
- [x] **`view_index`.** The built-in multiview needs: MultiView capability, and
      Flat on a fragment input.
- [x] **Private variables.** `private uint frame_view;` at module scope, so an
      entry point hands the view index to every helper without a parameter.
- [x] **`@invariant` on a position**, so the depth prepass and the scene that
      tests EQUAL against it compute the same depth.
- [x] **The shader cache key does not know the compiler.** It hashes `"shady"`
      and the source, so a codegen change serves stale SPIR-V until
      `SHADER_CACHE_FORMAT_VERSION` is bumped by hand. A shady revision constant
      belongs in the key.
- [ ] **`half` has no vectors.** There are no `half2`..`half4`, and `vector_of`
      turns a half element into a `floatN` (`codegen.c3`).
- [ ] **Two spellings of one array type do not match.** `Light both[2] =
      lights.lights;` is refused with "cannot use a Light[2] where a Light[2] is
      expected": array types are not interned, so a member's and a local's are
      different types to `coerce`.

## 3. Input

- [x] **Touch controllers.** OpenXR actions for the Touch profile (simple controller
      as a fallback): grip and aim poses, triggers, thumbsticks, buttons and haptics, as
      `three.xr.left` / `three.xr.right` with engine-placed `grip` and `aim` groups.
      `three.xr.emulate` makes the mouse and keyboard the hands at a desk.
- [x] **Try them on the headset.** On Quest 3 (runtime 210.137) both hands come up as
      `oculus/touch_controller`; triggers, squeeze, A, B, Y and both sticks reach the
      script with their edges, `vr_controllers.js` grabs, throws and pushes cubes, and
      `vibrate` buzzes the controller. X, the stick clicks and menu were not pressed
      in that session.
- [ ] **A grab lags its hand by a physics step.** A kinematic hand copied from
      `r.grip` in the callback reaches the solver one step late, so a joint made the
      frame a hand arrives holds the object that far off. `node.xrTrack` on a
      top-level kinematic mesh would close it.

## 4. Stereo

- [ ] **The UI layer is laid out over both eyes.** It draws once across the
      side-by-side target, so a HUD is split by the eye seam. In VR it wants a
      panel in the world or an OpenXR quad layer.
- [ ] **Post passes sample across the eye seam.** The chain runs one viewport over
      the whole target, so a blur or bloom a script adds bleeds from one eye
      into the other. The tonemap is per pixel and fine.

## 5. Android

- [x] **Passthrough.** `three.xr.passthrough` over `XR_FB_passthrough`: the scene
      clears to nothing, skips its sky, and its premultiplied alpha is coverage (opaque
      writes 1, additive leaves it alone, the tonemap carries it).
- [x] **Try passthrough on the headset.** The room shows behind the scene and toggles
      cleanly; `vr_controllers.js` held 120 fps at about 1.2 ms CPU and 2.5-3.5 ms GPU
      with it on or off.
- [x] **Hot reload on the headset.** `quest.sh push` reloads the running game in about
      30 ms without restarting the app or the session.
- [x] **Build and test from a Mac.** `build-apk.sh` finds the NDK's host toolchain;
      `quest.sh` pushes a game (reloaded in place), forwards MCP and tails logcat;
      the headset serves the MCP tools on 8808.

- [ ] **Ship a shader cache in the APK.** `build-apk.sh` packs none, so the first
      launch after an install compiles every shader on the headset.
- [ ] **Submit depth with the frame** (`XR_KHR_composition_layer_depth`), so the
      runtime reprojects late frames better.
- [ ] **The stdlib thread-setup bug is only worked around.** The glue thread
      needs `@pool_init` for tmem and the `NativeThread` must outlive `create`.
- [ ] **Shader cache logs never reach logcat.** They are `@debug_log`, and the
      Android entry never sets `debugging`.
