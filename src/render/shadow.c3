<*
 The directional shadow map: one depth image, one fit, one comparison.

 `c3c test --trust=full --test-noleak --test-filter three_tests::shadow`

 `plan.md` §12 called this "the largest single visual gap left after the sky",
 and §13 costed it at one extra barrier site before it was written. It came out
 at two, and the difference is stated here rather than quietly absorbed: §13
 assumed the read-side transition would fold into `begin_render_to`'s existing
 two-element array, and it does not, because the shadow map is **its own image at
 its own extent** rather than the target's depth buffer. So the pass owns both
 ends of its image's life and there is nothing to fold into.

 ## What a frame gains

 prepare        fit the light's box around the scene, write it into FrameBlock
 record_shadow  UNDEFINED -> DEPTH_ATTACHMENT, draw every caster, -> SAMPLED
 the scene      binding 1 is the map; `shadow_factor` reads it back

 The two ends agree because there is one matrix and it is written once, into the
 frame block both passes read — `shaders/shadow.slang` rasterises with it and
 `shaders/mesh.slang` projects into it. A second fit, or a matrix pushed to one
 pass and derived in the other, is the failure this arrangement rules out: a
 shadow map that is correct and a lookup that reads the wrong texel is a scene
 lit through a shape nobody drew.

 ## The three honest costs, each with the trigger that would change it

 **The whole scene, one map, no cascades.** The box is fitted around
 `Scene.bounds` every frame, so texel density is `extent / size` and a village is
 coarser than a room. 2048 across a 40-unit village is 2 cm a texel, which is
 fine; 2048 across a 4 km terrain is 2 m a texel, which is not. `three.light.
 shadow.size` is the knob, and the **trigger** for cascades is a scene where the
 largest size a device will allocate is still too coarse — at which point the fit
 becomes per-slice against the camera frustum and this becomes an array image,
 which §13 already notes is more draw calls and the same two transitions.

 **Every drawable casts, and the camera frustum stops culling while it does.**
 A caster outside the camera's view still throws a shadow into it, so the draw
 list cannot be the camera-culled one — `Scene.update` is told there is a shadow
 pass and builds the list without the frustum. What that costs is vertex work in
 the *main* pass for geometry that is then clipped away; what it buys is that
 panning the camera does not make shadows appear and disappear, which is the most
 obvious wrong thing a shadow map can do. It costs no draw calls at all: culling
 here drops instances from buckets, never buckets. The **trigger** for a second
 draw list is a scene where that vertex work is measurable — and `stats()` says
 `culled` is zero while shadows are on, which is already what it says when
 `Scene.cull` is off, so the number does not lie about it.

 **A depth pass has no fragment stage, so nothing is alpha tested and no vertex
 body runs.** A leaf card casts the shadow of its quad and a `ShaderMaterial`
 with a `vertex:` body casts the shadow of its undisplaced geometry. Both are one
 decision: `shaders/shadow.slang` is a single pipeline shared by every caster,
 and honouring either would make it a pipeline per material — the alpha test
 needs the material's map and a fragment stage to discard in, and the
 displacement needs the material's own assembled vertex body. The **trigger** is
 the first scene where foliage is the subject rather than the scenery.

 ## The two barriers rest on the specification, not on the layer

 `ShadowMap.begin` and `ShadowMap.end` own both ends of this image's life, and
 **deleting either of them leaves every check in `three_tests::shadow` green** —
 the pictures included, with the ordinary validation layer and with
 synchronization validation requested through `create_instance(sync: true)`.
 Measured by injection, twice, not reasoned about.

 That is a sharper finding than the usual one, because `plan.md` §13 argues that
 the layout bookkeeping *is* the instrument that catches a missing barrier on this
 driver, and offers the post chain as the measurement. The post chain still
 measures that way: comment out `record_chain`'s `shader_read_barrier` and
 `VUID-vkCmdDraw-imageLayout-00344` names the image, the binding and both
 layouts. So the instrument is present and works through a push descriptor — and
 it does not fire for a **depth** image sampled the same way. Anything relying on
 "the layer would have told us" about a depth attachment should not.

 ## What is deliberately not here

 No `castShadow` or `receiveShadow` per object. `plan.md`'s thesis is that two
 named channels vary per copy — `color` and `variant` — and a third would split
 buckets: two copies of one mesh disagreeing about casting are two draws, which
 is precisely the trade the whole renderer is built to refuse. Everything opaque
 casts and everything shaded receives.
