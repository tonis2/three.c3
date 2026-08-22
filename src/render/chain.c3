<*
 The post chain: three images, two rules, and the one interface in this project.

	`c3c test --trust=full --test-noleak --test-filter three_tests::post`

 ## What a frame is, once there is more than one full-screen pass

	inactive   scene ─────────────────────────────────────────► target.color ─► blit
	one pass   scene ─► A ─► P0 ─────────────────────► tonemap ─► target.color ─► blit
	three      scene ─► A ─► P0 ─► P1 ─► P0 ─► tonemap ─► target.color ─► blit

 **Three images regardless of how long the chain is.** A is what the scene renders
 into — `PostPass.scene`, which `render/post.c3` still calls image A — and P0/P1
 are the ping-pong pair every pass after the first writes and the next one reads.
 A chain of one uses P0 and never allocates P1; a chain of none allocates nothing
 and is byte-identical to a frame from before any of this existed, because it is
 the same two calls it always was.

 The two rules, and they are the whole scheduler:

	pass i     reads P[(i-1)&1] as `prev` — or A, when i is 0 — and A as `scene`
	           writes P[i&1]
	tonemap    reads P[(N-1)&1], writes target.color

 ## Why this is a chain and not a graph

 `plan.md` §13 argues it at length and the sentence that carries it is: **in a
 chain, adjacency is the edge set.** A general DAG needs explicit edges precisely
 because list position no longer says who reads whom; a chain does not have that
 problem, so constraining the topology derives the barriers for nothing.

 The one non-adjacent read anybody actually wants is the original picture — bloom
 is `blur(bright(scene)) + scene`, which needs the frame three passes later — and
 that is `scene` at binding 1. **The edge people reach for a solver to express is
 a binding.** What would change the answer is a *script* naming which pass's
 output another pass reads, where the answer is not its predecessor; at that point
 no human is left in the loop and a solver is the honest response. Pass count is
 not the trigger and never was.

 ## Why the tonemap is the engine's and always last

 `gpu/pipeline.c3` declares a pipeline's colour attachment format at build time.
 If the last pass of a chain wrote `target.color` directly, then the same body at
 slot 3 and at slot N would be two different `VkPipeline`s, output format would
 enter the pipeline cache key, and **reordering a chain would be a recompile**.

 So the decision is taken away from user passes entirely: every script-authored
 pass reads float and writes float, and one fixed engine-owned pass does the
 encode into `target.color`. One pipeline shape for every body, no format in the
 key, free reordering — and a body that forgot to encode stops being expressible,
 which is the washed-out failure `plan.md` §10 carries as a trap.

 The cost is honest and worth writing down: a chain of one is two draws where it
 used to be one, and it allocates P0 where it used to allocate nothing past A.
 That is the price of the format decision, paid only by frames that asked for a
 post pass at all.
*>
module three;

import std::collections::list;
import std::time;
import vk;

<*
 What every pass in the chain writes, and what every pass but the first reads.

 `R16G16B16A16_SFLOAT`, so **the chain runs in linear HDR**: a pass may write
 above 1.0 and the next one still sees it, which is what a bright pass followed by
 a blur — the shape of every bloom — needs and what an 8-bit intermediate
 destroys. Nothing decodes on the way in and nothing encodes on the way out; the
 values are the numbers the body returned.

 Image A is deliberately *not* this format and `render/post.c3` has the argument:
 it is what the scene's own pipelines render into, and their colour format is
 fixed at build time from `target.color_format`.

 No feature check and none needed — `R16G16B16A16_SFLOAT` is one of the formats
 every conformant implementation must support as a colour attachment and as a
 linearly-filtered sampled image.
*>
const vk::Format POST_CHAIN_FORMAT = FORMAT_R16G16B16A16_SFLOAT;

<*
 An owned colour image that a pass writes and a later pass samples.

 Image A and the two ping-pong images are the same three objects with the same
 three lifetimes, so they are one struct rather than nine fields on the chain.
 `Target` does not use it: its colour image carries `TRANSFER_SRC` for the
 readback and its depth image is not colour at all.
*>
struct ChainImage
{
	vk::Image image;
	vk::ImageView view;
	vk::Memory memory;
}

