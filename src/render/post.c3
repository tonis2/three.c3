<*
 The post-processing pass: one agent-written shader over the whole finished
 frame.

	`c3c test --trust=full --test-noleak --test-filter three_tests::post`

 ## Where it sits, and what does not move

 Nothing about the frame's ends changes. The blit still reads `target.color`,
 the readback still copies `target.color`, and `gpu/target.c3`'s two-layout
 contract still holds — because with a post pass active the *scene* is what
 moves, not the frame:

	 inactive   scene ────────────────────────────────► target.color ──► blit
	 active     scene ──► image A ──[sample]──► post ──► target.color ──► blit

 So `Renderer.record_scene` grows exactly one branch, the three frame paths
 stay one recording function, and everything downstream of `target.color` is
 unaware that a post pass exists. A pass that was never given a shader records
 nothing at all and the frame is byte-identical to one from before this file.

 ## Why image A is `_SRGB`, which is the whole colour argument

 A is created `R8G8B8A8_SRGB`, the same format as `target.color`. That makes the
 round trip close **by format rather than by arithmetic**:

 - the scene's shaders write linear floats and the `_SRGB` attachment encodes
   them, exactly as they do into `target.color` today;
 - `scene.Sample()` in `post.slang` decodes back to linear, because a sampler
   reads an `_SRGB` image as linear;
 - the body works in linear, which is the space every other shader in this
   project works in;
 - the `_SRGB` write to `target.color` re-encodes.

 An identity body is therefore an identity to within eight bits. Under `_UNORM`
 it would not be — the sample would arrive already encoded, the body would treat
 sRGB numbers as linear, and the write would encode a second time. That shifts
 the mid-tones and leaves black and white alone, which is precisely the failure
 that looks like "the post pass is a bit washed out" rather than like a bug.
 `plan.md` §10 carries it as a trap.

 ## Why A needs no per-frame layout bookkeeping

 It is cleared at the start of every frame it is used in, so its contents are
 never carried across one. `color_attachment_barrier` opens it from
 `IMAGE_LAYOUT_UNDEFINED` with an `ALL_COMMANDS` source scope — an execution
 dependency that orders last frame's sampled read against this frame's write —
 and `shader_read_barrier` closes it for the sample. Two barriers a frame, no
 state on this side, and nothing to get out of step when a frame is skipped.

 ## One slot, owned outright

 `MeshPipeline` here is a value and not a `PipelineCache` entry. There is one
 post pass, so a cache would be a map with one key in it; and the swap case a
 cache exists to make cheap — the same source coming back — is not the case a
 post shader is in, which is an agent editing a body and asking again. The
 compile is still cached, on disk, by `compile_slang_cached`: the expensive half
 is shared, the cheap half is not indirected.

 Swapping is `gpu.retire_pipeline` and nothing else. The old pipeline may be
 bound by frames still in flight, and the deletion queue's whole job is to know
 when they are not — see `gpu/retire.c3`.
*>
module three;

import std::collections::list;
import std::io;
import std::time;
import vk;

<*
 The image the scene is rendered into while a post pass is active, and the
 shader that reads it.

 Everything here is inert until `set` is called: `active` is false, the image is
 null, and `record` is never reached. That is the state a `Renderer` starts in
 and the state `clear` puts it back into.
*>
struct PostPass
{
	// Whether the frame goes through this pass. The one field `Renderer` reads.
	bool active;

	// Image A: what the scene renders into, and what the shader samples.
	// Created lazily — a runtime that never sets a post shader never pays for a
	// second full-size attachment.
	vk::Image image;
	vk::ImageView view;
	vk::Memory memory;
	// What `image` was created at. Compared against `target.extent` every frame
	// so that a target which ever *does* change size takes A with it; today it
	// never does — `Target.init` is called once, from `Renderer.init`, and a
	// window resize rebuilds the swapchain and moves the blit's destination rect
	// rather than touching the target (`gpu/target.c3`'s header).
	vk::Extent2D extent;

	// How A is read. CLAMP_TO_EDGE rather than REPEAT, unlike every other
	// sampler in this project: a blur steps off the edge of the frame by
	// construction, and wrapping there puts the opposite edge of the picture
	// into the border rather than smearing the border itself.
	vk::Sampler sampler;

