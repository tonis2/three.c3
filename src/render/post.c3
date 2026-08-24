<*
 The post-processing pass: an agent-written shader over the whole finished
 frame, and the list of them.

	`c3c test --trust=full --test-noleak --test-filter three_tests::post`

 ## Where it sits, and what does not move

 Nothing about the frame's ends changes. The blit still reads `target.color`,
 the readback still copies `target.color`, and `gpu/target.c3`'s two-layout
 contract still holds — because with a post pass active the *scene* is what
 moves, not the frame:

	 inactive   scene ────────────────────────────────────────► target.color ─► blit
	 active     scene ──► image A ──► the chain ──► tonemap ──► target.color ─► blit

 `render/chain.c3` is the chain: three images, two rules, and the
 `FullscreenPass` interface that a `PostStage` below is the first implementer of.
 This file is what an agent writes — one body, its uniforms, its samplers — and
 the verbs that put one in the chain.

 A chain that was never given a shader records nothing at all and the frame is
 byte-identical to one from before this file.

 ## Why image A is `_SRGB`, which is the whole colour argument

 A is created `R8G8B8A8_SRGB`, the same format as `target.color`. That makes the
 round trip close **by format rather than by arithmetic**:

 - the scene's shaders write linear floats and the `_SRGB` attachment encodes
   them, exactly as they do into `target.color` today;
 - `prev.Sample()` in `post.slang` decodes back to linear, because a sampler
   reads an `_SRGB` image as linear;
 - the body works in linear, which is the space every other shader in this
   project works in;
 - the pass writes `POST_CHAIN_FORMAT`, which is linear float and stores what it
   was given, and the tonemap's `_SRGB` write re-encodes at the end.

 An identity chain is therefore an identity to within eight bits. Under `_UNORM`
 A it would not be — the sample would arrive already encoded, the body would
 treat sRGB numbers as linear, and the write would encode a second time. That
 shifts the mid-tones and leaves black and white alone, which is precisely the
 failure that looks like "the post pass is a bit washed out" rather than like a
 bug. `plan.md` §10 carries it as a trap.

 ## Why A is not the float image, and the chain is

 `plan.md` §13's step 2 said image A becomes `R16G16B16A16_SFLOAT` and called it
 one line. **It is one line and it does not compile**, which is worth writing
 down because the reasoning that produced it is right about everything except
 where the format is declared. §13 now carries the retraction; this is the code
 the retraction is about.

 A is what the *scene* renders into, and a scene pipeline's colour attachment
 format is fixed when the pipeline is built, from `target.color_format`
 (`gpu/pipeline.c3:577`). Dynamic rendering checks the two against each other, so
 a float A makes every mesh pipeline wrong the moment a post pass is set — and
 the ways out are both large:

 - **a second variant of every mesh pipeline**, keyed on whether a post pass is
   active, which puts a format in the pipeline cache key and makes `setPost`
   rebuild every material's pipeline. That is the thing the chain's design exists
   to avoid, one layer down.
 - **render the scene into A always**, tonemapping even when no script asked for
   a post pass. That is a full-size attachment and a full-screen draw on every
   frame of every scene, and it deletes the property that an unposted frame is
   the code path it always was rather than a new one that agrees with it.

 Neither is one line, and neither buys anything today: **nothing in this renderer
 produces a value above 1.0.** `target.color` has always clamped them and no
 shader has ever complained. What HDR is actually blocked on is physical light
 intensities, which is `plan.md` §2's material unit — step 4, not this one.

 So the float went where it pays for itself immediately instead. The *chain*
 runs in `POST_CHAIN_FORMAT`: a pass may write above 1.0 and the next one sees
 it, which is what a bright pass followed by a blur needs and what an 8-bit
 intermediate destroys. When the scene becomes HDR, A joins the chain's format
 and the always-on path becomes the right answer — for a reason that will exist
 by then.

 ## Why A needs no per-frame layout bookkeeping

 It is cleared at the start of every frame it is used in, so its contents are
 never carried across one. `color_attachment_barrier` opens it from
 `IMAGE_LAYOUT_UNDEFINED` with an `ALL_COMMANDS` source scope — an execution
 dependency that orders last frame's sampled read against this frame's write —
 and `shader_read_barrier` closes it for the sample. The same is true of every
 ping-pong image, which is why the chain needs no state on this side and nothing
 gets out of step when a frame is skipped.

 ## One slot per stage, owned outright

 `MeshPipeline` here is a value and not a `PipelineCache` entry. A chain is a
 handful of passes, so a cache would be a map with a handful of keys in it; and
 the swap case a cache exists to make cheap — the same source coming back — is
 not the case a post shader is in, which is an agent editing a body and asking
 again. The compile is still cached, on disk, by `compile_slang_cached`: the
 expensive half is shared, the cheap half is not indirected.

 Swapping is `gpu.retire_pipeline` and nothing else. The old pipeline may be
 bound by frames still in flight, and the deletion queue's whole job is to know
 when they are not — see `gpu/retire.c3`.
