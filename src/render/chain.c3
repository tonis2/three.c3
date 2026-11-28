<*
 The post chain: three images, two rules, and the one interface in this project.

 `c3c test --trust=full --test-noleak --test-filter three_tests::post`

 ## What a frame is

 inactive scene
 ─────────────────────────────────────────►
 target.color ─► blit
 tone only scene ─► A ──────────────────────► tonemap ─►
 target.color ─► blit
 one pass scene ─► A ─► P0 ─────────────────────► tonemap ─►
 target.color ─► blit
 three      scene ─► A ─► P0 ─► P1 ─► P0 ─► tonemap ─► target.color ─► blit

 Three images regardless of how long the chain is. A is what the scene renders
 into (`PostPass.scene`), and P0/P1 are the ping-pong pair every pass after the
 first writes and the next one reads. A chain of one uses P0 and never allocates
 P1; a chain of none allocates nothing and is byte-identical to a frame from
 before any of this existed.

 `three.toneMapping = 'agx'` is the second row: no pass of the script's, so the
 tonemap reads A the way a first pass does and neither ping-pong image is
 allocated. That is the whole of what a tone curve costs when nothing else is
 running — one attachment and one draw.

 The two rules are the whole scheduler:

 pass i     reads P[(i-1)&1] as `prev` — or A, when i is 0 — and A as `scene`
 writes P[i&1]
 tonemap    reads P[(N-1)&1], writes target.color

 ## Why a chain and not a graph

 In a chain, adjacency *is* the edge set. A general DAG needs explicit edges
 precisely because list position no longer says who reads whom, so constraining
 the topology derives the barriers for nothing.

 The one non-adjacent read anybody actually wants is the original picture — bloom
 is `blur(bright(scene)) + scene`, which needs the frame three passes later — and
 that is `scene` at binding 1. What would change the answer is a *script* naming
 which pass's output another pass reads, where the answer is not its predecessor;
 pass count is not the trigger.

 ## Why the tonemap is the engine's and always last

 `gpu/pipeline.c3` declares a pipeline's colour attachment format at build time.
 If the last pass of a chain wrote `target.color` directly, then the same body at
 slot 3 and at slot N would be two different `VkPipeline`s, output format would
 enter the pipeline cache key, and reordering a chain would be a recompile.

 So every script-authored pass reads float and writes float, and one fixed
 engine-owned pass does the encode into `target.color`. One pipeline shape for
 every body, no format in the key, free reordering — and a body that forgot to
 encode stops being expressible.

 The cost: a chain of one is two draws where it used to be one, and it allocates
 P0 where it used to allocate nothing past A. Paid only by frames that asked for
 a post pass at all.
*>
module three;

import std::collections::list;
import vk;

<*
 What every pass in the chain writes, and what every pass but the first reads.

 `R16G16B16A16_SFLOAT`, so the chain runs in linear HDR: a pass may write above
 1.0 and the next one still sees it, which is what a bright pass followed by a
 blur — the shape of every bloom — needs and what an 8-bit intermediate destroys.
 Nothing decodes on the way in and nothing encodes on the way out; the values are
 the numbers the body returned.

 Image A is deliberately not this format: it is what the scene's own pipelines
 render into, and their colour format is fixed at build time from
 `target.color_format`.

 No feature check and none needed — `R16G16B16A16_SFLOAT` is one of the formats
 every conformant implementation must support as a colour attachment and as a
 linearly-filtered sampled image.
*>
const vk::Format POST_CHAIN_FORMAT = FORMAT_R16G16B16A16_SFLOAT;

<*
 Everything one full-screen pass is handed, and nothing else.

 Each field is something a pass genuinely cannot get anywhere else:

 prev, scene      the two reserved bindings. Two rather than one because the
 chain has two edges; see the header.
 dst, dst_view    the destination. The *image* as well as the view because the
 pass opens it with a barrier and a barrier names an image.
 extent           the viewport, the scissor and `info.xy`.
 sampler          the chain's own — CLAMP_TO_EDGE, so a blur stepping off the
 edge smears the border rather than wrapping the far side of
 the picture in.
 assets           what a pass's *own* samplers resolve through. Null is legal
 and means the reflected bindings above the reserved two get
 nothing, which is only safe on a pass that declared none.

 What is absent is the argument for the interface being scoped to this one kind
 of pass: no `Gpu`, no `Target`, no frame slot, no scene, no instance buffer. A
 geometry pass needs five of those and a full-screen pass needs none, and a
 context carrying the union would be one where you could no longer tell from a
 signature what a pass touches.
