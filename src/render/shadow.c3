<*
 The directional shadow map: one depth image, one fit, one comparison.

 `c3c test --trust=full --test-noleak --test-filter three_tests::shadow`

 ## What a frame does

 prepare        fit the light's box around the scene, write it into FrameBlock
 record_shadow  UNDEFINED -> DEPTH_ATTACHMENT, draw every caster, -> SAMPLED
 the scene      binding 1 is the map; `shadow_factor` reads it back

 ...where "draw every caster" is one of three shapes — see `SHADOW_PLAN_FULL`.

 The two ends agree because there is one matrix, written once into the frame
 block both passes read: `shaders/shadow.slang` rasterises with it and
 `shaders/mesh.slang` projects into it. A second fit, or a matrix pushed to one
 pass and derived in the other, is the failure this rules out — a shadow map that
 is correct and a lookup that reads the wrong texel is a scene lit through a
 shape nobody drew.

 The pass owns both ends of its image's life, because the map is its own image at
 its own extent rather than the target's depth buffer; there is nothing to fold
 into `begin_render_to`'s existing barrier array.

 ## The honest costs, each with the trigger that would change it

 **The whole scene, one map, no cascades.** The box is fitted around
 `Scene.bounds` every frame, so texel density is `extent / size` and a village is
 coarser than a room. 2048 across a 40-unit village is 2 cm a texel, which is
 fine; 2048 across a 4 km terrain is 2 m a texel, which is not.
 `three.light.shadow.size` is the knob, and the trigger for cascades is a scene
 where the largest size a device will allocate is still too coarse.

 **Every drawable casts, and the camera frustum stops culling while it does.** A
 caster outside the camera's view still throws a shadow into it, so the draw list
 cannot be the camera-culled one — `Scene.update` is told there is a shadow pass
 and builds the list without the frustum. What that costs is vertex work in the
 *main* pass for geometry that is then clipped away; what it buys is that panning
 the camera does not make shadows appear and disappear. It costs no draw calls:
 culling drops instances from buckets, never buckets. The trigger for a second
 draw list is a scene where that vertex work is measurable.

 **Every drawable casts every frame, until something says it will not.**
 `object.static = true` puts a node in a second depth image that is drawn when it
 changes and kept when it does not, and a frame in which nothing casting is
 moving records no shadow pass at all. On the reference village at 1280x720 that
 took the whole pass from 0.334 ms to nothing — a settled shadowed frame costs
 0.344 against 0.276 with shadows off, and the difference left is the nine PCF
 taps the colour pass runs — while a frame with a mover over the cache costs
 0.078. `SHADOW_PLAN_FULL` has the three shapes, `ShadowMap.static_fit` has the
 invalidation, and `Bucket.static_first` has the reason the flag does not split a
 draw bucket.

 ## The cached half, and what it asked of the fit

 A stored depth image is only depths *in a particular projection*, so a cache is
 worth exactly as much as the fit is stable — and the fit follows the camera,
 which is what makes a village's shadows sharp. The two are reconciled in `fit`'s
 `stable` parameter: fit a square a little larger than the focus needs, then keep
 it for as long as the focus stays inside it. `SHADOW_FIT_SLACK` is the number,
 13% of the texel density is the price, and it is charged only to scenes that
 marked something static.

 Nothing else about the pass changes: the lookup is one sampler and one
 projection, the two images are the same format at the same extent under the same
 fit, and `descriptor` is the only place either view is named. The alternative —
 two maps — puts a second sampler and a second projection into
 `shaders/mesh.slang`, which every `ShaderMaterial` in every scene shares.

 A depth pass has no fragment stage, so nothing is alpha tested and no vertex
 body runs. A leaf card casts the shadow of its quad and a `ShaderMaterial` with
 a `vertex:` body casts the shadow of its undisplaced geometry. Both follow from
 `shaders/shadow.slang` being a single pipeline shared by every caster: the alpha
 test needs the material's map and a fragment stage to discard in, and the
 displacement needs the material's own assembled vertex body. The trigger is the
 first scene where foliage is the subject rather than the scenery.

 ## The two barriers rest on the specification, not on the layer

 `ShadowMap.begin` and `ShadowMap.end` own both ends of this image's life, and
 deleting either left every check in `three_tests::shadow` green — the pictures
 included, with the ordinary validation layer and with synchronization validation
 requested through `create_instance(sync: true)`. Measured by injection, twice.

 The check that carried that measurement is gone: it asked the loader for
 `VK_EXT_validation_features`, which this machine refuses, so it failed for the
 machine rather than for the pass. The finding stands on the injections, which is
 all it ever stood on — a green check was never the evidence here.

 The post chain does measure that way: comment out `record_chain`'s
 `shader_read_barrier` and `VUID-vkCmdDraw-imageLayout-00344` names the image,
 the binding and both layouts. So the instrument is present and works through a
 push descriptor — and it does not fire for a *depth* image sampled the same way.
 Anything relying on "the layer would have told us" about a depth attachment
 should not.

 ## What is deliberately not here

 No `castShadow` or `receiveShadow` per object. Two named channels vary per copy
 — `color` and `variant` — and a third would split buckets: two copies of one
 mesh disagreeing about casting are two draws. Everything opaque casts and
 everything shaded receives.

 `Node.static_caster` is not a counter-example. `castShadow` would decide
 *whether* a copy is drawn into the map, which the pass would have to key a draw
 on; `static` decides *when* — both halves are rasterised, in different frames,
 into images that are then one image. So it orders copies inside their bucket
 instead of keying one, and two copies of a wall disagreeing about it are still
 one draw call in the colour pass.
*>
module three;

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
// device this targets can allocate as a depth image with room to spare.
const uint SHADOW_MIN_SIZE = 256;
const uint SHADOW_MAX_SIZE = 8192;

<*
 How far a sample is lifted off its own surface before it is projected, in
 shadow-map texels.

 This is the whole of the acne fix and it is why the default `bias` is zero. The
 classic depth bias fights acne by moving the comparison, which trades it for a
 shadow that detaches from its caster; the normal offset moves the *point being
 asked about* instead, off the surface it sits on, so the texel that recorded the
 surface stops competing with the surface itself.

 Two texels is the standard number, and it is in texels rather than world units
 on purpose — a scene ten times bigger has texels ten times wider and needs the
 offset to grow with them.