*>
module three;

import std::collections::list;
import std::io;
import vk;

<*
 One shader in the chain: a body, its uniforms, its samplers and the pipeline
 they were compiled into.

 **The project's first implementer of an interface**, and the reason the
 interface is worth having at one implementer is that an engine-provided bloom is
 internally a pyramid of twelve passes with the same contract and a completely
 different type. See `FullscreenPass`.

 Heap-allocated and held by pointer in `PostPass.stages`, because an interface
 value is a pointer and `three.addPass` grows that list at arbitrary times.
*>
struct PostStage (FullscreenPass)
{
	// Owned outright — see the header.
	MeshPipeline pipeline;

	// The body as the agent wrote it, kept so a caller can read back what is
	// running. Owned; freed with the stage.
	String fragment;

	// The push block, laid out as the shader lays it out. `info` occupies
	// 0..16 and is rewritten every frame; everything at or above
	// `POST_PUSH_START` is the agent's and is written when a uniform is set.
	// The same arrangement `Material.block` has, and for the same reason:
	// setting a uniform is a bounds check and a copy, and drawing is a memcpy
	// with no per-uniform loop.
	char[PUSH_BUDGET] block;

	// The samplers the body declared, at bindings 4..N. Bindings 0 to 3 are
	// `prev`, `scene`, the depth buffer and `tap`, and are not in here — they are
	// the chain's, the way `base_color_map` is a material's own. `TextureSlots`
	// has what is stored.
	//
	// **Held across nothing.** Replacing a stage releases these before the new
	// shader's bindings exist, for the same reason it does not carry the uniform
	// block across: the new module's binding 2 is a different sampler with a
	// different name, and keeping an image in it would be putting one shader's
	// texture into another shader's slot.
	TextureSlots textures;

	// The game clock's reading when this stage was compiled, in seconds.
	// `info.z` is the seconds since, so a body animating off `p.time` runs at the
	// simulation's speed, stops when the simulation stops, and renders the same
	// picture twice from the same clock — which is what `plan.md` §2 deferred
	// and §17's clock answered. It was `clock::now()` and a wall clock until
	// then, so a paused scene kept its post pass animating.
	double set_at;

	// Which *earlier* stage this one also reads, as `tap`, or -1 for the passes
	// that read only their predecessor. The third source `plan.md` §2 wanted, and
	// the reason it is an index rather than an edge list is in `render/chain.c3`:
	// one extra source keeps adjacency as the barrier derivation, and a set of
	// them does not.
	int tap;

	// This stage's own output image, for a stage somebody taps.
	//
	// A stage normally writes into the ping-pong pair, where P0 is overwritten by
	// the stage after next — which is exactly what a later reader cannot have. So
	// a tapped stage is given an image nothing else writes, and `PostPass.output_of`
	// is the one place that decides which of the two a stage got.
	//
	// **Allocated only when something taps it**, so a chain nobody taps costs the
	// two images it always cost.
	ChainImage keep;
	bool kept;
}

<*
 The chain, and `active()` is what `Renderer` asks to know whether there is one.

 Everything here is inert until `set` or `add` is called: the images are null,
 the list is empty and `record_chain` is never reached. That is the state a
 `Renderer` starts in and the state `clear` puts it back into.
*>
struct PostPass
{
	// Image A: what the scene renders into, and what every pass reads as `scene`.
	// Created lazily — a runtime that never sets a post shader never pays for a
	// second full-size attachment.
	ChainImage scene;

	// The ping-pong pair, in `POST_CHAIN_FORMAT`. `pong[1]` exists only from the
	// second stage on. `render/chain.c3` has the two rules that index them.
	ChainImage[2] pong;