*>
struct PassIo
{
	vk::ImageView prev;
	vk::ImageView scene;
	// Null for a side pass: a compute pass that writes only its own images, and
	// whose successor reads what this one read.
	vk::Image dst;
	vk::ImageView dst_view;
	vk::Extent2D extent;
	vk::Sampler sampler;
	// The frame's own depth buffer, already in `DEPTH_STENCIL_READ_ONLY_OPTIMAL` —
	// `record_chain` transitions it once, beside `scene`, and every pass in the
	// frame reads the same image in the same layout.
	vk::ImageView depth;
	// Nearest, and a second sampler for one reason: `D32_SFLOAT` is not required
	// to support linear filtering, and a device that does not would refuse the
	// descriptor. Nothing wants a filtered depth anyway — the two values either
	// side of a silhouette are metres apart and their average is a surface that is
	// not there.
	vk::Sampler depth_sampler;
	// The camera's planes, for the linearisation in `post.shady`. Facts about the
	// frame being recorded, like `extent` and `time`: a pass that read them from
	// the camera itself could be recorded against a camera the frame was not
	// drawn with.
	float near_plane;
	float far_plane;
	// The output of the pass this one named as its third source, already in
	// `SHADER_READ_ONLY_OPTIMAL`. Image A for a pass that named none — the same
	// answer `p.scene` gives, so a body that reads `tap` without a tap would see
	// the frame rather than something undefined. It cannot: `build_stage` refuses
	// that body outright, and this is the belt to that pair of braces.
	vk::ImageView tap;
	Assets* assets;
	// The game clock, in seconds — `scene/clock.c3`. An argument at record time
	// rather than a field on the chain, for the same reason `extent` is one: it is
	// a fact about the frame being recorded, and a pass that read it from
	// somewhere else could be recorded with a time the frame does not have.
	double time;
	// The tonemap over passthrough: it writes the scene's coverage as alpha.
	bool see_through;
	// Which eye of a multiview frame, and so which layer of `dst` and of each
	// pass image; 0 on any other frame, whose images have one layer.
	uint layer;
}

// ============================================================================
// The chain's images
// ============================================================================

<*
 Creates image A and as much of the ping-pong pair as `stages` needs, or moves
 them to a new extent.

 Idempotent: the common call finds everything already there at the right size and
 returns. P1 is allocated only from the second pass on, which is the difference
 between a script that set one post shader and one that built a chain.

 Nothing waits for the device before destroying anything: `GpuImage.free`
 retires its handles through `gpu/retire.c3` and they go two frames later. A
 stall here would be redundant as well as expensive — a resize has already
 recreated the swapchain, which waits idle because the images it replaces belong
 to the presentation engine and cannot be queued.

 @param stages : `How many script passes the chain is about to have. Zero still creates A, because a set that fails to compile has already paid for it.`