*>
const float SHADOW_NORMAL_OFFSET_TEXELS = 2.0;

<*
 How much bigger than it needs to be the fitted square is made, once a scene has
 static casters worth caching.

 The cache is only worth having if the fit holds still, and the fit is centred on
 what the camera can see: a camera that moves at all moves the light's box, and
 every texel in the cached map is then about the wrong part of the world.

 This is the hysteresis: fit a square slightly larger than the focus needs, then
 keep it for as long as the focus still fits inside it rather than recentring
 every frame. The camera can drift by 7.5% of the box's width in any direction
 for free, which at walking pace is measured in seconds rather than frames.

 15% is the smallest number that buys a useful window. It costs 13% of the texel
 density the camera-following fit won, and it is charged only to scenes that
 marked something static — `fit` takes it as a parameter, so a scene with nothing
 to cache is fitted exactly as it was before this constant existed.
*>
const float SHADOW_FIT_SLACK = 1.15;

<*
 How far down the view direction a fit reaches when nothing said — as a multiple
 of the camera's own orbit distance.

 The default this replaces was the camera's far plane, which is 1000 units out of
 `default_camera` and is not a number about the scene at all: a camera in a
 200-unit level can see past the end of it, so the focus box is the level again
 and the whole fit collapses. The knob existed to be set, and what it costs when
 it is not is an hour spent asking whether shadows were rendering at all.

 Five, and here is where five comes from. At the default 45-degree field of view
 a camera standing `d` away frames `2 d tan(22.5) = 0.83 d` of the world, so a
 reach of `5 d` is about six frame-heights of ground down the view direction —
 the subject, and enough behind it that the fit does not end in a visible line
 across the floor. It is also, within ten per cent, the number the one level that
 ever set this by hand arrived at: 70 units at an orbit distance of 13.

 A guess with one measurement behind it, which is why `distance` is still the
 knob rather than being removed. What it buys is that a scene which never touches
 it gets a fit around what the camera is looking at instead of a fit around
 everything that exists.
*>
const float SHADOW_DEFAULT_REACH = 5.0;

<*
 How far the focus box should reach this frame: what a script set, or a number
 derived from where the camera is standing.

 The derivation is deliberately not clamped to the far plane here —
 `Camera.view_bounds` already takes the smaller of the two, and doing it in one
 place keeps "reach past the far plane" meaning the far plane rather than two
 different things in two files.

 @param orbit_distance : `The camera's own distance from its target, in world units.`
 @return `The world-space reach for Camera.view_bounds. Never zero for a camera that is anywhere.`
*>
fn float ShadowMap.reach(&self, float orbit_distance)
{
	if (self.distance > 0.0f) return self.distance;
	return orbit_distance * SHADOW_DEFAULT_REACH;
}

<*
 What `record_shadow` does with the map this frame.

 Three shapes, and which one a frame is in follows entirely from what the draw
 list holds — see `MeshPass.plan_shadow`, the only thing that assigns this.

 - `FULL` clears the map, draws every caster into it, and samples it. Any frame
 with nothing marked static is this, and so is a frame whose second image could
 not be allocated.
 - `STATIC` is the win. Every caster is static, so the map is a picture of a
 world that is not moving: it is drawn once into an image of its own and then
 sampled directly, frame after frame, with no pass recorded at all — no clear,
 no draws, no barriers, not even a copy.
 - `COMBINED` is a village with somebody walking through it. The static image is
 copied into the live one and the movers are drawn over the top, so the
 buildings are rasterised when they change and never because a character took a
 step.
*>
const uint SHADOW_PLAN_FULL     = 0;
const uint SHADOW_PLAN_STATIC   = 1;
const uint SHADOW_PLAN_COMBINED = 2;

// Which copies of each bucket a shadow pass draws — see `Bucket.static_first`
// for the layout these index into, and `MeshPass.record_casters` for the loop.
const uint CASTERS_ALL     = 0;
const uint CASTERS_STATIC  = 1;
const uint CASTERS_DYNAMIC = 2;

<*
 The five numbers a script set, apart from everything that answers them.

 Split out of `ShadowMap` because they belong to a scene and the device objects
 do not: a `Scene` keeps a copy of these — see `SceneLook` — so that activating
 it again brings its shadows back, while the image, the pipeline and the cached
 half stay with the renderer and are reused by whichever scene is on screen.
*>
struct ShadowSettings
{
	// Off until something turns it on, and off is not merely "intensity zero": no
	// image is allocated, no shader is compiled and the pass records nothing, so a
	// project that never asks for shadows pays for none of this.
	bool enabled;

	<*
	 How far down the view direction the map is fitted, in world units. 0 derives
	 one — see `reach` and `SHADOW_DEFAULT_REACH`.

	 The texel-density knob, and it is needed rather than optional: the default far
	 plane is 1000 units, so a camera in a 200-unit level can see past the end of
	 it and the focus box is the level again. Set this to the distance shadows are
	 wanted at — for a village looked at from 80 units away, 120 spends every texel
	 on what is in shot.

	 Setting it explicitly still beats the derived number and always will: the
	 scene knows how far away its shadows are worth having in a way the orbit
	 distance can only approximate.
	*>
	float distance;
	// Texels per side, already clamped. What the image is *actually* at is
	// `created` — the two differ between a script writing this and the next frame
	// reaching `ensure`.
	uint size;
	// Added to the depth comparison, in the light's ndc depth units. Zero by
	// default; `SHADOW_NORMAL_OFFSET_TEXELS` has the argument for why.
	float bias;
	// How dark a shadow is: 1 removes the whole direct term and leaves the ambient
	// floor, 0 is no shadow at all. Doubles as the shader's "is there a shadow
	// pass this frame" flag — see `params`.
	float intensity;
}

// The settings a shadow map starts on, and the ones a fresh `Scene` carries.
const ShadowSettings DEFAULT_SHADOW = {
	.enabled = false,
	.distance = 0,
	.size = SHADOW_DEFAULT_SIZE,
	.bias = 0.0,
	.intensity = 1.0,
};