	// What the images were created at. Compared against `target.extent` every time
	// a stage is built, so that a target which ever *does* change size takes them
	// with it; today it never does — `Target.init` is called once, from
	// `Renderer.init`, and a window resize rebuilds the swapchain and moves the
	// blit's destination rect rather than touching the target (`gpu/target.c3`'s
	// header).
	vk::Extent2D extent;

	// How every image in the chain is read. One for all of them — see
	// `ensure_sampler`.
	vk::Sampler sampler;

	// How `target.depth` is read, which is nearest rather than linear.
	// `ensure_sampler` has the two reasons it cannot be the one above.
	vk::Sampler depth_sampler;

	// The script's passes, in the order they run. Boxed, because an interface value
	// is a pointer into this list and `add` grows it.
	List{PostStage*} stages;

	// The engine's own last pass: the only thing that writes `target.color`, and
	// the only pipeline here built with its format. Not in `stages` because it is
	// not the script's and cannot be reordered, removed or replaced.
	PostStage tonemap;

	// The game clock as of the last frame recorded, in seconds. Written by
	// `record_chain` and read by `build_stage`, which is the only reader: a
	// stage has to be stamped with the time it was set at, and `set` is reached
	// between frames from a script rather than from the frame loop.
	double now;
}

<*
 Give the chain its list.

 Called from `Renderer.init`. A `List` that has never been initialised falls back
 to the *temp* allocator on its first push, which would put a stage in a pool that
 is released at the end of the frame that created it — so this is not a
 convenience.
*>
fn void PostPass.init(&self)
{
	self.stages.init(mem, 2);
}

// ============================================================================
// Building a stage
// ============================================================================

<*
 Compile a post shader and make it the whole chain.

 The agent-facing contract, and it is deliberately shaped like
 `MeshPass.create_material`: source, uniforms, and a diagnostic out-param that
 receives Slang's text on failure *and* on success, because a warning arrives
 with `ok == true` and an agent who never sees a warning writes the same mistake
 twice.

 **This replaces every stage**, which is what keeps `three.setPost` meaning what
 it always meant: one call, one pass, whatever was running is gone. `add` is the
 verb that appends.

 **Called on a live renderer between frames.** The old pipelines are retired
 rather than destroyed, so frames still in flight keep the ones they were
 recorded with; the swap itself happens after every fault. A `set` that fails
 leaves the previous chain running — the frame is either the old chain or the new
 one and never neither, which is what makes an editing loop safe to hold a frame
 loop open through.

 The uniform block is **not** carried across. The new shader's uniforms are new
 fields at new offsets, so keeping the old bytes would be writing one shader's
 values into another's layout; every uniform starts at zero and `set_uniform` is
 how it stops.

 @param fragment : `The agent's body. Must define float3 post(Post p).`
 @param uniforms : `Names and widths, appended to the push block after info. Reached from the body as bare names.`
 @param textures : `Samplers the body wants, in declaration order. Declared here and filled afterwards, one set_texture per name.`
 @param assets : `Where the textures the *previous* chain held go back to. Null skips that release, which is only safe on a chain that never had any.`
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
	MaterialTexture[] textures = {},
	Assets* assets = null,
	String* diagnostic = null
)
{
	// One, not `stages.len() + 1`: this call is about to be the whole chain, so
	// the second ping-pong image is only allocated if a later `add` asks for it.
	// `-1`: the first pass of a chain has nothing before it to tap, and `setPost`
	// is always the first pass of a chain.
	PostStage* built = self.build_stage(gpu, target, 1, fragment, uniforms, textures, -1, diagnostic)!;

	// Past every fault: from here the swap cannot fail half way.
	self.drop_stages(gpu, assets);
	self.stages.push(built);
}