*>
fn void? PostPass.ensure_images(&self, Gpu* gpu, Target* target, sz stages)
{
	// A multiview frame runs the chain once per eye, on images an eye in size
	// with a layer for each.
	vk::Extent2D extent = target.views > 1 ? target.view_extent : target.extent;
	uint layers = target.views;
	bool moved = self.extent.width != extent.width || self.extent.height != extent.height || self.layers != layers;
	if (moved && self.extent.width != 0)
	{
		self.destroy_images(gpu);
		// A tapped stage's image has an extent too, and it is not in `pong`. Freed
		// here rather than in `destroy_images`, which `free` also calls after the
		// stages are already gone.
		foreach (stage : self.stages) if (stage.keep.exists()) stage.keep.free(gpu);
	}
	self.extent = extent;
	self.layers = layers;
	// After the extent, because that is what they are created at.
	self.ensure_keeps(gpu)!;

	self.ensure_eyes(gpu, target)!;

	// The scene stays linear and unclamped until the final display encode. Mesh
	// pipelines declare this same format in `MeshPipeline.init`. A multiview
	// target renders into `eyes` instead, and every pass reads its eye's layer.
	if (target.views == 1 && !self.scene.exists()) self.scene = gpu.create_image_2d(POST_CHAIN_FORMAT, self.extent, CHAIN_IMAGE_USAGE)!;

	// P0 from the first script pass on, because the tonemap reads a pong image
	// rather than A once there is one; P1 only from the second. A chain that is
	// the tonemap alone — `three.toneMapping` with no `setPost` — reads A and
	// allocates neither, which is what keeps a tone curve one image rather than
	// two.
	vk::ImageUsageFlags usage = self.pong_usage();
	if (stages >= 1 && !self.pong[0].exists()) self.pong[0] = gpu.create_layered_image(POST_CHAIN_FORMAT, self.extent, self.layers, usage)!;
	if (stages >= 2 && !self.pong[1].exists()) self.pong[1] = gpu.create_layered_image(POST_CHAIN_FORMAT, self.extent, self.layers, usage)!;

	self.ensure_post_images(gpu)!;
	self.ensure_sampler(gpu)!;
}

<*
 The scene's layers, which a multiview target renders into in place of A. Freed
 again for a one-view target, and A for a multiview one.
*>
fn void? PostPass.ensure_eyes(&self, Gpu* gpu, Target* target)
{
	if (target.views == 1)
	{
		if (self.eyes.exists()) self.eyes.free(gpu);
		return;
	}
	if (self.scene.exists()) self.scene.free(gpu);
	if (!self.eyes.exists())
	{
		self.eyes = gpu.create_layered_image(POST_CHAIN_FORMAT, target.view_extent, target.views, CHAIN_IMAGE_USAGE)!;
	}
}

<*
 Where the scene renders: A, or a multiview target's layers.
*>
fn GpuImage* PostPass.scene_target(&self) => self.eyes.exists() ? &self.eyes.whole : &self.scene;

<*
 One eye of the rendered scene, as a pass samples it: its layer of a multiview
 target, or A.
*>
fn vk::ImageView PostPass.scene_view(&self, uint eye) => self.eyes.exists() ? self.eyes.layer_view(eye) : self.scene.view;

<*
 One eye of the frame's depth, as a pass samples it.
*>
fn vk::ImageView PostPass.depth_view(&self, Target* target, uint eye) => self.eyes.exists() ? target.depth_layer(eye) : target.depth_view;

<*
 What a stage reads as `prev` in one eye.
*>
fn vk::ImageView PostPass.source_view(&self, sz stage, uint eye)
{
	LayeredImage* from = self.source_of(stage);
	return from != null ? from.layer_view(eye) : self.scene_view(eye);
}

<*
 What a pass's destination is created with: an attachment, and a storage image
 too once the chain has had a compute pass. Image A is never a destination, so it
 never needs it.
*>
fn vk::ImageUsageFlags PostPass.pong_usage(&self)
{
	return self.storage ? CHAIN_IMAGE_USAGE | IMAGE_USAGE_STORAGE_BIT : CHAIN_IMAGE_USAGE;
}

<*
 Makes every pass destination a storage image, before the first compute pass is
 built.

 By recreating them: a usage bit is fixed when an image is made. The images go
 through the deletion queue like any other, so frames in flight keep theirs, and
 the next frame opens the new ones from `UNDEFINED` as it does every frame. Once
 and for good - a chain that had a compute pass once is likely to again, and the
 flag going back would be a second recreation for nothing.
*>
fn void? PostPass.ensure_storage(&self, Gpu* gpu)
{
	if (self.storage) return;
	self.storage = true;
	self.pong[0].free(gpu);
	self.pong[1].free(gpu);
	foreach (stage : self.stages) if (stage.keep.exists()) stage.keep.free(gpu);
	if (self.extent.width == 0) return;
	self.ensure_keeps(gpu)!;
}

