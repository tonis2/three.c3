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
- [ ] **AO still costs about 7 ms with 32 lamps.** The taps are cheaper now (an
      affine unproject, one normalize), but the same `crevice_occlusion` measured
      2-2.5 ms cheaper when a material body called it than where `mesh_fragment`
      calls it, and moving the call, or giving it the shading normal, did not
      recover that. Worth a GPU profiler (Snapdragon Profiler or RenderDoc for
      Meta) before guessing further. AO's own depth pass is 0.2 ms and could reuse
      the prepass's depth.
- [ ] **`@relaxed` in the lighting.** Measured once the features were compiled
      out: no gain (9.58 against 9.54 ms). It only helped while the shader was
      starved of registers. Leave it until a scene that needs every feature is slow.
- [ ] **Foveated rendering.** The Quest driver has `VK_EXT_fragment_density_map`,
      its v2 and `VK_QCOM_fragment_density_map_offset`. It needs the device feature
      enabled, a density map with two lens centres over the side-by-side target,
      `RenderingFragmentDensityMapAttachmentInfoEXT` on the scene rendering, and
      `PIPELINE_CREATE_RENDERING_FRAGMENT_DENSITY_MAP_ATTACHMENT_BIT_EXT` on the
      pipelines drawn in it. The prepass must use the same map, or the scene's
      EQUAL depth test sees full-resolution depth under coarse fragments.
- [ ] **Tonemap straight into the XR image.** Every frame goes scene → RGBA16F →
      tonemap → `target.color` → blit to the swapchain: about 0.5 ms all told
      (post plus present). Writing the tonemap into the acquired image drops the
      blit and a full-size image; a screenshot or a UI overlay can still take the
      old path.
- [ ] **Depth is stored when nothing reads it.** Every attachment is STORE.
      AO's depth is dead after the scene, and the scene's depth is dead unless a
      post stage reads it — `post.shady` samples it whether or not it is used.
- [x] **CPU/GPU levels.** `XR_EXT_performance_settings` asks for sustained high
      at session start; light scenes got about 30% faster.
- [ ] **A refresh-rate knob for scripts.** `XR_FB_display_refresh_rate` is bound
      and the offered rates are logged (72, 80, 90, 120), but the runtime accepts
      a request at READY or FOCUSED and keeps 120 Hz. Find when it honours one,
      then expose it as `three.xr.refreshRate`.
- [ ] **Multiview.** One draw for both eyes through `viewMask` and a two-layer
      target. Saves CPU and vertex work, not fragment work. `view_index` is in
      shady now; every per-view pass still has to move from rects to layers.
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

- [ ] **Touch controllers.** No OpenXR actions yet: grip and aim poses, triggers,
      thumbsticks, buttons, haptics, and a JS API for scripts.

## 4. Stereo

- [ ] **The UI layer is laid out over both eyes.** It draws once across the
      side-by-side target, so a HUD is split by the eye seam. In VR it wants a
      panel in the world or an OpenXR quad layer.
- [ ] **Post passes sample across the eye seam.** The chain runs one viewport over
      the whole target, so a blur or bloom a script adds bleeds from one eye
      into the other. The tonemap is per pixel and fine.

## 5. Android

- [ ] **Ship a shader cache in the APK.** `build-apk.sh` packs none, so the first
      launch after an install compiles every shader on the headset.
- [ ] **Submit depth with the frame** (`XR_KHR_composition_layer_depth`), so the
      runtime reprojects late frames better.
- [ ] **The stdlib thread-setup bug is only worked around.** The glue thread
      needs `@pool_init` for tmem and the `NativeThread` must outlive `create`.
- [ ] **Shader cache logs never reach logcat.** They are `@debug_log`, and the
      Android entry never sets `debugging`.