<*
 Compile a post shader and put it at the end of the chain.

 `set` for a chain that keeps what is already in it, and the whole of
 `three.addPass`. The new pass reads what the one before it wrote as `prev`, and
 image A as `scene` — that is the entire dependency declaration, and it is
 adjacency rather than a graph. `render/chain.c3` argues why that is enough.

 A pass appended to an empty chain is exactly a `set`, which is what makes
 `addPass` usable without a `setPost` in front of it.

 The faults are `set`'s, and so is everything about what a failure leaves behind:
 the chain that was running stays running, including the passes this one was
 going to follow.

 ## The third source

 `tap` names an *earlier* pass whose output this one also reads, as the sampler
 `tap` and the field `p.tap`. That is `plan.md` §2's "a pass wanting a third
 source", and it is deliberately one index rather than an edge list — see
 `render/chain.c3` for why one keeps adjacency as the barrier derivation and a
 set does not.

 Naming a pass makes that pass's output survive: it is given an image of its own
 instead of a ping-pong slot, which is what `PostPass.output_of` decides and the
 whole cost of the feature.

 **A `tap` naming a pass that is not in the chain yet is refused**, because it
 would be a cycle or a dangling read and there is nothing sensible to bind.

 **A body that reads `p.tap` having named nothing is not**, and that is a
 deliberate asymmetry rather than a gap. Binding 3 is declared by the template
 unconditionally — `fragmentMain` fills `p.tap` for every body, so Slang keeps the
 sampler whether or not the agent's lines mention it, and the reflected layout
 cannot tell the two apart. Rather than guess textually, the untapped case is
 *defined*: it binds image A, so `p.tap` is the rendered scene. That is exactly
 what `p.scene` gives, and it is this chain's existing rule for a source that is
 not distinct — `p.color == p.scene` on a chain of one, and a null sampler reads
 white.

 @param tap : `Which earlier pass this one also reads, or -1 for none. Must be an index already in the chain.`
 @return `Which position in the chain this pass took. Stable until the chain is set or cleared.`
 @return? POST_TAP_UNKNOWN : `tap is not an index of a pass already in the chain. diagnostic has the sentence.`
*>
fn uint? PostPass.add(
	&self,
	Gpu* gpu,
	Target* target,
	String fragment,
	MaterialUniform[] uniforms,
	MaterialTexture[] textures = {},
	int tap = -1,
	String* diagnostic = null
)
{
	// **Before the compile**, unlike the `tap`-is-unread check below, because
	// this one needs nothing from the module and refusing early costs the caller
	// no Slang.
	if (tap < -1 || tap >= (int)self.stages.len())
	{
		if (diagnostic != null)
		{
			*diagnostic = string::format(
				mem,
				"post: this pass reads pass %d, and the chain has %d — a pass may only read one that already ran",
				tap,
				self.stages.len()
			);
		}
		return POST_TAP_UNKNOWN~;
	}

	PostStage* built = self.build_stage(
		gpu, target, self.stages.len() + 1, fragment, uniforms, textures, tap, diagnostic
	)!;

	self.stages.push(built);
	// After the push, and after every fault: giving a stage its own image is a
	// change to a chain that is already running, and `build_stage` may still have
	// refused above this line.
	if (tap >= 0)
	{
		self.stages[tap].kept = true;
		// A failure here leaves the stage kept with no image, which `output_of`
		// answers with the ping-pong slot — the picture is wrong rather than the
		// process being wrong, and the fault reaches the script.
		self.ensure_keeps(gpu)!;
	}
	return (uint)self.stages.len() - 1;
}

<*
 Which image a stage writes into: its own if something taps it, otherwise its
 ping-pong slot.

 **The one place the two kinds of destination are told apart**, which is what
 keeps the difference from leaking into the recording loop, the tonemap's `prev`
 and the tap binding — all three ask this rather than indexing `pong` themselves.

 A stage marked `kept` whose image failed to allocate falls back to the slot. That
 is a wrong picture and not a crash, and the allocation failure was already
 reported to the script.
*>
fn ChainImage* PostPass.output_of(&self, sz stage)
{
	PostStage* owner = self.stages[stage];
	if (owner.kept && owner.keep.exists()) return &owner.keep;
	return &self.pong[stage & 1];
}

<*
 Create an image for every stage something taps, at the chain's extent.

 Idempotent and cheap: the common call finds every kept stage already holding an
 image and returns. Called from `add` when a tap arrives and from `ensure_images`
 when the extent moves, which are the only two moments the set can change.
*>
fn void? PostPass.ensure_keeps(&self, Gpu* gpu)
{
	foreach (stage : self.stages)
	{
		if (!stage.kept || stage.keep.exists()) continue;
		stage.keep.init(gpu, POST_CHAIN_FORMAT, self.extent)!;
	}
}

<*
 Everything both verbs do before anything is committed to.

 The order is the whole point and every step of it is fallible, which is why the
 callers are two lines each: **nothing that can fail happens after the caller has
 changed what is running.** A fault between building a pipeline and installing it
 would strand a `VkPipeline` that nothing owns.

 The images and the tonemap are ensured *before* the compile rather than after
 it, so that a body which fails to compile has still paid for image A — one
 attachment, freed by `PostPass.free` either way. That is cheaper than the
 alternative, which is a compile whose success then has to allocate.

 @param stages : `How many stages the chain will have if this succeeds. Decides whether the second ping-pong image is needed.`
 @return `A stage owned by the caller until it is pushed. Nothing else has seen it.`