<*
 How A and the ping-pong images are read.

 CLAMP_TO_EDGE rather than REPEAT, unlike every other sampler in this project: a
 blur steps off the edge of the frame by construction, and wrapping there puts
 the opposite edge of the picture into the border rather than smearing the border
 itself.

 One sampler for all three images and for every pass. There is nothing per-pass
 about it — the addressing and the filter are properties of "this is a
 full-screen image being read at screen resolution".
*>
fn void? PostPass.ensure_sampler(&self, Gpu* gpu)
{
	if (self.depth_sampler == null)
	{
		// Nearest, and not a shortcut. `D32_SFLOAT` is not required to advertise
		// `SAMPLED_IMAGE_FILTER_LINEAR`, so a linear sampler on it is a descriptor
		// a conformant device may refuse; and a filtered depth is meaningless where
		// it would matter, because the two texels either side of a silhouette are
		// metres apart and their average is a surface that does not exist.
		// CLAMP_TO_EDGE for the colour sampler's reason.
		self.depth_sampler = gpu.clamp_sampler(FILTER_NEAREST, BORDER_COLOR_INT_OPAQUE_BLACK)!;
	}
	if (self.sampler != null) return;
	self.sampler = gpu.clamp_sampler(FILTER_LINEAR, BORDER_COLOR_INT_OPAQUE_BLACK)!;
}

fn void PostPass.destroy_images(&self, Gpu* gpu)
{
	self.scene.free(gpu);
	self.eyes.free(gpu);
	self.pong[0].free(gpu);
	self.pong[1].free(gpu);
	self.extent = { };
}

// ============================================================================
// A pass's own images
// ============================================================================

<*
 A storage image post passes declared for themselves: a history a temporal
 effect reads back next frame, a histogram one pass builds and the next reduces.

 **The chain's, not a pass's.** Two passes that declare the same name, format and
 size bind the same image - that is how one pass hands another something that is
 not a frame - and the image lives as long as any pass declares it. `users` is
 that count. `PostPass.set` reuses an image whose declaration it repeats exactly,
 so live-editing a temporal effect's body keeps its history rather than starting
 it over.

 Starts at zero (`fresh`), and is zeroed again whenever it is remade - a resize,
 for one the size of the frame. `per_frame` zeroes it at the start of every
 frame too, for an accumulator that is about one frame.

 Always in `GENERAL`: every reader and writer is a shader, and a layout change
 per pass would be a barrier per pass for nothing.

 A layer per eye on a multiview frame, so each eye keeps its own history.
*>
struct PostImage
{
	String name;
	StorageImageFormat format;
	// As declared. Zero is the frame's own size, which `extent` then follows.
	uint width;
	uint height;
	bool per_frame;
	LayeredImage image;
	vk::Extent2D extent;
	bool fresh;
	uint users;
}

fn bool PostImage.matches(&self, PostImageDecl decl)
{
	return self.name == decl.name && self.format.name == decl.format
		&& self.width == decl.width && self.height == decl.height && self.per_frame == decl.per_frame;
}

fn void write_image_conflict(String* diagnostic, PostImage* existing, PostImageDecl decl)
{
	if (diagnostic == null) return;
	@pool()
	{
		*diagnostic = string::format(mem,
			"post: image '%s' is already in the chain as %s %s, and this pass declares it %s %s - "
				"one name is one image",
			decl.name, existing.format.name, image_size_words(existing.width, existing.height),
			decl.format, image_size_words(decl.width, decl.height));
	};
}

<*
 The image a declaration names: one the chain already has under that name, or a
 new one.

 An existing image under the name with a different format, size or clear is a
 conflict for `add` - two passes cannot mean two images by one name - and is
 passed over for `set`, which is about to drop the passes that declared it. The
 new image then lives beside it until they go.

 @param replacing : `True from set: the chain's current passes are about to be dropped.`
 @return? POST_IMAGE_CONFLICT : `An existing image of that name was declared differently. diagnostic says how.`
 @return? STORAGE_FORMAT_UNSUPPORTED : `This device cannot store to the format.`