	// Owned outright — see the header.
	MeshPipeline pipeline;

	// The body as the agent wrote it, kept so a caller can read back what is
	// running. Owned; freed by `clear` and `free`.
	String fragment;

	// The push block, laid out as the shader lays it out. `info` occupies
	// 0..16 and is rewritten every frame; everything at or above
	// `POST_PUSH_START` is the agent's and is written when a uniform is set.
	// The same arrangement `Material.block` has, and for the same reason:
	// setting a uniform is a bounds check and a copy, and drawing is a memcpy
	// with no per-uniform loop.
	char[PUSH_BUDGET] block;

	// When `set` was called. `info.z` is seconds since — wall clock, not a game
	// clock, because nothing here knows about a simulation. `plan.md` §2 has the
	// deferral.
	Clock since_set;
}

<*
 Compile a post shader and make it the one that runs.

 The whole of the agent-facing contract, and it is deliberately shaped like
 `MeshPass.create_material`: source, uniforms, and a diagnostic out-param that
 receives Slang's text on failure *and* on success, because a warning arrives
 with `ok == true` and an agent who never sees a warning writes the same mistake
 twice.

 **Called on a live renderer between frames.** The old pipeline is retired
 rather than destroyed, so frames still in flight keep the one they were
 recorded with; the swap itself is two assignments. A `set` that fails leaves
 the previous shader running — the pass is either the old shader or the new one
 and never neither, which is what makes an editing loop safe to hold a frame
 loop open through.

 The uniform block is **not** carried across a `set`. The new shader's uniforms
 are new fields at new offsets, so keeping the old bytes would be writing one
 shader's values into another's layout; every uniform starts at zero and
 `set_uniform` is how it stops.

 @param fragment : `The agent's body. Must define float3 post(Post p).`
 @param uniforms : `Names and widths, appended to the push block after info. Reached from the body as bare names.`
 @param [out] diagnostic : `Slang's output verbatim, on failure and on warnings alike. Owned by the caller. Null keeps the old behaviour of printing to stderr.`
 @return? POST_BODY_EMPTY : `The body is empty. post_diagnostic() has the sentence, and it is copied into diagnostic too.`
 @return? POST_NAME_INVALID : `A uniform name, width or row count is one this cannot generate. post_diagnostic() names it.`
 @return? POST_TOO_MANY_UNIFORMS : `The uniforms want more than the 112 bytes info leaves.`
 @return? SHADER_NOT_FOUND : `shaders/post.slang is not on the search path.`
 @return? SHADER_COMPILE_FAILED : `Slang refused the assembled module. diagnostic has the text, with post:<line> coordinates on the agent's own lines.`
 @return? SLANG_UNAVAILABLE : `The Slang session would not start. Nothing to do with this body.`
 @return? PUSH_BLOCK_MISMATCH : `The module does not begin with a 16-byte info. Unreachable through post_source, and checked anyway — see MeshPipeline.init_post.`