<*
 One directional shadow map: what a script asked for, the device objects that
 answer it, and this frame's fit.

 Everything in `settings` survives everything below it — a size change destroys
 and rebuilds the image and leaves `bias` and `intensity` alone, which makes the
 four properties independent at the JS boundary rather than four ways to
 invalidate one another.

 `settings` is `inline`, so `shadows.enabled` still reads the field it always
 did; what the split buys is a `Scene` being able to hold five numbers without
 holding a Vulkan image.
*>
struct ShadowMap
{
	inline ShadowSettings settings;

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

	// ---- the cached half ----

	<*
	 A second depth image holding everything marked `Node.static_caster`, drawn
	 when something about it changes and kept otherwise.

	 Allocated only once a scene actually has a static caster, so a project that
	 never sets the flag pays neither the 16 MB nor the copy. Same format, same
	 extent and same fit as `image` — it has to be, because the whole point is that
	 one can be copied into the other and the lookup cannot tell which it read.
	*>
	vk::Image static_image;
	vk::ImageView static_view;
	vk::Memory static_memory;
	uint static_created;

	<*
	 What the cached image is a picture of, and the whole of the invalidation.

	 Two things are compared, and each is a way the stored depths stop meaning what
	 the lookup will assume they mean:

	 - the fit, because a shadow map is only depths *in a particular projection*
	 and re-projecting is not something a stored image can do. See
	 `SHADOW_FIT_SLACK`.
	 - `Scene.static_revision`, which moves when a static caster is added, removed,
	 hidden, re-parented, re-materialled or moved.

	 The size is a third and is not compared, because it cannot drift: `ensure`
	 destroys both images when it changes and `invalidate_static` goes with it.

	 What is deliberately *not* in here is anything about the camera or about a
	 dynamic node. That is the point: a character walking through the village must
	 not cost the village its map, and a camera that turns must not either.
	*>
	Matrix4f static_fit;
	uint static_revision;
	// False until the image holds a fit and a revision worth comparing — after
	// creation, after a resize, and after `defaults`.
	bool static_valid;
	// How many buckets the last *static* rebuild drew, for `stats()` to report
	// beside `draws`. Zero in every frame that did not rebuild.
	uint static_draws;

	<*
	 Whether the colour pass samples the cached image rather than the live one.

	 True in a `SHADOW_PLAN_STATIC` frame and only there: nothing moves, so the
	 cached image *is* the shadow map, and copying it into a second image to sample
	 that instead would be a full-image copy per frame to change nothing.
	*>
	bool sample_static;
	// This frame's shape — one of the three `SHADOW_PLAN_` constants. Decided by
	// `MeshPass.plan_shadow` once the draw list exists, read by `record_shadow`.
	uint plan;
	// Set when the cached image would not allocate, so the diagnostic is one
	// sentence and not one per frame. Cleared by a resize, which is a different
	// allocation and may well succeed.
	bool static_refused;

	// ---- the fit, as it last landed ----

	<*
	 The pieces `fit` needs to answer "is the box I already have still good?".

	 Kept apart from `light_view_projection` because that is the *product* and this
	 is the arithmetic: a projection matrix can be compared for equality but cannot
	 be asked whether a box is inside the region it covers, which is exactly the
	 question hysteresis is.
	*>
	Matrix4f fit_view;
	float fit_low_x;
	float fit_low_y;
	float fit_extent;
	float fit_near;
	float fit_far;
	bool has_fit;

	// One pipeline for every caster in the scene — there is no material in a depth
	// pass, so there is nothing to key a second one on. Compiled the first time
	// shadows are switched on and kept until the pass is freed.
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

	 Decided in `MeshPass.prepare` and read three times after it — by
	 `Scene.update`, which builds an unculled draw list when it is set; by the
	 frame block, through `params`; and by `record_shadow`. One field rather than
	 three conditions, because the three have to agree: a draw list built as though
	 there were no shadow pass, followed by a shadow pass, is a shadow map missing
	 every caster the camera cannot see.
	*>
	bool live;
	// How many buckets the last shadow pass drew. Reported through `stats()`.
	// 
	// It counts the draws this frame *recorded*, so a village whose static map is
	// still good reports zero and one with somebody walking through it reports the
	// movers. That is the number a script wants: `shadowDraws` is what the frame
	// paid, and `shadowStaticDraws` beside it is what the rebuild cost.
	uint draws;
}

// Whether two matrices are the same one. Element by element and bitwise, which is
// the right comparison here rather than a tolerance: `fit` is deterministic, so
// the same inputs produce the same sixteen floats, and "nearly the same fit" is
// not a thing a stored depth image can be sampled through.
fn bool same_matrix(Matrix4f a, Matrix4f b) @local
{
	for (usz i = 0; i < 16; i++)
	{
		if (a.m[i] != b.m[i]) return false;
	}
	return true;
}

<*
 Puts a scene's shadow settings on, and forgets what the last one's fit meant.

 `activate()` and `MeshPass.init` are the two callers, and everything below the
 assignment is what stops being true when the world changes underneath the
 image: the fit was a projection of a scene that is no longer on screen, and the
 cached half is a picture of it.

 The image and the pipeline are **not** freed — they are the expensive part,
 they are correct for whatever comes next, and `ensure` hands the same one back
 the moment anything turns shadows on again.
*>
fn void ShadowMap.apply(&self, ShadowSettings settings)
{
	self.settings = settings;
	self.light_view_projection = matrix::IDENTITY4{float};
	self.live = false;
	self.draws = 0;
	// The cached half is forgotten rather than freed: the static image is a picture
	// of the scene that was on screen, and the one coming on is a different world.
	// The image itself is worth keeping — the next scene will want one the same
	// size — and it is rebuilt on the first frame that needs it.
	self.invalidate_static();
	self.static_draws = 0;
	self.sample_static = false;
	self.plan = SHADOW_PLAN_FULL;
	self.has_fit = false;
}

// The settings a shadow map starts at. One spelling of a default, so that
// `MeshPass.init` and a fresh `Scene` cannot drift apart.
fn void ShadowMap.defaults(&self) => self.apply(DEFAULT_SHADOW);