*>
fn PostStage*? PostPass.build_stage(
	&self,
	Gpu* gpu,
	Target* target,
	sz stages,
	String fragment,
	MaterialUniform[] uniforms,
	MaterialTexture[] textures,
	int tap,
	String* diagnostic
)
{
	// The refusals before Slang: they carry a sentence rather than a fault, and
	// the caller asked for the text. Written here rather than left to
	// `post_source` because `post_diagnostic()` is a view into a fixed buffer
	// that the next call overwrites, and the caller's copy is not.
	String? assembled = post_source(fragment, uniforms, mem, textures);
	if (catch reason = assembled)
	{
		if (diagnostic != null) *diagnostic = post_diagnostic().copy(mem);
		return reason~;
	}
	String source = assembled;
	defer source.free(mem);

	self.ensure_images(gpu, target, stages)!;
	self.ensure_tonemap(gpu, target)!;

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

		// **`POST_CHAIN_FORMAT`, never the target's.** Every pass a script writes
		// reads float and writes float; the tonemap is the only encoder. That is
		// what keeps one pipeline shape for every body and reordering free.
		built.init_post(gpu, &mod, POST_CHAIN_FORMAT)!;
	};

	PostStage* stage = mem::new(PostStage);
	stage.pipeline = built;
	stage.fragment = fragment.copy(mem);
	stage.set_at = self.now;
	stage.tap = tap;
	return stage;
}

<*
 Stop post-processing, and give every pipeline back.

 The frame returns to drawing straight into `target.color`, which is
 byte-identical to how it drew before any post shader was set — not similar to
 it, the same code path. The images are kept rather than destroyed: they are
 three allocations, the next `set` would want them back at the same extent, and
 freeing them here would mean freeing device images from a call that has no
 reason to stall the device. `free` is where they go.

 Safe on a chain that was never set — `clear` on an inactive chain is a no-op, so
 a script can call it unconditionally.
*>
fn void PostPass.clear(&self, Gpu* gpu, Assets* assets = null)
{
	if (!self.active()) return;
	self.drop_stages(gpu, assets);
}

<*
 Retire every stage's pipeline, give its images back, and empty the list.

 Retire rather than destroy: this runs on a live renderer, and the pipelines may
 still be bound by frames in flight. `PostPass.free` is the one that runs after
 the device has been idled and frees outright.
*>
fn void PostPass.drop_stages(&self, Gpu* gpu, Assets* assets)
{
	foreach (stage : self.stages)
	{
		stage.release_textures(gpu, assets);
		gpu.retire_pipeline(stage.pipeline);
		// Retired too — `ChainImage.free` goes through the deletion queue, which is
		// what makes replacing a chain mid-frame safe for its images as well as for
		// its pipelines.
		if (stage.keep.exists()) stage.keep.free(gpu);
		if (stage.fragment.ptr != null) stage.fragment.free(mem);
		mem::free(stage);
	}
	self.stages.clear();
}

// ============================================================================
// Reaching into one stage
// ============================================================================

<*
 One stage of the chain, or null.

 Every verb below takes a stage index defaulting to zero, which is what makes the
 single-pass API the chain's own special case rather than a layer over it:
 `three.setPost` leaves exactly one stage and every existing call reaches it
 without saying so.

 @return `Borrowed from the chain, which owns it. Null for a chain that is not that long.`
*>
fn PostStage* PostPass.stage(&self, uint index)
{
	if (index >= self.stages.len()) return null;
	return self.stages[index];
}

// How many passes a script has put in the chain. The tonemap is not one of them.
fn uint PostPass.count(&self) => (uint)self.stages.len();

<*
 Whether the frame goes through the chain.

 Derived rather than a field: every stage push and every `drop_stages` would
 otherwise have to keep a `bool` in step with the list, and the frame a
 disagreement produces is a black one — image A written by nobody. The "read it
 exactly once" rule `Renderer.record_scene` needs is served by the local it
 already copies this into, not by the answer being stored.
*>
fn bool PostPass.active(&self) => self.stages.len() > 0;