<*
 Create the image, its memory and its view.

 `COLOR_ATTACHMENT` because a pass writes it and `SAMPLED` because the next one
 reads it, and nothing else: none of these is ever blitted or copied out — only
 `target.color` is, and that one is `Target`'s.

 @require self.image == null : `already created; free it first`
*>
fn void? ChainImage.init(&self, Gpu* gpu, vk::Format format, vk::Extent2D extent)
{
	self.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(format)
		.setExtent({ .width = extent.width, .height = extent.height, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setUsage(IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.build(gpu.handle)!;
	self.memory = vk::create_image_buffer(self.image, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	self.view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(format)
		.setSubresourceRange(
			{ .aspectMask = IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 }
		)
		.setImage(self.image)
		.build(gpu.handle)!;
}

<*
 `vk::Memory.free` destroys the image it was bound to, so the image must not be
 destroyed again here — the view is the only extra. `Target.free` says the same.

 Idempotent, because the chain frees images it may never have created.
*>
fn void ChainImage.free(&self, Gpu* gpu)
{
	if (self.view != null) self.view.free(gpu.handle);
	self.memory.free();
	*self = {};
}

fn bool ChainImage.exists(&self) => self.image != null;

<*
 Everything one full-screen pass is handed, and nothing else.

 `plan.md` §13 sketched this as three fields — source view, destination view,
 extent — and it is seven, each of which is something a pass genuinely cannot get
 anywhere else:

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

 What is deliberately absent is the whole argument for the interface being scoped
 to this one kind of pass: no `Gpu`, no `Target`, no frame slot, no scene, no
 instance buffer. A geometry pass needs five of those and a full-screen pass needs
 none, and a context carrying the union would be one where you could no longer
 tell from a signature what a pass touches.
*>
struct PassIo
{
	vk::ImageView prev;
	vk::ImageView scene;
	vk::Image dst;
	vk::ImageView dst_view;
	vk::Extent2D extent;
	vk::Sampler sampler;
	Assets* assets;
}

<*
 One full-screen pass over the frame.

 **The protocol, which the interface cannot express and every implementer must
 honour:** on entry `prev` and `scene` are in `SHADER_READ_ONLY_OPTIMAL` and `dst`
 is in whatever the last frame left — open it with `color_attachment_barrier`,
 which discards from `UNDEFINED`. On exit `dst` is in `COLOR_ATTACHMENT_OPTIMAL`
 with rendering ended. `target.depth` is not yours and neither is `target.color`,
 unless you are the tonemap.

 Both halves of that are real and neither is expressible in a signature. The
 layout half is at least *checked*: `plan.md` §13's second entry is the whole
 story of finding out that a missing barrier is only visible to validation as a
 layout mismatch, which is why the layouts here are still specific rather than
 `GENERAL`.

 ## Why an interface here and nowhere else

 This is the one kind of pass whose contract is uniform across implementers: read
 one full-screen image, write another at the same extent. A script's pass is one
 shader; an engine-provided bloom is internally a pyramid of twelve. Same
 contract, different types — which is what dynamic dispatch is for.

 A geometry pass and a full-screen pass under one interface would be worse than
 no interface: it would grant compile-time substitutability the GPU does not
 honour, the compiler would accept a shadow pass in a full-screen slot, and the
 failure is a validation error in a debug build or a black frame in a release one
 — and since `-D DEBUG` the release build is the one without the layer. Their
 simply being different functions with different arguments is the stronger
 guarantee.

 ## Interface values are pointers

 A `FullscreenPass` is `{void*, typeid}`, so one taken from a `List` is
 invalidated by anything that grows it — and `three.addPass` grows it at
 arbitrary times. `PostPass.stages` holds *boxed* stages for that reason, and the
 values here are still taken fresh each frame rather than cached.
*>
interface FullscreenPass
{
	fn void? record(vk::CommandBuffer cmd, PassIo io);

	<*
	 The target changed size. Anything owned at the old extent is now wrong.

	 Optional, and it is the member that earns `@optional` immediately: a pass
	 that is one shader over the whole frame owns nothing that has an extent, and
	 a pyramid owns twelve things that do.
	*>
	fn void? resize(Gpu* gpu, vk::Extent2D extent) @optional;

	// Give back device objects. Optional for the pass that holds none.
	fn void free(Gpu* gpu) @optional;
}

// ============================================================================
// The chain's images
// ============================================================================

<*
 Create image A and as much of the ping-pong pair as `stages` needs, or move
 them to a new extent.

 Idempotent: the common call is the one that finds everything already there at
 the right size and returns. **P1 is allocated only from the second pass on**,
 which is the difference between a script that set one post shader and a script
 that built a chain — the first pays for A and P0 and nothing more.

 `waitIdle` before destroying anything, because these images have no deletion
 queue of their own. Pipelines do, and one mechanism earning its keep for the
 objects a resize touches would be a mechanism built for a case that has never
 happened — `Target.init` is called once, from `Renderer.init`.

 @param stages : `How many script passes the chain is about to have. Zero still creates A, because a set that fails to compile has already paid for it.`
*>
fn void? PostPass.ensure_images(&self, Gpu* gpu, Target* target, sz stages)
{
	bool moved = self.extent.width != target.extent.width || self.extent.height != target.extent.height;
	if (moved && self.extent.width != 0)
	{
		gpu.handle.waitIdle();
		self.destroy_images(gpu);
		// Every stage that owns anything at the old extent hears about it. A stage
		// that owns nothing does not implement `resize` and is skipped — see
		// `FullscreenPass`.
		foreach (boxed : self.stages)
		{
			FullscreenPass pass = boxed;
			if (&pass.resize) pass.resize(gpu, target.extent)!;
		}
	}
	self.extent = target.extent;

	// **`target.color_format`, not `POST_CHAIN_FORMAT`** — `render/post.c3`'s
	// colour argument in one line, and the reason it is not the chain's format is
	// that the scene's own pipelines declare theirs at build time.
	if (!self.scene.exists()) self.scene.init(gpu, target.color_format, self.extent)!;

	// P0 whenever there is a chain at all, because the tonemap reads a pong image
	// rather than A. P1 only from the second pass on.
	if (!self.pong[0].exists()) self.pong[0].init(gpu, POST_CHAIN_FORMAT, self.extent)!;
	if (stages >= 2 && !self.pong[1].exists()) self.pong[1].init(gpu, POST_CHAIN_FORMAT, self.extent)!;

	self.ensure_sampler(gpu)!;
}

<*
 How A and the ping-pong images are read.

 CLAMP_TO_EDGE rather than REPEAT, unlike every other sampler in this project: a
 blur steps off the edge of the frame by construction, and wrapping there puts the
 opposite edge of the picture into the border rather than smearing the border
 itself.

 One sampler for all three images, and for every pass. There is nothing per-pass
 about it — the addressing and the filter are properties of "this is a full-screen
 image being read at screen resolution", which is the same sentence for all of
 them.
*>
fn void? PostPass.ensure_sampler(&self, Gpu* gpu)
{
	if (self.sampler != null) return;
	self.sampler = vk::samplerCreateInfo().setMagFilter(FILTER_LINEAR).setMinFilter(FILTER_LINEAR)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setAddressModeV(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setMipmapMode(SAMPLER_MIPMAP_MODE_LINEAR)
		.setMinLod(0.0)
		.setMaxLod(0.0)
		.setBorderColor(BORDER_COLOR_INT_OPAQUE_BLACK)
		.build(gpu.handle)!;
}

fn void PostPass.destroy_images(&self, Gpu* gpu)
{
	self.scene.free(gpu);
	self.pong[0].free(gpu);
	self.pong[1].free(gpu);
	self.extent = {};
}

// ============================================================================
// The tonemap — the engine's own pass, and the only writer of target.color
// ============================================================================

<*
 What the engine's last pass does, as a post body.

 **The identity, and that is not a placeholder for a missing tonemap operator.**
 Its job today is entirely the *encode*: it reads linear float out of the chain
 and writes an `_SRGB` attachment, which is the hardware conversion, and it clamps
 above 1.0 because a UNORM attachment does. Nothing in this renderer produces a
 value above 1.0 yet — `target.color` has always clamped them — so a Reinhard or
 an ACES curve here would be shaping a range nothing occupies.

 Where it stops being the identity is `plan.md` §13's step 4: physical light
 intensities, at which point this string is the one place a curve goes and every
 pass in the chain is already in linear float in front of it.

 It goes through `post_source` like any other body, which is worth stating because
 it is the load-bearing test of the whole design: **the engine's own pass is
 expressible in the interface a script gets.**
*>
const String TONEMAP_BODY = "float3 post(Post p) { return p.color; }";

<*
 Compile the tonemap, once.

 Kept for the life of the renderer rather than retired with each `set`: it does
 not depend on what the script wrote, and rebuilding it per set would mean
 recompiling the one shader in the chain that never changes. The disk cache would
 make that cheap and it would still be one more thing to be wrong.

 Its pipeline is built with `target.color_format` — the only pipeline in the chain
 that is — which is exactly what makes the format decision *not* a property of the
 passes above it.
*>
fn void? PostPass.ensure_tonemap(&self, Gpu* gpu, Target* target)
{
	if (self.tonemap.pipeline.handle != null) return;

	@pool()
	{
		String source = post_source(TONEMAP_BODY, {}, tmem)!;
		ShaderModule mod = compile_slang_cached(source, POST_PREAMBLE_NAME, MESH_ENTRIES[..])!;
		defer mod.free();
		if (!mod.ok) return SHADER_COMPILE_FAILED~;
		self.tonemap.pipeline.init_post(gpu, &mod, target.color_format)!;
	};
	self.tonemap.since_set = clock::now();
}

// ============================================================================
// Recording
// ============================================================================

<*
 Run the chain: every script pass in order, then the tonemap into
 `target.color`.

 Called from `Renderer.record_scene` with the scene's rendering already ended —
 both frame paths end it, which is what makes the close below happen exactly once
 and in one place.

 ## The barriers, which are the part validation exists to catch

 One per edge and not one per pass, which is the same count the single-pass
 version had generalised:

 - **A → SHADER_READ_ONLY_OPTIMAL**, once, before anything reads it. It is
   `scene` at binding 1 for every pass and `prev` at binding 0 for the first, so
   one transition covers every use of it in the frame.
 - **P[i] → SHADER_READ_ONLY_OPTIMAL** after pass i, because pass i+1 samples it.
 - the destination's `UNDEFINED → COLOR_ATTACHMENT_OPTIMAL` is **the pass's own**,
   not issued here. That is the protocol on `FullscreenPass`, and it is what lets
   an implementation that renders into its destination more than once — a
   pyramid — open it as many times as it needs to.

 `color_attachment_barrier` discards from `UNDEFINED`, which is already correct
 for reusing P0 on pass 2 after pass 1 sampled it: the pass covers every pixel, so
 there is nothing in it worth preserving.

 Merging the close of one pass with the open of the next into a single two-element
 `cmdPipelineBarrier2` — which is what the single-pass version did — is possible
 and is not done, because it would move the open back out of the pass and there is
 no measurement saying the extra call costs anything.
*>
fn void? PostPass.record_chain(&self, vk::CommandBuffer cmd, Target* target, Assets* assets = null)
{
	sz count = self.stages.len();
	if (count == 0) return;

	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ shader_read_barrier(self.scene.image) }));

	foreach (i, boxed : self.stages)
	{
		ChainImage* dst = &self.pong[i & 1];
		// The first pass's `prev` is A, which is what makes a chain of one
		// identical to the pass this file replaced: both bindings point at the
		// same image, so `p.color == p.scene` and a shader written before the
		// chain existed reads exactly what it always read.
		vk::ImageView prev = i == 0 ? self.scene.view : self.pong[(i - 1) & 1].view;

		// Taken fresh from the boxed stage rather than cached — see
		// `FullscreenPass` on interface values being pointers.
		FullscreenPass pass = boxed;
		pass.record(cmd, {
			.prev = prev,
			.scene = self.scene.view,
			.dst = dst.image,
			.dst_view = dst.view,
			.extent = self.extent,
			.sampler = self.sampler,
			.assets = assets,
		})!;

		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ shader_read_barrier(dst.image) }));
	}

	// The one pass that writes `target.color`, and the one pipeline in the chain
	// built with its format.
	FullscreenPass tone = &self.tonemap;
	tone.record(cmd, {
		.prev = self.pong[(count - 1) & 1].view,
		.scene = self.scene.view,
		.dst = target.color,
		.dst_view = target.color_view,
		.extent = self.extent,
		.sampler = self.sampler,
		.assets = assets,
	})!;
}