*>
fn PostImage*? PostPass.claim_image(&self, Gpu* gpu, PostImageDecl decl, bool replacing, String* diagnostic)
{
	PostImage* conflict = null;
	foreach (image : self.images)
	{
		if (image.name != decl.name) continue;
		if (image.matches(decl))
		{
			image.users++;
			return image;
		}
		conflict = image;
	}
	if (conflict != null && !replacing)
	{
		write_image_conflict(diagnostic, conflict, decl);
		return POST_IMAGE_CONFLICT~;
	}

	StorageImageFormat format = storage_format_named(decl.format)!;
	if (!gpu.can_have_storage(format))
	{
		if (diagnostic != null)
		{
			*diagnostic = string::format(mem, "post: image '%s' is %s, which this device cannot store to", decl.name,
				decl.format);
		}
		return STORAGE_FORMAT_UNSUPPORTED~;
	}

	PostImage* made = mem::new(PostImage);
	defer catch mem::free(made);
	*made = {
		.name = decl.name.copy(mem),
		.format = format,
		.width = decl.width,
		.height = decl.height,
		.per_frame = decl.per_frame,
		.users = 1,
	};
	defer catch made.name.free(mem);
	made.ensure(gpu, self.extent, self.layers)!;
	self.images.push(made);
	return made;
}

fn String image_size_words(uint width, uint height)
{
	return width == 0 ? "the size of the frame" : string::tformat("%dx%d", width, height);
}

<*
 One user fewer, and the image gone with the last.
*>
fn void PostPass.release_image(&self, Gpu* gpu, PostImage* image)
{
	if (image.users > 1)
	{
		image.users--;
		return;
	}
	foreach (i, held : self.images)
	{
		if (held != image) continue;
		self.images.remove_at(i);
		break;
	}
	image.image.free(gpu);
	image.name.free(mem);
	mem::free(image);
}

<*
 Makes the image exist at the size it should be, its own or the frame's, with a
 layer for each eye. Remade is remade empty, and marked to be zeroed before its
 first use.

 @param frame : "One eye's extent"
 @param layers : "Eyes the frame has"
 @require layers >= 1 : "At least one layer"
*>
fn void? PostImage.ensure(&self, Gpu* gpu, vk::Extent2D frame, uint layers)
{
	vk::Extent2D wanted = self.width == 0 ? frame : { .width = self.width, .height = self.height };
	if (wanted.width == 0 || wanted.height == 0) return;
	if (self.image.exists() && self.extent.width == wanted.width && self.extent.height == wanted.height
		&& self.image.count == layers) return;
	self.image.free(gpu);
	self.image = gpu.create_layered_image(self.format.vk, wanted, layers, IMAGE_USAGE_STORAGE_BIT | IMAGE_USAGE_TRANSFER_DST_BIT)!;
	self.extent = wanted;
	self.fresh = true;
}

fn void? PostPass.ensure_post_images(&self, Gpu* gpu)
{
	foreach (image : self.images) image.ensure(gpu, self.extent, self.layers)!;
}

<*
 Zeroes every image that needs it before the frame's first pass: a new one, a
 remade one, and every `per_frame` one.

 A clear is a transfer write, so each is fenced on both sides: after every shader
 that touched the image last frame, and before every one that touches it this
 frame.
