<*
 Shadow settings, directional fitting, cache keys and caster pipelines.

 ShadowManager projects every light into ordinary views and ShadowAtlas owns all
 depth images, tile rendering and static-cache copies. This file keeps the
 projection policy and the shared depth-only pipelines used by those views.
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
 `Camera.view_sphere` already takes the smaller of the two, and doing it in one
 place keeps "reach past the far plane" meaning the far plane rather than two
 different things in two files.

 @param orbit_distance : `The camera's own distance from its target, in world units.`
 @return `The world-space reach for Camera.view_sphere. Never zero for a camera that is anywhere.`
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
const uint CASTERS_VISIBLE = 3;

// Every casting light is reduced to one or more ordinary atlas views. Keeping
// the distinction here, instead of in the image owner, makes allocation,
// invalidation and rendering identical for all light shapes.
enum ShadowViewKind : char
{
	DIRECTIONAL,
	POINT,
	SPOT,
	AREA,
}

const uint SHADOW_VIEW_NONE = uint::max;
const uint SHADOW_MAX_VIEWS = 64;

struct ShadowViewKey
{
	// Stable light identity, never its position in the packed lighting array.
	uint light;
	// Cascade or cube face. Zero for spot and representative area views.
	uint part;
	ShadowViewKind kind;
}

fn bool ShadowViewKey.equals(ShadowViewKey a, ShadowViewKey b) @inline =>
	a.light == b.light && a.part == b.part && a.kind == b.kind;

// CPU and shader-visible description of one atlas tile. `atlas` is scale.xy
// and offset.zw. Area lights deliberately use a representative perspective
// view: this is stable and useful, but is not exact extended-source visibility.
struct ShadowView
{
	ShadowViewKey key;
	Matrix4f view_projection;
	float[4] atlas;
	float[4] params; // texel, bias, normal offset, intensity
	uint size;
	uint static_revision;
	uint signature;
	bool static_valid;
	// The live atlas may be reused when a combined update is deferred.
	bool live_valid;
	// Whether that complete live tile includes a dynamic overlay. When the last
	// caster leaves this view, one cache copy is needed to erase its old depth.
	bool live_dynamic;
	bool live;
	bool wanted;
}

// Device-addressed tail written for active views. Kept free of CPU cache keys:
// shaders index it through Light.meta.y and need only projection and sampling.
struct ShadowGpuView
{
	Matrix4f view_projection;
	float[4] atlas;
	float[4] params;
}

struct ShadowBudget
{
	// Limits are resources, not a magic number of lights. A point light consumes
	// six views and six tiles, exactly as the allocator and renderer do.
	uint max_views;
	usz max_texels;
	usz max_bytes;
	uint max_updates;
	usz max_update_texels;
}

const ShadowBudget DEFAULT_SHADOW_BUDGET = {
	.max_views = SHADOW_MAX_VIEWS,
	.max_texels = 8192 * 8192,
	.max_bytes = 256 * 1024 * 1024,
	.max_updates = 64,
	.max_update_texels = 32 * 1024 * 1024,
};

struct ShadowViewSet
{
	ShadowView[SHADOW_MAX_VIEWS] views;
	uint count;
	uint active;
	usz texels;
	usz bytes;
	ShadowBudget budget;
}

fn void ShadowViewSet.reset(&self)
{
	for (uint i = 0; i < self.count; i++)
	{
		self.views[i].live = false;
		self.views[i].wanted = false;
	}
	self.active = 0;
	self.texels = 0;
	self.bytes = 0;
	if (self.budget.max_views == 0) self.budget = DEFAULT_SHADOW_BUDGET;
}

// Admission is deliberately expressed in views, texels and device bytes. It
// therefore makes the cost difference between a spot and a six-face point
// light explicit and remains correct when depth formats change size.
fn uint ShadowViewSet.admit(&self, ShadowViewKey key, uint size, usz bytes_per_texel = 4)
{
	usz texels = (usz)size * (usz)size;
	usz bytes = texels * bytes_per_texel;
	if (self.active >= self.budget.max_views) return SHADOW_VIEW_NONE;
	if (self.texels + texels > self.budget.max_texels) return SHADOW_VIEW_NONE;
	if (self.bytes + bytes > self.budget.max_bytes) return SHADOW_VIEW_NONE;
	uint at = self.find(key);
	if (at == SHADOW_VIEW_NONE)
	{
		// Recycle only a view that was not selected this frame. Cache identity is
		// the stable key, so packed light reordering never aliases another light.
		if (self.count < SHADOW_MAX_VIEWS)
		{
			at = self.count++;
		}
		else
		{
			for (uint i = 0; i < self.count; i++) if (!self.views[i].wanted) { at = i; break; }
			if (at == SHADOW_VIEW_NONE) return SHADOW_VIEW_NONE;
		}
		self.views[at] = { .key = key, .view_projection = matrix::IDENTITY4{float} };
	}
	else if (self.views[at].size != size)
	{
		// Resolution changes retain the identity but never the stored depths.
		self.views[at].static_valid = false;
		self.views[at].live_valid = false;
	}
	self.views[at].size = size;
	self.views[at].live = true;
	self.views[at].wanted = true;
	self.active++;
	self.texels += texels;
	self.bytes += bytes;
	return at;
}