<*
 Says that the cached image is a picture of something that is no longer true.

 One line, and it is a function so the places that have to call it are a list
 somebody can read: a resize, a `defaults`, and a freshly created image. The two
 keys drifting is not one of them — `static_current` compares them every frame.
 Nothing is destroyed and nothing is drawn: the next frame that wants the static
 half finds `static_valid` false and rebuilds it.
*>
fn void ShadowMap.invalidate_static(&self)
{
	self.static_valid = false;
}

<*
 Is the cached image still a picture of this frame?

 `ShadowMap.static_fit` is the argument for the two terms and for what is
 deliberately absent from them. Both are compared rather than trusted — the fit
 bitwise, because it is recomputed every frame from inputs that have not changed
 and therefore comes out the same sixteen floats.

 @param revision : `Scene.static_revision, which moves when anything about a static caster does.`
*>
fn bool ShadowMap.static_current(&self, uint revision)
{
	return self.static_valid && self.static_revision == revision && same_matrix(
		self.static_fit,
		self.light_view_projection
	);
}

<*
 The cached image now holds this revision under this fit.

 Called immediately after the rebuild and from nowhere else, so the keys are
 always written from the same values the pass just drew with rather than from
 whatever they are by the time somebody asks.
*>
fn void ShadowMap.mark_static_built(&self, uint revision)
{
	self.static_valid = true;
	self.static_revision = revision;
	self.static_fit = self.light_view_projection;
}

<*
 Creates the depth image, its view and its sampler at the requested size, or does
 nothing if one that size already exists.

 The image is one object shared by every frame in flight rather than one per
 slot, so destroying it while an earlier frame may still be sampling it is
 undefined behaviour that shows up as a corrupt frame later. `gpu/retire.c3`
 keeps the two apart: the old image's three handles go on the queue and are
 destroyed two frames later, so a script that changes `shadow.size` between
 frames pays an allocation and no stall.

 @return ? SHADOW_FORMAT_UNSUPPORTED : `No depth format on this device can be both rendered to and sampled. Cannot happen on a conformant device — D32_SFLOAT is required to do both — so this is a sentence rather than a fallback.`
