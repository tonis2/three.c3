<*
 What a draw hands its shader's samplers, built from what the shader said it
 wants.

 ## The half of "derived, not declared" that was missing

 `shader/reflect.c3` has read the *layout* out of the compiled module since M4 —
 `MeshPipeline.init` hands Slang's answer to `vkCreateDescriptorSetLayout`
 unchanged, and nothing in C3 names `base_color_map` or knows it is a combined
 image sampler. What stayed hand-written was the other end: two `setDstBinding(0)`
 calls, one in `MeshPass.record` and one in `PostPass.record`, each with one image
 and no idea whether the shader had asked for more.

 That is the difference between reflection describing a shape and reflection
 *driving* the draw, and it is why a `ShaderMaterial` had exactly one texture:
 not because the layout could not hold two, but because the write site could not.
 This file is the write site, keyed on the reflected bindings, so a material with
 three samplers and a material with none go down the same path.

 ## Why every binding is written, every time

 A binding the layout declares and the draw leaves unwritten is undefined
 behaviour — the shader samples a descriptor that was never filled in, and
 nothing in Vulkan is required to say so. Validation layers do not catch it,
 because from their side the layout is satisfied by the set that *will* be
 pushed and they cannot know one never was.

 So `collect` walks the reflected bindings rather than the textures somebody
 supplied, and a binding with nothing in it gets the same 1x1 opaque white image
 `Assets.texture_at` already answers with for `NO_TEXTURE`. That rule is not new:
 it is exactly what makes an untextured mesh and a textured one the same pipeline
 (`scene/asset.c3`'s header). It just applies to four bindings now instead of one.

 ## Still no descriptor set

 `MeshPipeline.init` creates its layout with `PUSH_DESCRIPTOR_BIT`, so there is
 no pool, no allocation and no per-frame set lifetime anywhere in this project —
 the writes are specified inline against the pipeline's own layout and die with
 the command buffer. That is what makes this file small: going from one image to
 several is an array and a count, not a set-management layer.
*>
module three;

import vk;

// One past the last binding each kind of shader can have: its template's
// reserved bindings plus what an agent may declare on top of them. A material
// reserves one and a post pass reserves two — see `MATERIAL_BINDING_FIRST`.
// Loop bounds, and the two halves of the maximum below.
const uint MATERIAL_BINDINGS_END = MATERIAL_BINDING_FIRST + MATERIAL_TEXTURE_LIMIT;
const uint POST_BINDINGS_END = POST_BINDING_FIRST + POST_TEXTURE_LIMIT;

<*
 The most sampler bindings one draw can carry here: whichever kind of shader
 wants the most.

 Derived rather than chosen, so that raising either limit — or reserving a third
 binding in either template — raises this with it. It used to be one sum because
 both kinds started at the same binding; the max is what that expression becomes
 once they do not.

 It is also `TextureSlots`'s array length, which is why it is a maximum rather
 than a per-kind number: one struct holds either kind's slots, indexed by the
 binding itself.
*>
const uint MAX_SAMPLED_BINDINGS = MATERIAL_BINDINGS_END > POST_BINDINGS_END
	? MATERIAL_BINDINGS_END
	: POST_BINDINGS_END;

<*
 The image writes for one draw, gathered before any of them is pushed.

 **A value on the caller's stack, and it has to be.** `WriteDescriptorSet` holds
 a *pointer* to its image info — `setImageInfo` stores `&infos[0]` — so the
 `DescriptorImageInfo` values must outlive the builder call and stay put until
 `vkCmdPushDescriptorSetKHR` reads them. Keeping both arrays in one struct is what
 makes that true by construction: build it, fill it, push it, and the pointers
 into it are valid for exactly that long.

 Writing this as a function that took a slice of infos would compile and would be
 wrong the first time somebody passed a temporary.
*>
struct SampledBindings
{
	vk::DescriptorImageInfo[MAX_SAMPLED_BINDINGS] infos;
	vk::WriteDescriptorSet[MAX_SAMPLED_BINDINGS] writes;
	uint count;
}

<*
 Add one image at one binding.

 Silently full rather than faulting past the end: the count is bounded by the same
 constant the shader front doors validate against, so reaching it means a shader
 declared more samplers than either limit allows — which `texture_problem` already
 refused with a sentence, at construction, long before a frame was recorded. A
 fault here would be a second report of something that cannot get this far.
*>
fn void SampledBindings.add(&self, uint binding, vk::DescriptorImageInfo info)
{
	if (self.count >= MAX_SAMPLED_BINDINGS) return;

	self.infos[self.count] = info;
	self.writes[self.count] = vk::writeDescriptorSet().setDstBinding(binding)
		.setDescriptorType(DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
		// A one-element slice of the struct's own array, so the pointer this
		// stores outlives the expression — see the struct's note.
		.setImageInfo(self.infos[self.count : 1]);
	self.count++;
}

<*
 Fill every binding the shader declared past the ones its template reserves, from
 a material's own table.

 The reserved bindings are the caller's to add and are not touched here, because
 the two callers mean different things by them: a material's binding 0 is
 `material.map` or the mesh's own image, and a post pass's 0 and 1 are the pass
 before it and image A. Everything above them is the agent's and resolves the same
 way for both — which is why `first` is a parameter and not a constant.

 **Driven by the reflected bindings, not by the textures the material holds.** A
 sampler the script never supplied gets white rather than being skipped — see the
 header for why skipping it is undefined behaviour rather than a missing picture.

 @param pipeline : `Whose reflected layout says which bindings exist.`
 @param slots : `Where the indices come from. Null binds white to every declared sampler.`
 @param first : `The first binding that is the agent's — MATERIAL_BINDING_FIRST or POST_BINDING_FIRST. Everything below it belongs to the template and the caller has already added it.`
*>
fn void SampledBindings.collect(&self, MeshPipeline* pipeline, TextureSlots* slots, Assets* assets, uint first)
{
	foreach (binding : pipeline.shader.bindings)
	{
		if (binding.binding < first) continue;
		if (binding.type != DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER) continue;

		int index = slots == null ? NO_TEXTURE : slots.at(binding.binding);
		self.add(binding.binding, assets.texture_at(index).descriptor());
	}
}

<*
 Which binding a sampler name means, resolved through the *reflected* layout.

 `Material.set_uniform`'s move, one binding table over: the name is looked up in
 what Slang said the module contains rather than in anything this side remembers,
 so a shader and the thing holding its textures cannot disagree about which
 sampler is which. It is also the whole of why nothing above
 `shader/assemble.c3` spells a binding number — a script writes `noise_map`, and
 this is where that becomes a `1`.

 **Zero means no**, and can, because zero is never a legal answer: binding 0 is
 the template's own `base_color_map` or `prev`, which is reached through
 `material.map` and through the chain respectively, and deliberately not by name.
 A name that reflects below `first` is refused exactly like a name that reflects
 at nothing at all — which is what keeps a post shader from reaching `scene` at
 binding 1 by declaring a texture called something else and hoping.

 A name the body declared and never sampled may be absent here — Slang is free to
 drop a parameter nothing reads — which is a case the caller must have an answer
 for and cannot distinguish from a typo. The two setters have that answer, in a
 sentence naming both possibilities.

 @param first : `The first binding that is the agent's — MATERIAL_BINDING_FIRST or POST_BINDING_FIRST.`
 @return `The binding index, or 0 for a name this shader has no sampler for.`
*>
fn uint sampler_binding_of(MeshPipeline* pipeline, String name, uint first)
{
	if (pipeline == null) return 0;
	ShaderBinding* found = pipeline.shader.binding_of(name);
	if (found == null) return 0;
	if (found.binding < first) return 0;
	if (found.binding >= MAX_SAMPLED_BINDINGS) return 0;
	return found.binding;
}

<*
 Does this pipeline's layout have a sampler at this exact binding?

 The question the *reserved* bindings have to ask, and it exists because the
 answer is not always yes. A template declares its own samplers unconditionally,
 but reflection reports the linked program — and **Slang is free to drop a
 parameter nothing reads**. A post body that never touches `p.scene` gives it
 every reason to drop `scene`, and pushing a write for a binding the layout does
 not declare is a validation error rather than a wasted descriptor.

 So the reserved bindings go through the same question the agent's own do
 (`sampler_binding_of`), by index instead of by name — because a reserved binding
 has a fixed number and a name the caller must not have to spell.

 @param binding : `An absolute binding index. 0 and 1 are the only callers today.`
*>
fn bool pipeline_declares_binding(MeshPipeline* pipeline, uint binding)
{
	if (pipeline == null) return false;
	foreach (declared : pipeline.shader.bindings)
	{
		if (declared.binding != binding) continue;
		return declared.type == DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
	}
	return false;
}

<*
 Push the lot into the command buffer, against this pipeline's own layout.

 One call for every binding rather than one per binding: `vkCmdPushDescriptorSetKHR`
 takes an array, and the writes were gathered precisely so it can.
*>
fn void SampledBindings.push(&self, vk::CommandBuffer cmd, MeshPipeline* pipeline)
{
	if (self.count == 0) return;

	vk::cmdPushDescriptorSetKHR(
		cmd,
		PIPELINE_BIND_POINT_GRAPHICS,
		pipeline.layout,
		0,
		self.count,
		&self.writes[0]
	);
}