*>
module three;

import std::io;
import std::math;
import std::math::matrix;
import std::math::vector;
import vk;
import collision;

faultdef SHADOW_FORMAT_UNSUPPORTED;

<*
 How wide the map is by default, in texels per side.

 2048 is 16 MB of D32 and is the size at which a scene the size of a village
 stops showing stair-steps on a wall's shadow. It is allocated only once a script
 turns shadows on, which is why the default can afford to be the good one rather
 than the cheap one.
*>
const uint SHADOW_DEFAULT_SIZE = 2048;

// The bounds a script's `size` is clamped into. The floor is where the picture
// stops being a shadow and starts being a stain; the ceiling is a size every
// device this targets can allocate as a depth image with room to spare, and
// asking past it is a request nobody meant.
const uint SHADOW_MIN_SIZE = 256;
const uint SHADOW_MAX_SIZE = 8192;

<*
 How far a sample is lifted off its own surface before it is projected, in
 shadow-map texels.

 **This is the whole of the acne fix and it is why the default `bias` is zero.**
 The classic depth bias fights acne by moving the comparison, which trades it for
 a shadow that detaches from its caster; the normal offset moves the *point being
 asked about* instead, off the surface it sits on, so the texel that recorded the
 surface stops competing with the surface itself. Two texels is the standard
 number and it is in texels rather than in world units on purpose — a scene ten
 times bigger has texels ten times wider and needs the offset to grow with them.
*>
const float SHADOW_NORMAL_OFFSET_TEXELS = 2.0;

<*
 One directional shadow map: what a script asked for, the device objects that
 answer it, and this frame's fit.

 Everything above `image` is a setting and survives everything below it — a size
 change destroys and rebuilds the image and leaves `bias` and `intensity` alone,
 which is what makes the four properties independent at the JS boundary rather
 than four ways to invalidate one another.
*>
struct ShadowMap
{
	// ---- what a script set ----

	// Off until something turns it on, and off is not merely "intensity zero":
	// no image is allocated, no shader is compiled and the pass records nothing,
	// so a project that never asks for shadows pays for none of this.
	bool enabled;

	<*
	 How far down the view direction the map is fitted, in world units. 0 is the
	 camera's own far plane.

	 **The knob §18.1 leaves behind**, and the reason it is needed rather than
	 optional: the default far plane is 1000 units, so a camera in a 200-unit
	 level can see past the end of it and the focus box is the level again. Set
	 this to the distance shadows are wanted at — for a village looked at from 80
	 units away, 120 spends every texel on what is in shot.

	 Zero by default, which is the pre-§18.1 behaviour for any scene the camera
	 can see all of, and a large improvement for any scene it cannot. No default
	 is invented for it: the number that is right depends on how big the level is
	 and how far the camera stands off, and `plan.md` §18.7 argues that picking one
	 for a scene shape nobody has measured is picking it wrong.
	*>
	float distance;
	// Texels per side, already clamped. What the image is *actually* at is
	// `created` — the two differ between a script writing this and the next
	// frame reaching `ensure`.
	uint size;
	// Added to the depth comparison, in the light's ndc depth units. Zero by
	// default; `SHADOW_NORMAL_OFFSET_TEXELS` has the argument for why.
	float bias;
	// How dark a shadow is: 1 removes the whole direct term and leaves the
	// ambient floor, 0 is no shadow at all. Doubles as the shader's "is there a
	// shadow pass this frame" flag — see `params`.
	float intensity;

	// ---- the device objects ----

	vk::Image image;
	vk::ImageView view;
	vk::Sampler sampler;
	vk::Memory memory;
	vk::Format format;
	// The size the image above really has, and 0 when there is no image. Compared
	// against `size` rather than trusted, because a script may write `size` at any
	// moment and the image can only change between frames.
	uint created;

	// One pipeline for every caster in the scene — there is no material in a
	// depth pass, so there is nothing to key a second one on. Compiled the first
	// time shadows are switched on and kept until the pass is freed.
	MeshPipeline pipeline;
	bool pipeline_ready;

	// ---- this frame ----

	// The light's orthographic view-projection, as `fit` last left it. Identity
	// until the first fit, which is what a frame with no shadow pass ships in the
	// frame block.
	Matrix4f light_view_projection;
	// One texel in uv, and how far along the normal a sample is nudged in world
	// units. Both derived by `fit` from the box it just fitted, so both track the
	// scene's size and the map's size without anybody setting them.
	float texel;
	float normal_offset;
	<*
	 Whether this frame has a shadow pass at all.