// Call for every candidate before admission. This two-phase mark stops an
// early high-priority light recycling the cached slot of a later candidate.
fn void ShadowViewSet.want_light(&self, uint stable_light, ShadowViewKind kind)
{
	uint parts = shadow_view_parts(kind);
	for (uint part = 0; part < parts; part++)
	{
		uint at = self.find({ .light = stable_light, .part = part, .kind = kind });
		if (at != SHADOW_VIEW_NONE) self.views[at].wanted = true;
	}
}

fn uint shadow_view_parts(ShadowViewKind kind) @inline => kind == ShadowViewKind.POINT ? 6 : 1;

// A light is admitted atomically: a point light never receives three useful
// faces and three missing ones merely because the budget ended halfway through.
fn uint ShadowViewSet.admit_light(&self, uint stable_light, ShadowViewKind kind, uint size,
	usz bytes_per_texel = 4)
{
	uint parts = shadow_view_parts(kind);
	usz texels = (usz)size * (usz)size * parts;
	usz bytes = texels * bytes_per_texel;
	if (self.active + parts > self.budget.max_views || self.texels + texels > self.budget.max_texels
		|| self.bytes + bytes > self.budget.max_bytes) return SHADOW_VIEW_NONE;
	uint first = SHADOW_VIEW_NONE;
	for (uint part = 0; part < parts; part++)
	{
		uint at = self.admit({ .light = stable_light, .part = part, .kind = kind }, size, bytes_per_texel);
		if (first == SHADOW_VIEW_NONE) first = at;
	}
	return first;
}

fn uint ShadowViewSet.find(&self, ShadowViewKey key)
{
	for (uint i = 0; i < self.count; i++) if (self.views[i].key.equals(key)) return i;
	return SHADOW_VIEW_NONE;
}

fn void ShadowView.invalidate(&self, uint signature, uint revision)
{
	if (self.signature == signature && self.static_revision == revision) return;
	self.signature = signature;
	self.static_revision = revision;
	self.static_valid = false;
	self.live_valid = false;
}

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

	<*
	 Whether the map is fitted around what the camera can see, or around the whole
	 scene.

	 **True is the default and is what makes a village's shadows sharp**: a level
	 224 units across framed 70 at a time spends nine tenths of its texels outside
	 the picture, so the fit follows the eye and `Camera.view_sphere` is the shape
	 it follows it with.

	 False is the answer to the cost of that, and the cost is a *rebuild*: the
	 cached static map is a picture in one projection, so every time the fit moves
	 far enough to matter, every static caster is rasterised again. On the Evil
	 Forest scene that is 39 draw calls over 4,800 instances and 0.27 ms against a
	 0.10 ms steady pass — a spike that scales with the scenery, and one a script
	 dragging a turntable can provoke a few times a second. Fitted to the scene
	 instead, nothing about the camera is in the key at all: the map is rebuilt
	 when the light turns, when the scene's bounds change and when a static caster
	 does, and not otherwise.

	 What it costs is texels, and how many is arithmetic a scene can do for itself:
	 the map covers the whole level rather than `distance` units of it, so a 224-
	 unit village at 2048 is 11 cm a texel where a 40-unit fit is 2 cm. `size` is
	 the knob that buys some of that back, and `stats().shadowBytes` is what it
	 costs.

	 **Not a default anything derives.** Which of the two a scene wants depends on
	 how big the level is and on whether the camera moves, and neither is knowable
	 from here — see `plan.md`'s standing constraint about `shadow.size`.
	*>
	bool follow;
}

// The settings a shadow map starts on, and the ones a fresh `Scene` carries.
const ShadowSettings DEFAULT_SHADOW = {
	.enabled = false,
	.distance = 0,
	.size = SHADOW_DEFAULT_SIZE,
	.bias = 0.0,
	.intensity = 1.0,
	// The one field here whose default is not the zero value, which is why both
	// places that build a `ShadowSettings` state it: a forgotten initializer is a
	// scene-fitted map, which works and is coarse, rather than a visible fault.
	.follow = true,
};

const uint POINT_SHADOW_FACES = 6;
const uint POINT_SHADOW_LAYERS = (MAX_LIGHTS - 1) * POINT_SHADOW_FACES;
const uint POINT_SHADOW_MAX_SIZE = 2048;