<*
 Point a uniform at new values.

 `Material.set_uniform` for a post body, minus the rows: a post pass has no
 instances, so there is no table and no row to select. The name is resolved
 through the pipeline's *reflected* push fields rather than through anything
 this side remembers, which is what makes the offset right by construction —
 Slang decided it, and `-force-glsl-scalar-layout` is what makes it tight.

 `info` resolves — it is a real field — and is refused anyway, for the reason
 `Material.set_uniform` refuses `base_color`: writing the frame's own resolution
 through this door would be overwriting a value `record` rewrites every frame,
 which is a setting that appears to work and then does not.

 @param values : `One to four floats. Must match the width the shader declared.`
 @param stage : `Which pass in the chain. Zero is the one a plain setPost leaves.`
 @return? MATERIAL_UNIFORM_UNKNOWN : `No uniform of that name, or the chain has no such stage.`
 @return? MATERIAL_UNIFORM_WIDTH : `The shader declared a different number of components.`
*>
fn void? PostPass.set_uniform(&self, String name, float[] values, uint stage = 0)
{
	PostStage* target = self.stage(stage);
	if (target == null) return MATERIAL_UNIFORM_UNKNOWN~;

	ShaderField* field = target.pipeline.shader.field_of(name);
	if (field == null || field.offset < POST_PUSH_START) return MATERIAL_UNIFORM_UNKNOWN~;

	uint width = (uint)(values.len * float::size);
	if (width == 0 || field.size != width) return MATERIAL_UNIFORM_WIDTH~;
	if (field.offset + width > PUSH_BUDGET) return MATERIAL_UNIFORM_WIDTH~;

	mem::copy(&target.block[field.offset], values.ptr, width);
}

<*
 Every uniform one stage declared, in the order the shader laid them out.

 `Material.uniform_fields` for the post block, to the line: it reads the
 reflected push fields and drops the ones the contract owns — `info` here, the
 mesh's eight there — which is the same cut `set_uniform` makes. Nothing is
 pushed for a stage that is not there, so the caller's list comes back as it went
 in.
*>
fn void PostPass.uniform_fields(&self, List{ShaderField}* out, uint stage = 0)
{
	PostStage* target = self.stage(stage);
	if (target == null) return;
	foreach (field : target.pipeline.shader.push_fields)
	{
		if (field.offset >= POST_PUSH_START) out.push(field);
	}
}

<*
 `post.textures.<name> = texture` — put an image in one of the sampler bindings
 the body declared.

 `MeshPass.set_material_texture` for the pass with no geometry, and the same three
 moves in the same order: resolve the name through the shader's own reflection,
 retain the new index before releasing the old one because the two can name one
 slot, and wait for the device only when this release is the last reference to an
 image a frame in flight may still be sampling.

 The `Assets` arrives as an argument rather than being a field, which is the one
 structural difference: a `PostPass` belongs to the renderer and the texture table
 belongs to the mesh pass, and giving the post pass a pointer to the other's
 innards to save one parameter is the kind of coupling that outlives the reason
 for it.

 @param name : `The sampler as the body spells it.`
 @param texture : `An index into Assets.textures, or NO_TEXTURE to put white back.`
 @param stage : `Which pass in the chain. Zero is the one a plain setPost leaves.`
 @return? MATERIAL_UNKNOWN : `The chain has no such stage — there is nothing declaring samplers.`
 @return? MATERIAL_TEXTURE_UNKNOWN : `No such texture: a disposed handle, or one from another context.`
 @return? MATERIAL_SAMPLER_UNKNOWN : `This post shader has no sampler by that name.`
*>
fn void? PostPass.set_texture(&self, Gpu* gpu, Assets* assets, String name, int texture, uint stage = 0)
{
	PostStage* target = self.stage(stage);
	if (target == null || assets == null) return MATERIAL_UNKNOWN~;
	if (texture != NO_TEXTURE && !assets.texture_alive(texture)) return MATERIAL_TEXTURE_UNKNOWN~;

	uint binding = sampler_binding_of(&target.pipeline, name, POST_BINDING_FIRST);
	if (binding == 0) return MATERIAL_SAMPLER_UNKNOWN~;

	int held = target.textures.at(binding);
	if (held == texture) return;

	if (texture != NO_TEXTURE) assets.retain_texture(texture);
	assets.release_texture(gpu, held);

	target.textures.set(binding, texture);
}