	 **Decided in `MeshPass.prepare` and read three times after it** — by
	 `Scene.update`, which builds an unculled draw list when it is set; by the
	 frame block, through `params`; and by `record_shadow`. One field rather than
	 three conditions, because the three have to agree: a draw list built as
	 though there were no shadow pass, followed by a shadow pass, is a shadow map
	 missing every caster the camera cannot see.
	*>
	bool live;
	// How many buckets the last shadow pass drew. Reported through `stats()`,
	// which is where a script finds out what a shadow costs it.
	uint draws;
}

<*
 The settings a shadow map starts at, and the ones `new three.Scene()` restores.

 A function rather than a constant because `MeshPass.init` and the scene reset
 both need it, and two spellings of a default drift — `DEFAULT_LIGHT` beside it
 has the same argument.
*>
fn void ShadowMap.defaults(&self)
{
	self.enabled = false;
	self.size = SHADOW_DEFAULT_SIZE;
	self.distance = 0;
	self.bias = 0.0;
	self.intensity = 1.0;
	self.light_view_projection = matrix::IDENTITY4{float};
	self.live = false;
	self.draws = 0;
}

<*
 Create the depth image, its view and its sampler at the requested size, or do
 nothing if one that size already exists.

 **The resize stalls the device, and that is the same trade `set_material_map`
 makes.** The image is one object shared by every frame in flight rather than one
 per slot, so destroying it while an earlier frame may still be sampling it is
 undefined behaviour that shows up as a corrupt frame later. `gpu/retire.c3` is
 what keeps the two apart: the old image's three handles go on the queue and are
 destroyed two frames later, so a script that changes `shadow.size` between
 frames pays an allocation and no stall at all.

 @return ? SHADOW_FORMAT_UNSUPPORTED : `No depth format on this device can be both rendered to and sampled. Cannot happen on a conformant device — D32_SFLOAT is required to do both — so this is a sentence rather than a fallback.`