*>
fn void? PostPass.set(
	&self,
	Gpu* gpu,
	Target* target,
	String fragment,
	MaterialUniform[] uniforms,
	String* diagnostic = null
)
{
	// The refusals before Slang: they carry a sentence rather than a fault, and
	// the caller asked for the text. Written here rather than left to
	// `post_source` because `post_diagnostic()` is a view into a fixed buffer
	// that the next call overwrites, and the caller's copy is not.
	String? assembled = post_source(fragment, uniforms, mem);
	if (catch reason = assembled)
	{
		if (diagnostic != null) *diagnostic = post_diagnostic().copy(mem);
		return reason~;
	}
	String source = assembled;
	defer source.free(mem);

	// Before the compile rather than after it, so that everything between the
	// pipeline being built and the swap being done is infallible: a fault
	// between those two lines would strand a `VkPipeline` that nothing owns.
	// The cost of the order is that a post shader which fails to compile still
	// allocates image A — one attachment, freed by `PostPass.free` either way.
	self.ensure_image(gpu, target)!;

	MeshPipeline built;
	@pool()
	{
		// Through the disk cache, so the second run of a script that sets the
		// same body pays no Slang call at all — `plan.md` Phase B. The assembled
		// source is the key, so live editing needs no invalidation path: a
		// different body is a different key.
		ShaderModule mod = compile_slang_cached(source, POST_PREAMBLE_NAME, MESH_ENTRIES[..])!;
		defer mod.free();

		// Handed over before the `ok` check: a successful compile can still warn,
		// and the caller asked for the text rather than for the failures.
		if (diagnostic != null && mod.diagnostic.len > 0) *diagnostic = mod.diagnostic.copy(mem);
		if (!mod.ok)
		{
			// Printed only when nobody took delivery. `plan.md` §6: a compile that
			// fails quietly is the runtime version of the `$embed` trap.
			if (diagnostic == null) io::eprintn(mod.diagnostic);
			return SHADER_COMPILE_FAILED~;
		}
		if (diagnostic == null && mod.diagnostic.len > 0) io::eprintn(mod.diagnostic);

		built.init_post(gpu, target, &mod)!;
	};

	// Past every fault: from here the swap cannot fail half way.
	if (self.active) gpu.retire_pipeline(self.pipeline);
	if (self.fragment.ptr != null) self.fragment.free(mem);

	self.pipeline = built;
	self.fragment = fragment.copy(mem);
	self.block = {};
	self.since_set = clock::now();
	self.active = true;
}

<*
 Stop post-processing, and give the pipeline back.

 The frame returns to drawing straight into `target.color`, which is
 byte-identical to how it drew before any post shader was set — not similar to
 it, the same code path. Image A is kept rather than destroyed: it is one
 allocation, the next `set` would want it back at the same extent, and freeing
 it here would mean freeing a device image from a call that has no reason to
 stall the device. `free` is where it goes.

 Safe on a pass that was never set — `clear` on an inactive pass is a no-op, so
 a script can call it unconditionally.
*>
fn void PostPass.clear(&self, Gpu* gpu)
{
	if (!self.active) return;
	gpu.retire_pipeline(self.pipeline);
	self.pipeline = {};
	if (self.fragment.ptr != null) self.fragment.free(mem);
	// A zero slice, not `""`. A string literal has a perfectly good pointer into
	// static memory, and the next `set` would hand it to `free`.
	self.fragment = {};
	self.block = {};
	self.active = false;
}

<*
 Point a uniform at new values.

 `Material.set_uniform` for the post block, minus the rows: a post pass has no
 instances, so there is no table and no row to select. The name is resolved
 through the pipeline's *reflected* push fields rather than through anything
 this side remembers, which is what makes the offset right by construction —
 Slang decided it, and `-force-glsl-scalar-layout` is what makes it tight.

 `info` resolves — it is a real field — and is refused anyway, for the reason
 `Material.set_uniform` refuses `base_color`: writing the frame's own resolution
 through this door would be overwriting a value `record` rewrites every frame,
 which is a setting that appears to work and then does not.

 @param values : `One to four floats. Must match the width the shader declared.`
 @return? MATERIAL_UNIFORM_UNKNOWN : `No uniform of that name, or the pass has no shader.`
 @return? MATERIAL_UNIFORM_WIDTH : `The shader declared a different number of components.`
*>
fn void? PostPass.set_uniform(&self, String name, float[] values)
{
	if (!self.active) return MATERIAL_UNIFORM_UNKNOWN~;

	ShaderField* field = self.pipeline.shader.field_of(name);
	if (field == null || field.offset < POST_PUSH_START) return MATERIAL_UNIFORM_UNKNOWN~;

	uint width = (uint)(values.len * float::size);
	if (width == 0 || field.size != width) return MATERIAL_UNIFORM_WIDTH~;
	if (field.offset + width > PUSH_BUDGET) return MATERIAL_UNIFORM_WIDTH~;

	mem::copy(&self.block[field.offset], values.ptr, width);
}

<*
 Every uniform this pass declared, in the order the shader laid them out.

 `Material.uniform_fields` for the post block, to the line: it reads the
 reflected push fields and drops the ones the contract owns — `info` here, the
 mesh's eight there — which is the same cut `set_uniform` makes. Nothing is
 pushed for an inactive pass, so the caller's list comes back as it went in.