*>
fn void? ShadowMap.ensure(&self, Gpu* gpu)
{
	if (self.image != null && self.created == self.size) return;
	if (self.image != null) self.destroy_image(gpu);
	// The cached half is the same extent as the live one by construction — one is
	// copied into the other — so a resize takes both, and what the old one held is
	// a picture at a resolution nothing is going to ask for again.
	if (self.static_image != null) self.destroy_static_image(gpu);
	self.invalidate_static();
	// A different allocation, and one that may well succeed where the last one did
	// not — a script halving `shadow.size` after running out of memory is exactly
	// the recovery this allows.
	self.static_refused = false;

	// Both features, and the second one is the half `Target` does not need. The
	// target's depth buffer is only ever an attachment, so it asks for
	// DEPTH_STENCIL_ATTACHMENT alone; this one is read by a sampler afterwards,
	// and a format that can be written and not read would fail at the descriptor
	// rather than here.
	vk::FormatFeatureFlags wanted = FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT | FORMAT_FEATURE_SAMPLED_IMAGE_BIT;
	self.format = vk::findDepthFormat(features: wanted, device: gpu.pdevice);

	// `findDepthFormat` answers with its first candidate when none of them matched,
	// which is a sensible fallback for a caller that has to have *a* depth format
	// and a silent wrong answer for one that needs specific features. So the answer
	// is checked rather than taken: without this, a device with no sampleable depth
	// format would fail at `vkCreateImage` with a validation message about usage
	// flags, several layers away from the reason.
	vk::FormatProperties properties;
	vk::getPhysicalDeviceFormatProperties(gpu.pdevice, self.format, &properties);
	if ((properties.optimalTilingFeatures & wanted) != wanted) return SHADOW_FORMAT_UNSUPPORTED~;

	self.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(self.format)
		.setExtent({ .width = self.size, .height = self.size, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(
			IMAGE_TILING_OPTIMAL
		)/* TRANSFER_DST because the cached half is copied in before the movers are *//* drawn over it. Asked for unconditionally rather than only when something *//* is static: the flag is set per node at any moment and the image can only *//* be created between frames, so the alternative is a resize-and-stall the *//* first time a script writes `mesh.static = true`. */
		.setUsage(IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT | IMAGE_USAGE_TRANSFER_DST_BIT)
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

	// `FILTER_NEAREST`, and not a shortcut. The comparison happens in the shader,
	// after the sample, so a linear filter would average *depths* and then compare
	// the average — not a soft edge but a wrong one, putting a halo of half-shadow
	// around every silhouette at the wrong distance. The nine taps in
	// `shadow_factor` are where the softening comes from: they average the
	// *comparisons*, which is what PCF means. It is also the only filter a depth
	// format is guaranteed to support as a sampled image.
	// 
	// CLAMP_TO_EDGE with the uv bounds check in the shader on top of it. Either
	// alone is nearly right and both together are exact: the clamp keeps the sample
	// legal and the bounds check keeps the *answer* from being the edge texel's
	// shadow smeared across everything outside the fitted box.
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
 Creates the cached image, or does nothing if one at the live map's size exists.

 Only ever called from a frame that has something to cache, so a scene with
 shadows on and nothing marked static allocates one image, not two.

 The sampler is `image`'s, shared rather than duplicated. It is a comparison-free
 nearest sampler with no state that could differ between the two, and the lookup
 must not be able to tell which image it read.

 `ensure` has already run and settled `format` and `created`, so this borrows
 both rather than deciding again. Two images that disagreed about either would
 fail at the copy, several frames from the reason.
*>
fn void? ShadowMap.ensure_static(&self, Gpu* gpu)
{
	if (self.static_image != null && self.static_created == self.created) return;
	if (self.static_image != null) self.destroy_static_image(gpu);
	if (self.created == 0) return;

	self.static_image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(self.format)
		.setExtent({ .width = self.created, .height = self.created, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(
			IMAGE_TILING_OPTIMAL
		)/* SAMPLED as well as TRANSFER_SRC: a frame in which *everything* is static *//* reads this image directly and never copies it, which is the case the whole *//* section exists for. See `sample_static`. */
		.setUsage(IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.build(gpu.handle)!;
	self.static_memory = vk::create_image_buffer(self.static_image, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	self.static_view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(self.format)
		.setSubresourceRange(
			{
				.aspectMask = IMAGE_ASPECT_DEPTH_BIT,
				.baseMipLevel = 0,
				.levelCount = 1,
				.baseArrayLayer = 0,
				.layerCount = 1
			}
		)
		.setImage(self.static_image)
		.build(gpu.handle)!;

	self.static_created = self.created;
	// A fresh image holds nothing, whatever the keys happen to say.
	self.invalidate_static();
}

<*
 Compiles `shaders/shadow.slang` and builds the depth-only pipeline, once.

 Late rather than in `MeshPass.init`, for the reason the compute skinning
 pipeline is late: this is a Slang compile and a `VkPipeline` that a project which
 never turns shadows on should not pay for.

 @return ? SHADER_MISSING_ENTRY_POINT : `The shadow shader would not compile. The diagnostic is printed, because a Slang error with a line and a column is the only actionable form of it.`
*>
fn void? ShadowMap.build_pipeline(&self, Gpu* gpu)
{
	if (self.pipeline_ready) return;

	String source = shader_source("shadow.slang", mem)!;
	defer source.free(mem);

	ShaderModule mod = compile_slang(source, "shadow.slang", SHADOW_ENTRIES[..])!;
	defer mod.free();
	if (!mod.ok)
	{
		@advise("three: the shadow shader would not compile: %s", mod.diagnostic);
		return SHADER_MISSING_ENTRY_POINT~;
	}

	self.pipeline.init_shadow(gpu, &mod, self.format)!;
	self.pipeline_ready = true;
}

<*
 Fits the light's orthographic box around what the scene holds, and derives the
 two numbers the lookup needs from it.

 ## The fit, in four steps

 direction    surface-to-light, normalized here because a script's is not
 eye          the scene's centre, backed off along it by the bounding radius
 light space  the scene's box re-bounded through that view
 projection   exactly that box, so no depth range is spent on nothing

 The eye is at twice the bounding radius, the smallest distance at which the
 whole scene is in front of the light for *every* direction a script can set: the
 box is within one radius of its centre, so the nearest point is one radius away
 and the near plane is positive whatever way the light is turned. Placing it at
 the scene's own edge saves nothing — an orthographic projection has no
 perspective to lose — and gives a near plane of zero the first time somebody
 points the light along the box's diagonal.

 The box is re-bounded rather than its corners transformed one at a time.
 `Aabb3.transform_matrix` is exact for an affine transform of a box, which a view
 matrix is.

 ## The focus box, and why the extent is a square that snaps

 `bounds` decides where the light stands and how deep the pass reaches; `focus`
 decides how many texels a metre gets. A village 224 units across framed 70 units
 at a time spends nine tenths of the map outside the picture, and the map's fill
 is then the largest single item in the frame.

 Three things have to be true at once, and each is why the arithmetic below is
 not simply "re-bound the focus box":

 - The extent may not change when the camera turns. An axis-aligned box in light
 space grows and shrinks as the camera orbits, which changes the world size of
 a texel every frame and makes every shadow edge boil. So the extent is a
 *square* the size of the focus box's diagonal — the one number a rotation
 cannot move.
 - The origin may only move in whole texels. With a stable texel size, the
 remaining shimmer is the grid sliding under static geometry, and flooring the
 light-space origin to a multiple of the texel size removes it.
 - It may never be worse than fitting the whole scene. A camera that can see
 everything has a focus box that *is* the scene, and its diagonal is 1.7 times
 the box — so the square is capped at the scene's own light-space extent.

 The depth range still comes from `bounds`, not from `focus`: a caster standing
 between the light and the visible region is outside the focus box and its shadow
 lands inside it.

 ## The hysteresis, and why it is a parameter

 A fit that recentres every frame is a cached shadow map thrown away every frame.
 So a scene with static casters asks for `stable` and gets two changes: the
 square is fitted `SHADOW_FIT_SLACK` larger than it needs to be, and the previous
 square is kept for as long as the focus still fits inside it. The camera then
 drifts for free and the fit steps rather than slides.

 A parameter and not the behaviour, because the slack is texel density spent in
 advance: a scene that cached nothing would be paying for a saving it is not
 collecting. Every test written against the fit itself passes `stable` false,
 which is how the two paths stay two paths.

 The kept square is dropped in one other case besides the focus leaving it: when
 the focus has shrunk to less than half of it. Otherwise a camera that zoomed out
 across a level and back again would spend the rest of the session looking at the
 coarse map it needed at the far end.

 @param light : `xyz surface-to-light in world space, w ignored. A zero direction is treated as straight up rather than producing a NaN matrix — the same value three.light refuses at the door, defended again here because this is the only place it would be silent.`
 @param bounds : `The world box of everything drawable — Scene.bounds. A unit box for an empty scene, which fits and shadows nothing. Sets the light's stand-off and the near and far planes.`
 @param focus : `The part of it worth spending texels on — Camera.view_bounds intersected with bounds. Omitted, empty or degenerate falls back to bounds, which is what the tests that check the fit itself pass.`
 @param stable : `Whether to hold a fit that is still good rather than recentring on the focus. What a scene with static casters wants; see above for what it costs.`
*>
fn void ShadowMap.fit(&self, float[4] light, collision::Aabb3 bounds, collision::Aabb3 focus = { }, bool stable = false)
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
	// also the direction a script most plausibly asks for. Any axis not parallel to
	// the light will do; +Z leaves the map's own orientation the same as the
	// world's when the light is overhead.
	Vec3 up = { 0, 1, 0 };
	if (math::abs(direction.y) > 0.999f) up = { 0, 0, 1 };

	Matrix4f view        = matrix::look_at{float}(centre + direction * (radius * 2.0f), centre, up);
	collision::Aabb3 box = bounds.transform_matrix(view);

	// Degenerate on any axis means nobody supplied one, or the camera is looking
	// away from the scene entirely. The whole box is the honest answer to both.
	Vec3 span3 = focus.size();
	if (span3.x <= 0.0f || span3.y <= 0.0f || span3.z <= 0.0f) focus = bounds;

	collision::Aabb3 lit = focus.transform_matrix(view);

	// The diagonal, so that orbiting the camera cannot change it — and capped at
	// the scene's own light-space extent, so a camera which frames everything is
	// fitted exactly as it was before this existed.
	float extent  = (focus.max - focus.min).length();
	float ceiling = math::max(box.max.x - box.min.x, box.max.y - box.min.y);
	// The slack is applied before the cap, so a scene the camera can see all of is
	// fitted to the scene either way and pays nothing for hysteresis it cannot use.
	if (stable) extent *= SHADOW_FIT_SLACK;
	if (extent > ceiling || extent <= 1e-4f) extent = ceiling;
	if (extent <= 1e-4f) extent = 1.0f;

	uint texels = self.created > 0 ? self.created : self.size;

	// A right-handed eye looks down -Z, so everything in front of it has a negative
	// z and the ortho's near and far are the *distances* — which is the sign flip
	// that turns the box's z range into them. Getting this backwards is an empty
	// map with nothing in the pass to say so.
	float near = -box.max.z;
	float far  = -box.min.z;
	if (near < 0.01f) near = 0.01f;
	if (far <= near) far = near + 1.0f;

	// The square already in hand, if it still covers what has to be covered. The
	// view matrix and the depth range have to be the same ones — they come from
	// `bounds` and from the light, so a scene that grew or a sun that turned fails
	// here — and then the question is only whether the focus is inside the box,
	// which is the exact condition for the map still being right rather than a
	// heuristic for it. The half-size test is what lets density come back after a
	// zoom.
	bool keep = stable && self.has_fit && self.fit_near == near && self.fit_far == far && same_matrix(
		self.fit_view,
		view
	) && lit.min.x >= self.fit_low_x && lit.min.y >= self.fit_low_y && lit.max.x <= self.fit_low_x
		+ self.fit_extent && lit.max.y <= self.fit_low_y + self.fit_extent && extent * 2.0f >= self.fit_extent;

	float low_x;
	float low_y;
	if (keep)
	{
		low_x = self.fit_low_x;
		low_y = self.fit_low_y;
		extent = self.fit_extent;
	}
	else
	{
		float per_texel = extent / (float)texels;
		// Centred on the focus, then floored onto the texel grid. `math::floor` and
		// not a cast: the light-space origin is negative about as often as it is
		// positive, and a cast truncates towards zero, which snaps the two halves of
		// the world onto two different grids.
		low_x = (lit.min.x + lit.max.x - extent) * 0.5f;
		low_y = (lit.min.y + lit.max.y - extent) * 0.5f;
		low_x = math::floor(low_x / per_texel) * per_texel;
		low_y = math::floor(low_y / per_texel) * per_texel;
	}

	self.fit_view = view;
	self.fit_low_x = low_x;
	self.fit_low_y = low_y;
	self.fit_extent = extent;
	self.fit_near = near;
	self.fit_far = far;
	self.has_fit = true;

	float per_texel = extent / (float)texels;

	self.light_view_projection = matrix::ortho{float}(low_x, low_x + extent, low_y, low_y + extent, near, far)
		.mul(view);

	self.texel = 1.0f / (float)texels;

	// The world size of one texel, times the standard two. `fit` is the only place
	// that knows both halves of that product — the box's extent and the map's
	// resolution — which is why the offset is derived here and not set. It follows
	// the focus rather than the scene, so a tighter fit tightens the offset with it
	// instead of leaving a peter-pan gap tuned for a coarser map.
	self.normal_offset = per_texel * SHADOW_NORMAL_OFFSET_TEXELS;
}

<*
 The four floats the frame block carries, as `shaders/mesh.slang` reads them.

 All zero when the pass is not live, and `w` is the one that matters: the
 shader's first line is `if (params.w <= 0.0) return 1.0`, so a frame with no
 shadow pass costs one compare per fragment and no texture taps — and the same
 line covers a script setting the intensity to zero.
*>
fn float[4] ShadowMap.params(&self)
{
	if (!self.live) return { 0, 0, 0, 0 };
	return { self.texel, self.bias, self.normal_offset, self.intensity };
}

<*
 What the last fit came out as, in world units — `three.light.shadow.fit`.

 Six numbers rather than a picture. `three.debug.view = 'shadowMap'` answers "is
 anything in the map" as an inset; this answers "is the fit where the author
 thinks it is", which is the better shape for it — a number is the only one of
 the two a headless run can assert on.

 `extent` is the one to read first. It is the world width of the square the map
 covers, so `extent / size` is the world size of a texel and is what decides
 whether a shadow has an edge or a staircase. A scene that looks like it has no
 shadows and reports an extent of 400 has its texels somewhere else.
*>
struct ShadowFit
{
	// Whether a shadow pass ran on the last frame. False here and a frame with no
	// shadows in it needs no further explanation.
	bool live;
	// The centre of the fitted box, in world space.
	Vec3 centre;
	// How wide the square is, in world units. The square is `fit`'s doing — a
	// rotation cannot change it, which is what stops the edges boiling.
	float extent;
	// The light's near and far planes, in world units along its own direction.
	// These come from the whole scene's bounds and not from the focus box: a caster
	// standing between the light and the visible region has to be in range or its
	// shadow does not land.
	float near;
	float far;
	// The world size of one texel — `extent` divided by the map's real size. The
	// number that decides how a shadow edge reads.
	float texel;
}

<*
 Reads the fit back.

 The inverse is written out rather than taken. `fit_view` is a `look_at` matrix,
 so its rotation is orthonormal and its inverse is the transpose with the
 translation undone first — nine multiplies against a general 4x4 inversion that
 can fail and would have to be handled. It is also why this cannot silently
 disagree with `fit`: they are the same nine numbers read in the two orders.

 @return `A zeroed report when nothing has been fitted yet, which is a scene that has never turned shadows on.`
*>
fn ShadowFit ShadowMap.report(&self)
{
	if (!self.has_fit) return { };

	uint texels     = self.created > 0 ? self.created : self.size;
	float per_texel = texels > 0 ? self.fit_extent / (float)texels : 0.0f;

	// The centre of the fitted box in light space: the middle of the square, and
	// halfway down the depth range. A right-handed eye looks down -Z, which is the
	// sign that turns the near and far *distances* back into a coordinate.
	Vec3 middle = {
		self.fit_low_x + self.fit_extent * 0.5f,
		self.fit_low_y + self.fit_extent * 0.5f,
		-(self.fit_near + self.fit_far) * 0.5f,
	};

	float[<16>] v = self.fit_view.m;
	Vec3 d        = { middle.x - v[12], middle.y - v[13], middle.z - v[14] };
	Vec3 centre = {
		v[0] * d.x + v[1] * d.y + v[2] * d.z,
		v[4] * d.x + v[5] * d.y + v[6] * d.z,
		v[8] * d.x + v[9] * d.y + v[10] * d.z,
	};

	return {
		.live = self.live,
		.centre = centre,
		.extent = self.fit_extent,
		.near = self.fit_near,
		.far = self.fit_far,
		.texel = per_texel,
	};
}

<*
 The descriptor write for binding 1.

 SHADER_READ_ONLY_OPTIMAL because `end` put it there, in the same command buffer,
 before anything sampled it. The main pass binds this only when `live` is set and
 binds the white 1x1 otherwise — see `MeshPass.record`.

 A frame in which nothing casting is moving samples the cached image itself
 rather than a copy of it (see `sample_static`), and both are left in
 SHADER_READ_ONLY_OPTIMAL by the frame that last wrote them. This is the only
 place either view is named, so the choice is made once and the rest of the pass
 cannot disagree with it.
*>
fn vk::DescriptorImageInfo ShadowMap.descriptor(&self)
{
	return {
		.sampler = self.sampler,
		.imageView = self.sample_static ? self.static_view : self.view,
		.imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
	};
}

<*
 Transitions in, begins rendering with depth alone, and sets the map's own
 viewport.

 Not `Target.begin_render_to`: no colour attachment, an extent that is the map's
 rather than the target's, and a depth image that is this one. Sharing the
 function would mean four parameters that mean nothing to every other caller.

 The barrier is `ALL_COMMANDS` with no source access, which is
 `color_attachment_barrier`'s argument one image over: the hazard is that *last*
 frame sampled this map in the fragment stage and this frame writes it, and a
 write-after-read wants ordering rather than a cache flush. `vk::depthBarrier`
 would be the obvious reuse and is subtly wrong — its source stage is the
 depth-test stages, which do not cover a fragment shader's sampled read.

 The viewport height is negative, exactly as `Target.begin_render_to`'s is, so
 this pass rasterises under the same convention as every other pass.
*>
fn void ShadowMap.begin(&self, vk::CommandBuffer cmd)
{
	self.begin_depth(cmd, self.image, self.view, IMAGE_LAYOUT_UNDEFINED, true);
}

<*
 The cached half's own pass — the one that runs on the frames a static caster
 actually changed, and on no others.

 UNDEFINED as the old layout for `begin`'s reason: this clears, so whatever the
 image held is being thrown away. True on the first rebuild and on every one
 after it, which is why there is no layout to track between frames.
*>
fn void ShadowMap.begin_static(&self, vk::CommandBuffer cmd)
{
	self.begin_depth(cmd, self.static_image, self.static_view, IMAGE_LAYOUT_UNDEFINED, true);
}

<*
 The movers' pass, over a map that already holds the buildings.

 `ATTACHMENT_LOAD_OP_LOAD` rather than a clear, and the depths it loads are the
 ones `copy_static` put there a moment ago. The old layout is TRANSFER_DST for
 the same reason — the copy is what wrote them — and reading the loaded values
 back means asking for DEPTH_STENCIL_ATTACHMENT_READ as well as WRITE.
*>
fn void ShadowMap.begin_over_copy(&self, vk::CommandBuffer cmd)
{
	self.begin_depth(cmd, self.image, self.view, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, false);
}

<*
 Transitions a depth image in and starts rendering to it at the map's own extent.

 The three passes above differ by three things and share everything else, which
 is why they are one function with three arguments rather than three copies of a
 barrier, a `RenderingInfo` and a viewport.

 The barrier is `ALL_COMMANDS` with no source access, which is
 `color_attachment_barrier`'s argument one image over: the hazard is that *last*
 frame sampled this map in the fragment stage and this frame writes it, and a
 write-after-read wants ordering rather than a cache flush. `vk::depthBarrier`
 would be the obvious reuse and is subtly wrong — its source stage is the
 depth-test stages, which do not cover a fragment shader's sampled read. Coming
 out of a copy the hazard is the other kind, so the source is the transfer stage
 and its write.

 The viewport height is negative, exactly as `Target.begin_render_to`'s is.

 @param from : `The layout the image is in. UNDEFINED discards the contents, which is what a clearing pass wants; TRANSFER_DST preserves what the copy left.`
 @param clear : `Whether to clear on load. False loads what is already there, which is only legal because the caller put it there in this same command buffer.`
*>
fn void ShadowMap.begin_depth(
	&self,
	vk::CommandBuffer cmd,
	vk::Image image,
	vk::ImageView view,
	vk::ImageLayout from,
	bool clear
)
{
	bool loading = from == IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
	vk::ImageMemoryBarrier2 to_attachment = {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = loading ? PIPELINE_STAGE_2_COPY_BIT : PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.srcAccessMask = loading ? ACCESS_2_TRANSFER_WRITE_BIT : (vk::AccessFlags2)0,
		.dstStageMask = PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
		.dstAccessMask = ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT | ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT,
		.oldLayout = from,
		.newLayout = IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_attachment }));

	vk::RenderingAttachmentInfo depth_attachment = vk::renderingAttachmentInfo().setImageView(view)
		.setImageLayout(IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL)
		.setLoadOp(clear ? ATTACHMENT_LOAD_OP_CLEAR : ATTACHMENT_LOAD_OP_LOAD)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE)
		.setClearValue({ .depthStencil = { 1.0, 0 } });

	vk::Extent2D extent = { .width = self.created, .height = self.created };
	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = extent }).setLayerCount(1)
		.setDepthAttachment(&depth_attachment);

	vk::cmdBeginRendering(cmd, &rendering);

	set_full_viewport(cmd, extent, true);
}

<*
 Ends rendering and hands the map to the fragment shaders that sample it.

 The read side of the pair `begin` opened. `LATE_FRAGMENT_TESTS ->
 FRAGMENT_SHADER` is exactly the dependency: depth was written by the tests and
 is about to be read by a sampler, in the same submission, so this needs the
 access masks a layout change alone would not give.
*>
fn void ShadowMap.end(&self, vk::CommandBuffer cmd) => self.end_depth(cmd, self.image);

<*
 The same for the cached image, and it always lands in SHADER_READ_ONLY_OPTIMAL.

 One resting layout for the static image and no field tracking which it is in. It
 is read two ways — sampled directly in a frame where nothing moves, and copied
 in a frame where something does — and the copy is the rarer of the two by a long
 way once a scene is playing. So the rebuild leaves it sampleable and
 `copy_static` borrows it for the length of one copy and puts it back, which
 costs one extra barrier on the frames there is a mover and removes a piece of
 state that could be wrong.
*>
fn void ShadowMap.end_static(&self, vk::CommandBuffer cmd) => self.end_depth(cmd, self.static_image);

fn void ShadowMap.end_depth(&self, vk::CommandBuffer cmd, vk::Image image)
{
	vk::cmdEndRendering(cmd);

	vk::ImageMemoryBarrier2 to_sampled = {
		...IMAGE_BARRIER,
		.image = image,
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
 Puts the buildings back into the live map so the movers can be drawn over them.

 The one full-image copy this costs, and what it buys is the geometry. A depth
 image cannot be loaded from one attachment and stored to another, and the movers
 cannot be drawn into the cached image without ruining it — the next frame would
 find last frame's character baked into the buildings. So the cached depths are
 copied and the movers are drawn over the copy. At 2048 that is 16 MB read and 16
 MB written against 4178 instances of geometry it removes, and the frame where
 nothing moves does not do it at all.

 Three barriers in two calls. The first pair is one `vkCmdPipelineBarrier2` with
 both images in it: the cached one from sampleable to transfer-source, the live
 one from whatever it was to transfer-destination, and UNDEFINED is right for the
 live one because the copy overwrites every texel. The second puts the cached
 image back where `end_static` leaves it.
*>
fn void ShadowMap.copy_static(&self, vk::CommandBuffer cmd)
{
	vk::ImageMemoryBarrier2 source = {
		...IMAGE_BARRIER,
		.image = self.static_image,
		.srcStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
		.srcAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.dstStageMask = PIPELINE_STAGE_2_COPY_BIT,
		.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
	vk::ImageMemoryBarrier2 destination = {
		...IMAGE_BARRIER,
		.image = self.image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
		.srcAccessMask = (vk::AccessFlags2)0,
		.dstStageMask = PIPELINE_STAGE_2_COPY_BIT,
		.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
		.oldLayout = IMAGE_LAYOUT_UNDEFINED,
		.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ source, destination }));

	vk::ImageSubresourceLayers layer = {
		.aspectMask = IMAGE_ASPECT_DEPTH_BIT,
		.mipLevel = 0,
		.baseArrayLayer = 0,
		.layerCount = 1,
	};
	vk::ImageCopy region = {
		.srcSubresource = layer,
		.dstSubresource = layer,
		.extent = { .width = self.created, .height = self.created, .depth = 1 },
	};
	vk::cmdCopyImage(
		cmd,
		self.static_image,
		IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		self.image,
		IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		1,
		&region
	);

	vk::ImageMemoryBarrier2 restore = {
		...IMAGE_BARRIER,
		.image = self.static_image,
		.srcStageMask = PIPELINE_STAGE_2_COPY_BIT,
		.srcAccessMask = ACCESS_2_TRANSFER_READ_BIT,
		.dstStageMask = PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
		.dstAccessMask = ACCESS_2_SHADER_SAMPLED_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
		.subresourceRange = DEPTH_LEVEL,
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ restore }));
}