*>
fn void? ShadowMap.ensure(&self, Gpu* gpu)
{
	if (self.image != null && self.created == self.size) return;
	if (self.image != null) self.destroy_image(gpu);

	// **Both features, and the second one is the half `Target` does not need.**
	// The target's depth buffer is only ever an attachment, so it asks for
	// DEPTH_STENCIL_ATTACHMENT alone; this one is read by a sampler afterwards,
	// and a format that can be written and not read would fail at the descriptor
	// rather than here.
	vk::FormatFeatureFlags wanted = FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT | FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
	self.format = vk::findDepthFormat(features: wanted, device: gpu.pdevice);

	// **`findDepthFormat` answers with its first candidate when none of them
	// matched**, which is a sensible fallback for a caller that has to have *a*
	// depth format and a silent wrong answer for one that needs specific
	// features. So the answer is checked rather than taken: without this, a device
	// with no sampleable depth format would fail at `vkCreateImage` with a
	// validation message about usage flags, several layers away from the reason.
	vk::FormatProperties properties;
	vk::getPhysicalDeviceFormatProperties(gpu.pdevice, self.format, &properties);
	if ((properties.optimalTilingFeatures & wanted) != wanted) return SHADOW_FORMAT_UNSUPPORTED~;

	self.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(self.format)
		.setExtent({ .width = self.size, .height = self.size, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setUsage(IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.build(gpu.handle)!;
	self.memory = vk::create_image_buffer(self.image, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	self.view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(self.format)
		.setSubresourceRange(
			{
				.aspectMask = IMAGE_ASPECT_DEPTH_BIT,
				.baseMipLevel = 0,
				.levelCount = 1,
				.baseArrayLayer = 0,
				.layerCount = 1
			}
		)
		.setImage(self.image)
		.build(gpu.handle)!;

	// **`FILTER_NEAREST`, and it is not a shortcut.** The comparison happens in
	// the shader, after the sample, so a linear filter would average *depths* and
	// then compare the average — which is not a soft edge, it is a wrong one, and
	// it puts a halo of half-shadow around every silhouette at the wrong distance.
	// The nine taps in `shadow_factor` are where the softening comes from: they
	// average the *comparisons*, which is what PCF means. It is also the only
	// filter a depth format is guaranteed to support as a sampled image.
	// 
	// CLAMP_TO_EDGE with the uv bounds check in the shader on top of it. Either
	// alone is nearly right and both together are exact: the clamp keeps the
	// sample legal and the bounds check keeps the *answer* from being the edge
	// texel's shadow smeared across everything outside the fitted box.
	self.sampler = vk::samplerCreateInfo().setMagFilter(FILTER_NEAREST).setMinFilter(FILTER_NEAREST)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setAddressModeV(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setMipmapMode(SAMPLER_MIPMAP_MODE_NEAREST)
		.setMinLod(0.0)
		.setMaxLod(0.0)
		.setBorderColor(BORDER_COLOR_FLOAT_OPAQUE_WHITE)
		.build(gpu.handle)!;

	self.created = self.size;
}

<*
 Compile `shaders/shadow.slang` and build the depth-only pipeline, once.

 Late rather than in `MeshPass.init`, for the reason the compute skinning
 pipeline is late: this is a Slang compile and a `VkPipeline` that a project which
 never turns shadows on should not pay for. Every other shader here is compiled
 on demand for the same reason.

 @return ? SHADER_MISSING_ENTRY_POINT : `The shadow shader would not compile. The diagnostic is printed, because a Slang error with a line and a column is the only actionable form of it.`
*>
fn void? ShadowMap.build_pipeline(&self, Gpu* gpu)
{
	if (self.pipeline_ready) return;

	String path = find_shader("shadow.slang", mem)!;
	defer path.free(mem);

	ShaderModule mod = compile_shader_file(path, SHADOW_ENTRIES[..], "shadow.slang")!;
	defer mod.free();
	if (!mod.ok)
	{
		io::eprintfn("three: the shadow shader would not compile: %s", mod.diagnostic);
		return SHADER_MISSING_ENTRY_POINT~;
	}

	self.pipeline.init_shadow(gpu, &mod, self.format)!;
	self.pipeline_ready = true;
}

<*
 Fit the light's orthographic box around what the scene holds, and derive the
 two numbers the lookup needs from it.

 ## The fit, in four steps

 direction    surface-to-light, normalized here because a script's is not
 eye          the scene's centre, backed off along it by the bounding radius
 light space  the scene's box re-bounded through that view
 projection   exactly that box, so no depth range is spent on nothing

 The eye is at twice the bounding radius, which is the smallest distance at which
 the whole scene is in front of the light for **every** direction a script can
 set: the box is within one radius of its centre, so the nearest point is one
 radius away and the near plane is positive whatever way the light is turned.
 Placing it at the scene's own edge instead saves nothing — an orthographic
 projection has no perspective to lose — and gives a near plane of zero the first
 time somebody points the light along the box's diagonal.

 **The box is re-bounded rather than its corners transformed one at a time.**
 `transform_aabb` is exact for an affine transform of a box, which a view matrix
 is, so this is the same eight corners with the arithmetic already written down.

 ## The focus box, and why the extent is a square that snaps — §18.1

 `bounds` decides where the light stands and how deep the pass reaches; **`focus`
 decides how many texels a metre gets.** They were the same box until §18.1, and
 the cost of that is in `plan.md`: a village 224 units across framed 70 units at
 a time spends nine tenths of the map outside the picture, and the measurement
 says the map's fill is the largest single item in the frame.

 Three things have to be true at once, and each one is why the arithmetic below
 is not simply "re-bound the focus box":

 - **The extent may not change when the camera turns.** An axis-aligned box in
   light space grows and shrinks as the camera orbits, which changes the world
   size of a texel every frame, which makes every shadow edge boil. So the extent
   is a *square* the size of the focus box's diagonal — the one number a rotation
   cannot move.
 - **The origin may only move in whole texels.** With a stable texel size, the
   remaining shimmer is the grid sliding under static geometry, and flooring the
   light-space origin to a multiple of the texel size removes it. This is the
   part the plan called "the reason this is not a five-line change", and it is
   two `floor`s once the extent is stable.
 - **It may never be worse than fitting the whole scene.** A camera that can see
   everything has a focus box that *is* the scene, and its diagonal is 1.7 times
   the box — so the square is capped at the scene's own light-space extent, and
   the fit degrades to what it always was rather than to something coarser.

 The depth range still comes from `bounds`, not from `focus`: a caster standing
 between the light and the visible region is outside the focus box and its shadow
 lands inside it.

 @param light : `xyz surface-to-light in world space, w ignored. A zero direction is treated as straight up rather than producing a NaN matrix — the same value three.light refuses at the door, defended again here because this is the only place it would be silent.`
 @param bounds : `The world box of everything drawable — Scene.bounds. A unit box for an empty scene, which fits and shadows nothing. Sets the light's stand-off and the near and far planes.`
 @param focus : `The part of it worth spending texels on — Camera.view_bounds intersected with bounds. Omitted, empty or degenerate falls back to bounds, which is the pre-§18.1 fit exactly, and is what the tests that check the fit itself pass.`
*>
fn void ShadowMap.fit(&self, float[4] light, collision::Aabb3 bounds, collision::Aabb3 focus = {})
{
	Vec3 direction = { light[0], light[1], light[2] };
	float length   = direction.length();
	if (length > 1e-6f)
	{
		direction = direction * (1.0f / length);
	}
	else
	{
		direction = { 0, 1, 0 };
	}

	Vec3 centre  = bounds.center();
	float radius = bounds.extent().length();
	if (radius < 1e-4f) radius = 1.0f;

	// Straight down is the one direction `look_at` cannot use +Y for, and it is
	// also the direction a script most plausibly asks for. Any axis not parallel
	// to the light will do; +Z is the one that leaves the map's own orientation
	// the same as the world's when the light is overhead.
	Vec3 up = { 0, 1, 0 };
	if (math::abs(direction.y) > 0.999f) up = { 0, 0, 1 };

	Matrix4f view        = matrix::look_at{float}(centre + direction * (radius * 2.0f), centre, up);
	collision::Aabb3 box = transform_aabb(view, bounds);

	// Degenerate on any axis means nobody supplied one, or the camera is looking
	// away from the scene entirely. The whole box is the honest answer to both.
	Vec3 span3 = focus.size();
	if (span3.x <= 0.0f || span3.y <= 0.0f || span3.z <= 0.0f) focus = bounds;

	collision::Aabb3 lit = transform_aabb(view, focus);

	// The diagonal, so that orbiting the camera cannot change it — and capped at
	// the scene's own light-space extent, so that a camera which frames
	// everything is fitted exactly as it was before this existed.
	float extent = (focus.max - focus.min).length();
	float ceiling = math::max(box.max.x - box.min.x, box.max.y - box.min.y);
	if (extent > ceiling || extent <= 1e-4f) extent = ceiling;
	if (extent <= 1e-4f) extent = 1.0f;

	uint texels = self.created > 0 ? self.created : self.size;
	float per_texel = extent / (float)texels;

	// Centred on the focus, then floored onto the texel grid. `math::floor` and
	// not a cast: the light-space origin is negative about as often as it is
	// positive, and a cast truncates towards zero, which snaps the two halves of
	// the world onto two different grids.
	float low_x = (lit.min.x + lit.max.x - extent) * 0.5f;
	float low_y = (lit.min.y + lit.max.y - extent) * 0.5f;
	low_x = math::floor(low_x / per_texel) * per_texel;
	low_y = math::floor(low_y / per_texel) * per_texel;

	// A right-handed eye looks down -Z, so everything in front of it has a
	// negative z and the ortho's near and far are the *distances* — which is the
	// sign flip that turns the box's z range into them. Getting this backwards is
	// an empty map with nothing in the pass to say so.
	float near = -box.max.z;
	float far  = -box.min.z;
	if (near < 0.01f) near = 0.01f;
	if (far <= near) far = near + 1.0f;

	self.light_view_projection =
		matrix::ortho{float}(low_x, low_x + extent, low_y, low_y + extent, near, far).mul(view);

	self.texel = 1.0f / (float)texels;
	// The world size of one texel, times the standard two. `fit` is the only
	// place that knows both halves of that product — the box's extent and the
	// map's resolution — which is why the offset is derived here and not set.
	// It follows the focus rather than the scene, so a tighter fit tightens the
	// offset with it instead of leaving a peter-pan gap that was tuned for a
	// coarser map.
	self.normal_offset = per_texel * SHADOW_NORMAL_OFFSET_TEXELS;
}

<*
 The four floats the frame block carries, as `shaders/mesh.slang` reads them.

 **All zero when the pass is not live, and `w` is the one that matters.** The
 shader's first line is `if (params.w <= 0.0) return 1.0`, so a frame with no
 shadow pass costs one compare per fragment and no texture taps — and the same
 line covers a script setting the intensity to zero, which is the same question
 asked from the other end.
*>
fn float[4] ShadowMap.params(&self)
{
	if (!self.live) return { 0, 0, 0, 0 };
	return { self.texel, self.bias, self.normal_offset, self.intensity };
}

<*
 The descriptor write for binding 1.

 SHADER_READ_ONLY_OPTIMAL because `end` put it there, in the same command buffer,
 before anything sampled it. The main pass binds this only when `live` is set and
 binds the white 1x1 otherwise — see `MeshPass.record`, which is where the choice
 between the two is made and is the only place that knows both are possible.
*>
fn vk::DescriptorImageInfo ShadowMap.descriptor(&self)
{
	return {
		.sampler = self.sampler,
		.imageView = self.view,
		.imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
	};
}

<*
 Transition in, begin rendering with depth alone, and set the map's own viewport.

 **Not `Target.begin_render_to`**, and the three differences are the reason: no
 colour attachment, an extent that is the map's rather than the target's, and a
 depth image that is this one rather than the target's. Sharing the function
 would mean four parameters that mean nothing to every other caller.

 The barrier is `ALL_COMMANDS` with no source access, which is `color_attachment_
 barrier`'s argument one image over: the hazard is that *last* frame sampled this
 map in the fragment stage and this frame writes it, and a write-after-read wants
 ordering rather than a cache flush. `vk::depthBarrier` would have been the
 obvious reuse and is subtly wrong here — its source stage is the depth-test
 stages, which do not cover a fragment shader's sampled read.

 The viewport height is negative, exactly as `Target.begin_render_to`'s is, so
 this pass rasterises under the same convention as every other pass in the
 project and `shadow_factor`'s ndc-to-uv flip is the one that follows from it.
*>
fn void ShadowMap.begin(&self, vk::CommandBuffer cmd)
{
	// UNDEFINED because the map is cleared on load, so there is nothing to preserve.
	vk::ImageMemoryBarrier2 to_attachment = { ...IMAGE_BARRIER,
		.image = self.image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.srcAccessMask = (vk::AccessFlags2)0,
		.dstStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.dstAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.oldLayout = IMAGE_LAYOUT_UNDEFINED,
		.newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_attachment }));

	vk::RenderingAttachmentInfo depth_attachment = vk::renderingAttachmentInfo().setImageView(self.view)
		.setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
		.setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE)
		.setClearValue({ .depthStencil = { 1.0, 0 } });

	vk::Extent2D extent = { .width = self.created, .height = self.created };
	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = extent }).setLayerCount(1)
		.setDepthAttachment(&depth_attachment);

	vk::cmdBeginRendering(cmd, &rendering);

	set_full_viewport(cmd, extent, true);
}