struct PointShadowSettings
{
	bool enabled;
	uint size;
	float bias;
	float intensity;
}

// Zero-resolution work is opt-in. `size` is retained while disabled so toggling
// does not reinterpret the requested quality.
const PointShadowSettings DEFAULT_POINT_SHADOW = {
	.enabled = false,
	.size = 0,
	.bias = 0.0,
	.intensity = 1.0,
};

// Compatibility state for the point-shadow scripting API. ShadowAtlas owns the
// shared depth storage and ShadowManager owns per-light cache validity.
struct PointShadowMap
{
	inline PointShadowSettings settings;
	uint created;
	bool sample_static;
	uint plan;
	uint static_draws;
	bool live;
	uint draws;
}

fn void PointShadowMap.apply(&self, PointShadowSettings settings)
{
	self.settings = settings;
	self.live = false;
	self.draws = 0;
	self.static_draws = 0;
	self.sample_static = false;
	self.plan = SHADOW_PLAN_FULL;
}

<*
 Directional settings, fitted projection and shared caster pipelines.

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

	vk::Format format;
	// The size the image above really has, and 0 when there is no image. Compared
	// against `size` rather than trusted, because a script may write `size` at any
	// moment and the image can only change between frames.
	uint created;

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

	 A camera that turns *did*, for as long as the focus was a box: `fit` read its
	 extent off an axis-aligned box around an oriented frustum, which grows as it
	 yaws, so the fit moved and this key went with it. `Camera.view_sphere` is the
	 shape that made the sentence above true rather than intended, and
	 `ShadowSettings.follow` is how a scene takes the camera out of the key
	 altogether.
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

	<*
	 The second one, and the only material property that reaches this pass:
	 `material.alphaTest`.

	 A cut-out caster needs a fragment stage to `discard` in and the base colour
	 map to sample, and a depth pass has neither. So there are two pipelines rather
	 than one pipeline with a sampler on it: a scene with no foliage in it declares
	 no binding, pushes no descriptor and taps no texture, and a scene with foliage
	 pays a pipeline object and a bind per bucket.

	 Built by `build_cutout_pipeline` the first frame a cut-out caster is actually
	 in the draw list, on `ensure_static`'s terms — a project that never sets
	 `alphaTest` never compiles it.
	*>
	MeshPipeline cutout_pipeline;
	bool cutout_ready;
	// Set when the cut-out shader would not compile, so the diagnostic is one
	// sentence and not one per frame. Cut-out casters then draw as whole quads,
	// which is the picture this pass drew before the variant existed.
	bool cutout_refused;

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

 The fitted projection and pipelines are retained for the next scene.