<*
 The image, its view and its sampler — everything a resize rebuilds.

 `vk::Memory.free` destroys the image it was bound to, so the image must not be
 destroyed again here.
*>
fn void ShadowMap.destroy_image(&self, Gpu* gpu)
{
	// Retired rather than destroyed, so a size change mid-play costs nothing —
	// `gpu/retire.c3` holds the three handles for the frames that may still be
	// sampling the map. `memory.free` is what destroys the image, so `image` is not
	// handed over and is only cleared here.
	gpu.retire_memory(self.memory, self.view, self.sampler);
	self.memory = { };
	self.image = (vk::Image)null;
	self.view = (vk::ImageView)null;
	self.sampler = (vk::Sampler)null;
	self.created = 0;
}

<*
 The cached image and its view.

 No sampler: there is one, it belongs to `image`, and both views are read through
 it — see `ensure_static`. Retiring it here would take the live map's sampler
 away from the frames still using it.
*>
fn void ShadowMap.destroy_static_image(&self, Gpu* gpu)
{
	gpu.retire_memory(self.static_memory, self.static_view, (vk::Sampler)null);
	self.static_memory = { };
	self.static_image = (vk::Image)null;
	self.static_view = (vk::ImageView)null;
	self.static_created = 0;
	self.invalidate_static();
}