<*
 End rendering and hand the map to the fragment shaders that sample it.

 The read side of the pair `begin` opened, and the second of §13's two barrier
 sites. `LATE_FRAGMENT_TESTS -> FRAGMENT_SHADER` is exactly the dependency: depth
 was written by the tests and is about to be read by a sampler, in the same
 submission, so this needs the access masks a layout change alone would not give.
*>
fn void ShadowMap.end(&self, vk::CommandBuffer cmd)
{
	vk::cmdEndRendering(cmd);

	vk::ImageMemoryBarrier2 to_sampled = { ...IMAGE_BARRIER,
		.image = self.image,
		.srcStageMask = PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.srcAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
		.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_sampled }));
}

<*
 The image, its view and its sampler — everything a resize rebuilds.

 `vk::Memory.free` destroys the image it was bound to, so the image must not be
 destroyed again here; `gpu/target.c3` says the same about its own two.
*>
fn void ShadowMap.destroy_image(&self, Gpu* gpu)
{
	// Retired rather than destroyed, so that a size change mid-play costs
	// nothing — `gpu/retire.c3` holds the three handles for the frames that may
	// still be sampling the map. `memory.free` is what destroys the image, so
	// `image` is not handed over and is only cleared here.
	gpu.retire_memory(self.memory, self.view, self.sampler);
	self.memory = {};
	self.image = (vk::Image)null;
	self.view = (vk::ImageView)null;
	self.sampler = (vk::Sampler)null;
	self.created = 0;
}

<*
 Everything the map owns, including the pipeline.

 Called from `MeshPass.free` with the device already idle, so the pipeline is
 destroyed rather than retired — the deletion queue is for objects given back
 while frames are still running, and a teardown is neither.
*>
fn void ShadowMap.free(&self, Gpu* gpu)
{
	self.destroy_image(gpu);
	if (self.pipeline_ready) self.pipeline.free(gpu);
	self.pipeline_ready = false;
}