*>
fn void PostPass.open_images(&self, vk::CommandBuffer cmd)
{
	foreach (image : self.images)
	{
		if (!image.image.exists() || (!image.fresh && !image.per_frame)) continue;
		vk::ImageMemoryBarrier2 before = {
			...IMAGE_BARRIER,
			.image = image.image.whole.image,
			.srcStageMask = image.fresh ? PIPELINE_STAGE_2_NONE : CHAIN_READERS,
			.srcAccessMask = image.fresh ? (vk::AccessFlags2)0 : ACCESS_2_SHADER_STORAGE_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_CLEAR_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = image.fresh ? IMAGE_LAYOUT_UNDEFINED : IMAGE_LAYOUT_GENERAL,
			.newLayout = IMAGE_LAYOUT_GENERAL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ before }));
		vk::ClearColorValue zero = { .uint32 = { 0, 0, 0, 0 } };
		vk::cmdClearColorImage(cmd, image.image.whole.image, IMAGE_LAYOUT_GENERAL, &zero, 1, &COLOR_LEVEL);
		vk::ImageMemoryBarrier2 after = {
			...IMAGE_BARRIER,
			.image = image.image.whole.image,
			.srcStageMask = PIPELINE_STAGE_2_CLEAR_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = CHAIN_READERS,
			.dstAccessMask = ACCESS_2_SHADER_STORAGE_READ_BIT | ACCESS_2_SHADER_STORAGE_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_GENERAL,
			.newLayout = IMAGE_LAYOUT_GENERAL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ after }));
		image.fresh = false;
	}
}

fn void PostPass.free_post_images(&self, Gpu* gpu)
{
	foreach (image : self.images)
	{
		image.image.free(gpu);
		image.name.free(mem);
		mem::free(image);
	}
	self.images.clear();
}

// ============================================================================
// The tonemap — the engine's own pass, and the only writer of target.color
// ============================================================================

<*
 Which curve the engine's last pass puts the frame through.

 Calls into `shaders/tonemap.shady`, which a scene drawing straight into a
 headset's eye images applies too, so both display paths agree.
 `NONE` is the default identity encode.
*>
enum ToneMap : char (String name, String body)
{
	NONE {
		"none",
		`fn float3 post(Post p)
{
	return p.color;
}`,
	},
	AGX {
		"agx",
		`fn float3 post(Post p)
{
	return tone_agx(p.color * p.uniforms.exposure);
}`,
	},
	AGX_BLENDER {
		"agx-blender",
		`fn float3 post(Post p)
{
	return tone_agx_blender(p.color * p.uniforms.exposure);
}`,
	},
}

// What AgX's exposure uniform is called, in the body and in the push block.
const String TONEMAP_EXPOSURE = "exposure";

<*
 Compiles the tonemap, and recompiles it when the mode changes.

 The exposure survives the recompile because it is a uniform, not part of the
 string: `apply_exposure` writes it into the block against the new module's
 reflected offset. Its pipeline is built with `target.color_format`.
*>
fn void? PostPass.ensure_tonemap(&self, Gpu* gpu, Target* target)
{
	if (self.tonemap.pipeline.handle != null && self.tonemap_built == self.tonemap_mode) return;

	// Retired rather than destroyed: this can run on a live renderer, and frames
	// in flight may still have the old pipeline bound.
	if (self.tonemap.pipeline.handle != null) gpu.retire_pipeline(self.tonemap.pipeline);
	self.tonemap.pipeline = { };

	ToneMap mode = self.tonemap_mode;
	// Only the curves declare exposure; the identity would have the compiler
	// drop an unread uniform before reflection sees it.
	MaterialUniform[1] uniforms = { { .name = TONEMAP_EXPOSURE, .components = 1, .rows = 1 } };
	MaterialUniform[] declared = mode != ToneMap.NONE ? uniforms[..] : {};

	@pool()
	{
		ShaderModule mod = compile_shader(ShaderPass.POST, body: mode.body, uniforms: declared)!;
		defer mod.free();
		if (!mod.ok) return SHADER_COMPILE_FAILED~;
		self.tonemap.pipeline.init_post(gpu, &mod, target.color_format)!;
	};
	self.tonemap_built = mode;
	self.apply_exposure();
	self.tonemap.set_at = self.now;
}

<*
 Puts `tonemap_exposure` into the tonemap's push block.

 Silent on the identity, where there is no such field.
*>
fn void PostPass.apply_exposure(&self)
{
	if (self.tonemap.pipeline.handle == null) return;
	ShaderField* field = self.tonemap.pipeline.shader.uniform_of(TONEMAP_EXPOSURE);
	if (field == null || field.size != float::size) return;
	float value = self.tonemap_exposure;
	mem::copy(&self.tonemap.block[field.offset], &value, float::size);
}