*>
fn void ShadowMap.apply(&self, ShadowSettings settings)
{
	self.settings = settings;
	self.light_view_projection = matrix::IDENTITY4{float};
	self.live = false;
	self.draws = 0;
	// The compatibility key is forgotten when the active scene changes.
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
 Compiles the depth-only caster pipeline on first use.
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
 Compiles the cut-out variant of the same file and builds the pipeline that
 draws `material.alphaTest` casters, once.

 Later than `build_pipeline` and for a stricter reason than "shadows may never be
 switched on": most scenes that *do* use shadows still have no cut-out in them, so
 this is a Slang compile and a `VkPipeline` charged to the first frame in which
 something actually asks. `MeshPass.plan_shadow` is what asks, and it asks from
 the same place `ensure_static` is called from — between frames.

 ## The define, and why it is a second compile

 `shaders/shadow.slang` guards its sampler, its varying and its fragment stage
 behind `THREE_SHADOW_CUTOUT`, and this prepends the definition. Two compiles
 rather than one module with two programs, because reflection reports the *linked
 program*: a sampler declared anywhere in the source would land in the layout of
 the pipeline every ordinary caster shares, and a declared binding that nothing
 writes is undefined behaviour rather than an unused slot.

 `#line 1` after the define, so a Slang diagnostic still names the line the file
 has. `shader/assemble.c3` solves the same problem the other way — it swaps a
 marker line for the define, keeping the line count — and either is fine; this
 file has no marker to swap.

 @return ? SHADER_MISSING_ENTRY_POINT : `The cut-out variant would not compile. The diagnostic is printed, for build_pipeline's reason.`
*>
fn void? ShadowMap.build_cutout_pipeline(&self, Gpu* gpu)
{
	if (self.cutout_ready) return;

	String source = shader_source("shadow.slang", mem)!;
	defer source.free(mem);

	DString variant;
	variant.init(mem);
	defer variant.free();
	variant.append_string("#define THREE_SHADOW_CUTOUT 1\n#line 1\n");
	variant.append_string(source);

	ShaderModule mod = compile_slang(variant.str_view(), "shadow.slang", SHADOW_CUTOUT_ENTRIES[..])!;
	defer mod.free();
	if (!mod.ok)
	{
		@advise("three: the cut-out shadow shader would not compile: %s", mod.diagnostic);
		return SHADER_MISSING_ENTRY_POINT~;
	}

	self.cutout_pipeline.init_shadow(gpu, &mod, self.format, cutout: true)!;
	self.cutout_ready = true;
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
 *square*: the diameter of the focus sphere when there is one, and otherwise
 the focus box's diagonal.

 The two are not equally good and the difference is what `Camera.view_sphere`
 exists for. A diagonal is invariant for a box that *rotates rigidly* and the
 focus box does not — it is an axis-aligned box re-bounded around an oriented
 frustum, so it grows as well as drifts, and the extent grows with it. A
 sphere has no orientation to lose, so its diameter is a function of the field
 of view, the aspect and the reach and of nothing a drag can touch. On the
 Evil Forest scene that is the difference between 20 rebuilds in 300 frames of
 a dragged turntable and a handful.
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
 @param focus : `The part of it worth spending texels on. A box, or — with focus_radius beside it — a sphere whose centre this is. Omitted, empty or degenerate falls back to bounds, which is what the tests that check the fit itself pass.`
 @param stable : `Whether to hold a fit that is still good rather than recentring on the focus. What a scene with static casters wants; see above for what it costs.`
 @param focus_radius : `The focus sphere's radius, or 0 for a focus that is a box. See Camera.view_sphere: a sphere is the shape a turning camera cannot resize, and it is the one MeshPass.prepare passes. Ignored once the sphere is as big as the scene, which is fitted as a box instead.`
*>
fn void ShadowMap.fit(
	&self,
	float[4] light,
	collision::Aabb3 bounds,
	collision::Aabb3 focus = { },
	bool stable = false,
	float focus_radius = 0
)
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
	if (span3.x <= 0.0f || span3.y <= 0.0f || span3.z <= 0.0f)
	{
		focus = bounds;
		focus_radius = 0;
	}

	// The cap, and it decides which of the two focus shapes below is used as well
	// as bounding the answer: a focus at least as big as the scene *is* the scene,
	// and fitting the scene is both tighter and stiller than fitting a sphere
	// around it.
	float ceiling = math::max(box.max.x - box.min.x, box.max.y - box.min.y);
	bool sphere   = focus_radius > 1e-4f && focus_radius * 2.0f < ceiling;

	collision::Aabb3 lit = focus.transform_matrix(view);
	float extent;
	if (sphere)
	{
		// A view matrix is a rotation and a translation, so it takes a sphere to a
		// sphere: the light-space square is the transformed centre and the same
		// radius, exactly. Nothing is re-bounded, which is the whole point — a
		// re-bounded box is a box and grows as it turns.
		Vec3 middle = transform_point(view, focus.center());
		lit = {
			.min = { middle.x - focus_radius, middle.y - focus_radius, lit.min.z },
			.max = { middle.x + focus_radius, middle.y + focus_radius, lit.max.z },
		};
		extent = focus_radius * 2.0f;
	}
	else
	{
		// The diagonal, so that orbiting the camera cannot change it — and capped at
		// the scene's own light-space extent, so a camera which frames everything is
		// fitted exactly as it was before this existed.
		//
		// It is the *box's* diagonal and so it does still change: an axis-aligned
		// box around an oriented frustum grows as it yaws. That is what
		// `Camera.view_sphere` and the branch above exist to take away, and this
		// half is what a caller that hands over a plain box still gets.
		extent = (focus.max - focus.min).length();
	}
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

fn void ShadowMap.free(&self, Gpu* gpu)
{
	if (self.pipeline_ready) self.pipeline.free(gpu);
	self.pipeline_ready = false;
	if (self.cutout_ready) self.cutout_pipeline.free(gpu);
	self.cutout_ready = false;
	self.cutout_refused = false;
}

fn Matrix4f point_shadow_matrix(Light light, uint face)
{
	Vec3[6] directions = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
	Vec3[6] ups = { { 0, -1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 }, { 0, -1, 0 }, { 0, -1, 0 } };
	Vec3 eye = { light.direction[0], light.direction[1], light.direction[2] };
	float far_plane = light.direction[3];
	float near_plane = math::max(far_plane * 0.001f, math::min(0.01f, far_plane * 0.5f));
	return matrix::perspective{float}(math::PI / 2.0f, 1.0f, near_plane, far_plane)
		* matrix::look_at{float}(eye, eye + directions[face], ups[face]);
}

fn void PointShadowMap.free(&self, Gpu* gpu)
{
	*self = { };
}