<*
 Which texture is in one of a stage's sampler bindings.

 `MeshPass.material_texture`'s rule: a getter answers `NO_TEXTURE` for a name that
 is not a sampler rather than faulting, because the setter is where a bad name is
 reported against the line that wrote it.
*>
fn int PostPass.texture(&self, String name, uint stage = 0)
{
	PostStage* target = self.stage(stage);
	if (target == null) return NO_TEXTURE;
	return target.textures.at(sampler_binding_of(&target.pipeline, name, POST_BINDING_FIRST));
}

<*
 Give every image every stage holds back, and empty the slots.

 Run from `set`, from `clear` and from the renderer's teardown — every point at
 which the shaders that named these bindings stop being the ones that run.

 **Emptying the slots is not optional.** A release that left the indices behind
 would have the next `clear` release them a second time, which is the failure
 `Assets` cannot detect: a slot back at zero references is destroyed, and a second
 release of it takes a live image's count down instead.

 A null `assets` skips the whole thing rather than faulting, which is what makes
 the default argument on `clear` honest: a pass that never held a texture has
 nothing to give back, and every call site that might is a call site with the
 table in scope.
*>
fn void PostPass.release_textures(&self, Gpu* gpu, Assets* assets)
{
	foreach (stage : self.stages) stage.release_textures(gpu, assets);
}

fn void PostStage.release_textures(&self, Gpu* gpu, Assets* assets)
{
	if (assets == null) return;

	for (uint binding = POST_BINDING_FIRST; binding < POST_BINDINGS_END; binding++)
	{
		int held = self.textures.at(binding);
		if (held == NO_TEXTURE) continue;
		assets.release_texture(gpu, held);
	}
	self.textures = {};
}

<*
 Everything the chain owns, given back.

 Called from `Renderer.free` after the device has been idled, so the pipelines are
 freed outright rather than retired: there is no frame left for a deletion queue
 to wait for, and `Gpu.free` drains what is queued anyway.
*>
fn void PostPass.free(&self, Gpu* gpu)
{
	if (gpu.handle != null)
	{
		foreach (stage : self.stages)
		{
			stage.free(gpu);
			mem::free(stage);
		}
		self.tonemap.free(gpu);
		if (self.sampler != null) vk::destroySampler(gpu.handle, self.sampler, null);
		if (self.depth_sampler != null) vk::destroySampler(gpu.handle, self.depth_sampler, null);
		self.destroy_images(gpu);
	}
	self.stages.free();
	*self = {};
}

// The interface's optional `free`: a stage owns a pipeline and a string, so it
// implements it. A pass that owned neither would not have to.
fn void PostStage.free(&self, Gpu* gpu) @dynamic
{
	self.pipeline.free(gpu);
	if (self.keep.exists()) self.keep.free(gpu);
	if (self.fragment.ptr != null) self.fragment.free(mem);
	*self = {};
}

// ============================================================================
// Recording
// ============================================================================

<*
 Draw one full-screen pass: the chain's implementation of `FullscreenPass`.

 The whole of what a post shader does to a frame, and the tonemap goes through
 the identical function — which is the load-bearing check on the interface being
 real rather than decorative.

 ## The barrier is this pass's, and it is the only one here

 `color_attachment_barrier(io.dst)` opens the destination from `UNDEFINED`,
 discarding whatever the last frame left, because the draw covers every pixel.
 Closing it for the *next* reader is the chain's — `record_chain` says why the two
 halves sit where they do.

 ## The viewport is positive here, and that is not an oversight

 Everywhere else in this project the viewport height is negative, which undoes
 Vulkan's Y-down NDC so a glm-convention projection lands the right way up.
 There is no projection here: the three vertices *are* NDC, and `uv` is the same
 number the clip position was built from. Under a negative height a fragment at
 framebuffer row `r` would carry `uv.y = 1 - r/height` and sample the source's row
 `height - r` — a vertical flip, and one that no validation layer objects to.
 So the flip that exists for projections is left off for the pass that has none,
 and `shaders/post.slang` needs no `uv` flip anywhere in it.