<*
 `three.toneMapping = 'agx'` — which curve the frame ends on.

 @param mode : `The curve. NONE is the identity and is where a renderer starts.`
*>
fn void? PostPass.set_tonemap(&self, Gpu* gpu, Target* target, ToneMap mode)
{
	if (mode == self.tonemap_mode) return;
	self.tonemap_mode = mode;
	self.ensure_images(gpu, target, self.stages.len())!;
	self.ensure_tonemap(gpu, target)!;
}

<*
 `three.toneMappingExposure = 2` — a stop up, and no compile.

 @param value : `A multiplier applied before the curve. Only AgX reads it.`
*>
fn void PostPass.set_tonemap_exposure(&self, float value)
{
	self.tonemap_exposure = value;
	self.apply_exposure();
}

// ============================================================================
// Recording
// ============================================================================

<*
 Whether any pass in the chain, the tonemap included, samples the depth buffer.
 When none does, the scene need not write its depth back.
*>
fn bool PostPass.reads_depth(&self)
{
	if (pipeline_declares_binding(&self.tonemap.pipeline, PostBinding.DEPTH)) return true;
	foreach (stage : self.stages)
	{
		if (pipeline_declares_binding(&stage.pipeline, PostBinding.DEPTH)) return true;
	}
	return false;
}

<*
 Runs the chain: every script pass in order, then the tonemap into
 `target.color`.

 Called from `Renderer.record_scene` with the scene's rendering already ended —
 both frame paths end it, which is what makes the close below happen exactly once
 and in one place.

 ## The barriers

 One per edge, not one per pass:

 - A → SHADER_READ_ONLY_OPTIMAL, once, before anything reads it. It is `scene` at
 binding 1 for every pass and `prev` at binding 0 for the first, so one
 transition covers every use of it in the frame.
 - P[i] → SHADER_READ_ONLY_OPTIMAL after pass i, because pass i+1 samples it.
 - the destination's `UNDEFINED → COLOR_ATTACHMENT_OPTIMAL` is the *pass's own*,
 not issued here. That is the protocol on `FullscreenPass`, and it lets an
 implementation that renders into its destination more than once — a pyramid —
 open it as many times as it needs to.

 `color_attachment_barrier` discards from `UNDEFINED`, which is already correct
 for reusing P0 on pass 2 after pass 1 sampled it: the pass covers every pixel.

 Merging the close of one pass with the open of the next into a single
 two-element `cmdPipelineBarrier2` is possible and is not done, because it would
 move the open back out of the pass and no measurement says the extra call costs
 anything.

 @param now : `The game clock in seconds. Every stage is told it, and a stage set from here on is stamped against it.`
 @param output : "Where the tonemap writes, instead of target.color; null for the target"
 @param output_view : "A view of output"