*>
fn void PostPass.uniform_fields(&self, List{ShaderField}* out)
{
	if (!self.active) return;
	foreach (field : self.pipeline.shader.push_fields)
	{
		if (field.offset >= POST_PUSH_START) out.push(field);
	}
}

<*
 Create image A, or recreate it at a new extent.

 Idempotent: the common call is the one that finds the image already there at
 the right size and returns. `waitIdle` before destroying an existing one
 because an image has no deletion queue of its own — pipelines do, and one
 mechanism earning its keep for one object a resize would be a mechanism built
 for a case that has never happened (`Target.init` is called once, from
 `Renderer.init`).
*>
fn void? PostPass.ensure_image(&self, Gpu* gpu, Target* target)
{
	if (self.image != null && self.extent.width == target.extent.width && self.extent.height == target.extent.height)
	{
		return;
	}

	if (self.image != null)
	{
		gpu.handle.waitIdle();
		self.destroy_image(gpu);
	}

	self.extent = target.extent;

	// **`_SRGB` and `target.color_format`, not a format of its own** — the
	// header's colour argument in one line. COLOR_ATTACHMENT because the scene
	// renders into it, SAMPLED because the post shader reads it, and nothing
	// else: A is never blitted and never copied out.
	self.image = vk::imageCreateInfo().setImageType(IMAGE_TYPE_2D).setFormat(target.color_format)
		.setExtent({ .width = self.extent.width, .height = self.extent.height, .depth = 1 })
		.setMipLevels(1)
		.setArrayLayers(1)
		.setSamples(SAMPLE_COUNT_1_BIT)
		.setTiling(IMAGE_TILING_OPTIMAL)
		.setUsage(IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT)
		.setInitialLayout(IMAGE_LAYOUT_UNDEFINED)
		.build(gpu.handle)!;
	self.memory = vk::create_image_buffer(self.image, &gpu.allocator, MEMORY_PROPERTY_DEVICE_LOCAL_BIT)!;

	self.view = vk::imageViewCreateInfo().setViewType(IMAGE_VIEW_TYPE_2D).setFormat(target.color_format)
		.setSubresourceRange(
			{ .aspectMask = IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 }
		)
		.setImage(self.image)
		.build(gpu.handle)!;

	if (self.sampler == null)
	{
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
}

<*
 `vk::Memory.free` destroys the image it was bound to, so the image must not be
 destroyed again here — the view is the only extra. `Target.free` says the same.
*>
fn void PostPass.destroy_image(&self, Gpu* gpu)
{
	if (self.view != null) self.view.free(gpu.handle);
	self.memory.free();
	self.image = (vk::Image)null;
	self.view = (vk::ImageView)null;
	self.memory = {};
	self.extent = {};
}

<*
 Everything this pass owns, given back.

 Called from `Renderer.free` after the device has been idled, so the pipeline is
 freed outright rather than retired: there is no frame left for a deletion queue
 to wait for, and `Gpu.free` drains what is queued anyway.
*>
fn void PostPass.free(&self, Gpu* gpu)
{
	if (gpu.handle != null)
	{
		self.pipeline.free(gpu);
		if (self.sampler != null) vk::destroySampler(gpu.handle, self.sampler, null);
		self.destroy_image(gpu);
	}
	if (self.fragment.ptr != null) self.fragment.free(mem);
	*self = {};
}

// ============================================================================
// Recording
// ============================================================================

<*
 End the scene's rendering into image A, then draw the post pass into
 `target.color`.

 The whole second half of a post-processed frame, and it is called immediately
 after `Renderer.draw` — `Renderer.record_scene` has the branch.

 ## The barriers, which are the part validation exists to catch

 Two, and both are in the one `cmdPipelineBarrier2` between the passes:

 - **A: COLOR_ATTACHMENT_OPTIMAL → SHADER_READ_ONLY_OPTIMAL**, colour-attachment
   write to fragment-shader sampled read. A write-then-read inside one
   submission, so it needs the access masks and not merely the layout change;
   `shader_read_barrier` in `gpu/target.c3` is exactly this and this is its
   first caller.
 - **`target.color`: UNDEFINED → COLOR_ATTACHMENT_OPTIMAL**, the ordinary
   `color_attachment_barrier` every frame opens the target with. Nothing is
   preserved because the pass clears and then covers every pixel.

 Afterwards `to_transfer_src()` closes the target exactly as `end_render` does,
 which is what keeps the blit and the readback unaware that any of this
 happened.

 ## The viewport is positive here, and that is not an oversight

 Everywhere else in this project the viewport height is negative, which undoes
 Vulkan's Y-down NDC so a glm-convention projection lands the right way up.
 There is no projection here: the three vertices *are* NDC, and `uv` is the same
 number the clip position was built from. Under a negative height a fragment at
 framebuffer row `r` would carry `uv.y = 1 - r/height` and sample A's row
 `height - r` — a vertical flip, and one that no validation layer objects to.
 So the flip that exists for projections is left off for the pass that has none,
 and `shaders/post.slang` needs no `uv` flip anywhere in it.
*>
fn void PostPass.record(&self, vk::CommandBuffer cmd, Target* target)
{
	vk::cmdEndRendering(cmd);

	vk::ImageMemoryBarrier2[2] barriers = {
		shader_read_barrier(self.image),
		color_attachment_barrier(target.color),
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(barriers[..]));

	// Colour only, and no depth attachment — `MeshPipeline.init_post` declares
	// no depth format, and dynamic rendering checks the two against each other.
	vk::RenderingAttachmentInfo color_attachment = vk::renderingAttachmentInfo().setImageView(target.color_view)
		.setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
		// CLEAR rather than DONT_CARE: the draw covers every pixel, so this is
		// never read — but a load op that says "whatever was there" is a
		// difference between drivers waiting for a pass that one day does not
		// cover everything.
		.setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE)
		.setClearValue({ .color = { .float32 = { 0, 0, 0, 1 } } });

	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = target.extent }).setLayerCount(1)
		.setColorAttachments({ color_attachment });

	vk::cmdBeginRendering(cmd, &rendering);

	float width  = (float)target.extent.width;
	float height = (float)target.extent.height;
	vk::cmdSetViewport(
		cmd,
		0,
		1,
		(vk::Viewport[]) { { .x = 0, .y = 0, .width = width, .height = height, .minDepth = 0.0, .maxDepth = 1.0 } }
	);
	vk::cmdSetScissor(cmd, 0, 1, (vk::Rect2D[]) { { .offset = { 0, 0 }, .extent = target.extent } });

	vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.handle);

	// Pushed, not bound — the same argument `MeshPass.record` makes: there is no
	// descriptor set anywhere in this project, so image A is specified inline
	// against this pipeline's own layout.
	vk::DescriptorImageInfo image_info = {
		.sampler = self.sampler,
		.imageView = self.view,
		.imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
	};
	vk::WriteDescriptorSet write = vk::writeDescriptorSet().setDstBinding(0)
		.setDescriptorType(DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
		.setImageInfo({ image_info });
	vk::cmdPushDescriptorSetKHR(cmd, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.layout, 0, 1, &write);

	// `info` is rewritten here and nowhere else. The uniforms above it are
	// whatever `set_uniform` last wrote, which is what makes them live between
	// frames with no upload and no per-frame crossing.
	float[4] info = {
		width,
		height,
		(float)((double)self.since_set.to_now() / 1_000_000_000.0),
		0,
	};
	mem::copy(&self.block[0], &info[0], (sz)(4 * float::size));

	// **The reflected size, not `PUSH_BUDGET`.** Pushing more than the block the
	// shader declared is a validation error, and `MeshPass.record` has the note
	// about how it fails.
	uint push_size = self.pipeline.shader.push_size;
	vk::cmdPushConstants(cmd, self.pipeline.layout, self.pipeline.shader.stages, 0, push_size, &self.block);

	// Three vertices, one instance, no vertex buffer and no index buffer. The
	// triangle is `SV_VertexID` arithmetic in `shaders/post.slang`.
	vk::cmdDraw(cmd, 3, 1, 0, 0);

	vk::cmdEndRendering(cmd);
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ target.to_transfer_src() }));
}