*>
fn void? PostStage.record(&self, vk::CommandBuffer cmd, PassIo io) @dynamic
{
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ color_attachment_barrier(io.dst) }));

	// Colour only, and no depth attachment — `MeshPipeline.init_post` declares
	// no depth format, and dynamic rendering checks the two against each other.
	vk::RenderingAttachmentInfo color_attachment = vk::renderingAttachmentInfo().setImageView(io.dst_view)
		.setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
		// CLEAR rather than DONT_CARE: the draw covers every pixel, so this is
		// never read — but a load op that says "whatever was there" is a
		// difference between drivers waiting for a pass that one day does not
		// cover everything.
		.setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE)
		.setClearValue({ .color = { .float32 = { 0, 0, 0, 1 } } });

	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = io.extent }).setLayerCount(1)
		.setColorAttachments({ color_attachment });

	vk::cmdBeginRendering(cmd, &rendering);

	set_full_viewport(cmd, io.extent, false);

	// Also the first two floats of the push block below.
	float width  = (float)io.extent.width;
	float height = (float)io.extent.height;

	vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.handle);

	// Pushed, not bound — the same argument `MeshPass.record` makes: there is no
	// descriptor set anywhere in this project, so the images are specified inline
	// against this pipeline's own layout.
	//
	// **Every write is checked against the reflected layout first, the two reserved
	// bindings included.** Slang is free to drop a sampler nothing reads, and a
	// body that never touches `p.scene` gives it every reason to drop `scene` — a
	// write to a binding the layout does not declare is a validation error, so the
	// two reserved bindings go through the same question as the agent's own rather
	// than being assumed. Everything from `POST_BINDING_FIRST` up is resolved by
	// name; see `render/bind.c3`.
	SampledBindings samplers;
	if (pipeline_declares_binding(&self.pipeline, 0)) samplers.add(0, sampled_with(io.sampler, io.prev));
	if (pipeline_declares_binding(&self.pipeline, 1)) samplers.add(1, sampled_with(io.sampler, io.scene));
	// The depth buffer, in `DEPTH_STENCIL_READ_ONLY_OPTIMAL` rather than
	// `SHADER_READ_ONLY_OPTIMAL` — a different layout and a different sampler
	// from the two above, which is why it does not go through `sampled_with`.
	if (pipeline_declares_binding(&self.pipeline, 2))
	{
		samplers.add(2, {
			.sampler = io.depth_sampler,
			.imageView = io.depth,
			.imageLayout = IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
		});
	}
	// The third source. `io.tap` is the view of whatever pass this one names, and
	// the chain has already transitioned it — a tapped stage's output goes to
	// SHADER_READ_ONLY_OPTIMAL after it runs like every other stage's, and it is
	// an image nothing overwrites in between.
	if (pipeline_declares_binding(&self.pipeline, POST_TAP_BINDING))
	{
		samplers.add(POST_TAP_BINDING, sampled_with(io.sampler, io.tap));
	}
	if (io.assets != null) samplers.collect(&self.pipeline, &self.textures, io.assets, POST_BINDING_FIRST);
	samplers.push(cmd, &self.pipeline);

	// `info` is rewritten here and nowhere else. The uniforms above it are
	// whatever `set_uniform` last wrote, which is what makes them live between
	// frames with no upload and no per-frame crossing.
	// Six floats: `info` and then `planes`, which is exactly `POST_PUSH_START`
	// bytes and exactly what `POST_PUSH_FIELDS` pins. Written as one array
	// because they are contiguous in the shader's block and splitting them would
	// be two `mem::copy`s to say the same thing.
	float[6] info = {
		width,
		height,
		(float)(io.time - self.set_at),
		0,
		io.near_plane,
		io.far_plane,
	};
	mem::copy(&self.block[0], &info[0], (sz)POST_PUSH_START);

	// **The reflected size, not `PUSH_BUDGET`.** Pushing more than the block the
	// shader declared is a validation error, and `MeshPass.record` has the note
	// about how it fails.
	uint push_size = self.pipeline.shader.push_size;
	vk::cmdPushConstants(cmd, self.pipeline.layout, self.pipeline.shader.stages, 0, push_size, &self.block);

	// Three vertices, one instance, no vertex buffer and no index buffer. The
	// triangle is `SV_VertexID` arithmetic in `shaders/post.slang`.
	vk::cmdDraw(cmd, 3, 1, 0, 0);

	vk::cmdEndRendering(cmd);
}

// One of the chain's own images, as a descriptor. Always SHADER_READ_ONLY_OPTIMAL
// — the chain put it there before the pass was called, and `FullscreenPass`'s
// protocol is where that promise is written down.
fn vk::DescriptorImageInfo sampled_with(vk::Sampler sampler, vk::ImageView view) @local
{
	return { .sampler = sampler, .imageView = view, .imageLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
}