*>
fn void? PostPass.record_chain(
	&self,
	vk::CommandBuffer cmd,
	Target* target,
	Assets* assets = null,
	double now = 0,
	float near_plane = 0,
	float far_plane = 0,
	bool scene_cached = false,
	vk::Image output = (vk::Image)null,
	vk::ImageView output_view = (vk::ImageView)null,
	bool see_through = false
)
{
	sz count = self.stages.len();
	// The chain runs for the tonemap alone — that is what `three.toneMapping`
	// switches on — so there is no early return for an empty stage list, only the
	// loop below running zero times and the tonemap reading A.
	// Kept so a stage compiled *between* frames has something to stamp itself
	// against. At worst one frame stale, which is the difference between `p.time`
	// starting at zero and starting at a sixtieth; threading the clock into every
	// `set` call site would put the same number in two places for that.
	self.now = now;

	// A multiview frame's scene and depth are layers the passes read an eye at a
	// time; a flat one's are A and the target's depth.
	bool layered = self.eyes.exists();
	if (layered)
	{
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({
			shader_read_barrier(self.eyes.whole.image), depth_read_barrier(target.depth) }));
	}
	else if (!scene_cached)
	{
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo()
			.setImageMemoryBarriers(
				{
					shader_read_barrier(self.scene.image),
					depth_read_barrier(target.depth),
				}
			));
	}

	// Before any pass reads them: a new image, a remade one and a per-frame one
	// start the frame at zero.
	self.open_images(cmd);

	// **Each eye is a frame of its own.** A pass runs once per eye, on that eye's
	// layer of every image, so `p.uv` and `p.resolution` are the eye's, a blur
	// clamps at the eye's edge rather than reading the other eye across the seam,
	// and a history image keeps one history per eye. Each run opens only its own
	// layer of the destination; the close below hands both on at once.
	uint eyes = layered ? self.layers : 1;
	foreach (i, stage : self.stages)
	{
		LayeredImage* dst  = stage.writes_output ? self.output_of(i) : null;
		int tapped         = stage.tap;

		for (uint eye = 0; eye < eyes; eye++)
		{
			vk::ImageView scene = self.scene_view(eye);
			stage.record(
				cmd,
				{
					.prev = self.source_view(i, eye),
					.scene = scene,
					.dst = dst == null ? (vk::Image)null : dst.whole.image,
					.dst_view = dst == null ? (vk::ImageView)null : dst.layer_view(eye),
					.extent = self.extent,
					.sampler = self.sampler,
					.depth = self.depth_view(target, eye),
					.depth_sampler = self.depth_sampler,
					.near_plane = near_plane,
					.far_plane = far_plane,
					.tap = tapped >= 0 ? self.output_of((sz)tapped).layer_view(eye) : scene,
					.assets = assets,
					.time = now,
					.layer = eye,
				}
			)!;
		}

		if (dst != null)
		{
			vk::ImageMemoryBarrier2 close = stage.close_barrier(dst.whole.image);
			vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ close }));
		}
		// What this pass stored into its own images, before the next pass - or the
		// next frame - reads or rewrites them.
		if (stage.image_count > 0)
		{
			vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setMemoryBarriers({ storage_memory_barrier() }));
		}
	}

	if (layered)
	{
		self.record_tonemap_eyes(cmd, target, count, assets, now, near_plane, far_plane, output, output_view, see_through);
		return;
	}

	// The one pass that writes `target.color`, and the one pipeline in the chain
	// built with its format.
	self.tonemap.record(
		cmd,
		{
			.prev = self.source_view(count, 0),
			.scene = self.scene.view,
			.dst = output != null ? output : target.color,
			.dst_view = output != null ? output_view : target.color_view,
			.extent = self.extent,
			.sampler = self.sampler,
			.depth = target.depth_view,
			.depth_sampler = self.depth_sampler,
			.near_plane = near_plane,
			.far_plane = far_plane,
			.tap = self.scene.view,
			.assets = assets,
			.time = now,
			.see_through = see_through,
		}
	)!;
}

<*
 The tonemap over a multiview frame: each eye's layer of what the chain left
 into its half of `output`, or of `target.color`, in one rendering. Expects the
 eyes and the depth already open for reading.

 @param count : "Stages the chain ran; what the last of them wrote is what is tonemapped"
*>
fn void PostPass.record_tonemap_eyes(&self, vk::CommandBuffer cmd, Target* target, sz count, Assets* assets, double now,
	float near_plane, float far_plane, vk::Image output, vk::ImageView output_view, bool see_through = false)
{
	PassIo[MAX_VIEWS] views;
	for (uint i = 0; i < target.views; i++)
	{
		vk::ImageView eye = self.eyes.layer_view(i);
		views[i] = {
			.prev = self.source_view(count, i),
			.scene = eye,
			.dst = output != null ? output : target.color,
			.dst_view = output != null ? output_view : target.color_view,
			.extent = target.view_extent,
			.sampler = self.sampler,
			.depth = target.depth_layer(i),
			.depth_sampler = self.depth_sampler,
			.near_plane = near_plane,
			.far_plane = far_plane,
			.tap = eye,
			.assets = assets,
			.time = now,
			.see_through = see_through,
			.layer = i,
		};
	}
	self.tonemap.record_side_by_side(cmd, views[:target.views], target.extent);
}