<*
 What the map costs, in bytes, and 0 before there is one.

 Two D32 images at `size` squared once a scene has a static caster, one before
 that — which is why this is read off the allocations rather than computed from
 `size`. The number matters out of all proportion to how easy it is to set:
 `three.light.shadow.size = 4096` is a single assignment and 134 MB, larger than
 everything else in a frame put together, and until this there was nothing in
 `stats()` that moved when it was written.

 A resize destroys the old images and this follows it down as well as up, but
 turning shadows OFF does not: nothing frees the map until the size changes or
 `free` runs, so this keeps reading what the last enabled size cost. That is the
 honest answer — the memory really is still held — and it is why the number is
 worth having rather than inferring from `shadow.enabled`.
*>
fn usz ShadowMap.bytes(&self) => (usz)(self.memory.size + self.static_memory.size);

<*
 Everything the map owns, including the pipeline.

 Called from `MeshPass.free` with the device already idle, so the pipeline is
 destroyed rather than retired — the deletion queue is for objects given back
 while frames are still running, and a teardown is neither.
*>
fn void ShadowMap.free(&self, Gpu* gpu)
{
	self.destroy_image(gpu);
	self.destroy_static_image(gpu);
	if (self.pipeline_ready) self.pipeline.free(gpu);
	self.pipeline_ready = false;
}