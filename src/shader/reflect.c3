<*
 Slang reflection, turned into the two things Vulkan asks for.

 `plan.md` §3 is direct about why this file is the actual requirement and not the
 compiler: what makes Three.js's `ShaderMaterial` feel effortless is that it
 introspects the shader and wires the uniforms up for you. Without the
 equivalent, every agent-written shader needs a hand-authored descriptor
 declaration beside it, and "just write the shader" dies on contact.

 So: a descriptor set layout derived from the module, and a name → offset map for
 the push block. Both are read out of the same compile that produced the SPIR-V,
 so they cannot describe a different module than the one that runs.

 ## Three views of the same parameter, and only one of them is enough

 A `Sampler2D` and a `Texture2D` are indistinguishable at two of the three levels
 Slang exposes:

	type kind           RESOURCE for both
	parameter category  DESCRIPTOR_TABLE_SLOT for both
	binding range type  COMBINED_TEXTURE_SAMPLER vs TEXTURE

 Only the third says which. Deriving a set layout from the first two produces a
 `SAMPLED_IMAGE` where the shader wants a `COMBINED_IMAGE_SAMPLER`, which is a
 validation error at best and a black screen at worst — `plan.md` §7 names
 exactly this: "getting this wrong produces a black screen, not an error".

 The binding *index* comes from a fourth view again — the descriptor-set one —
 because that is the view that knows about `[vk::binding(n, m)]`. The binding
 range's own index is its position in the declaration order, which is the same
 number often enough to look correct.

 ## The push block is not a descriptor

 It reflects as a constant buffer, like `ConstantBuffer<T>` does, and the only
 thing separating them is the parameter category. Putting a push block into a set
 layout is a validation error naming a binding the shader never declared.
*>
module three;

import std::collections::list;
import vk;
import slang;

<*
 One thing the shader wants bound, in the terms `vkCreateDescriptorSetLayout`
 takes.
*>
struct ShaderBinding
{
	String name;
	uint set;
	uint binding;
	// Greater than one for an array — `Texture2D extras[4]` is one binding of
	// four, not four bindings.
	uint count;
	vk::DescriptorType type;
	vk::ShaderStageFlags stages;
}

<*
 One field of the push block: where it starts and how long it is.
*>
struct ShaderField
{
	String name;
	uint offset;
	uint size;
}

<*
 What a compiled module needs bound, and what its push block looks like.

 Owned; free with `ShaderLayout.free`.
*>
struct ShaderLayout
{
	List{ShaderBinding} bindings;
	List{ShaderField} push_fields;
	// Bytes, as the shader lays them out. Zero if the shader has no push block.
	uint push_size;
	// The union of every entry point's stage. See `stage_union` for why the
	// union rather than the precise per-binding set.
	vk::ShaderStageFlags stages;
	// How many distinct descriptor sets the bindings fall into. One, for
	// everything this project draws so far.
	uint set_count;
}

<*
 A deep copy, names included.

 Exists because one compiled module now serves several pipelines — the line pass
 and the solid pass are the same `mesh.slang` over two fixed-function states, and
 `material.side` is the same material source over two cull modes. `PipelineCache`
 keeps the module and hands each pipeline one of these.

 **A copy rather than a shared pointer**, which is the choice `MeshPipeline`'s
 own comment argues: a pipeline holding a pointer into the module would outlive
 what it points at the moment a caller freed the module, and a layout is a few
 dozen short strings — the price of getting that wrong is far higher than the
 price of copying it.
*>
fn ShaderLayout ShaderLayout.copy(&self)
{
	ShaderLayout out = {
		.push_size = self.push_size,
		.stages = self.stages,
		.set_count = self.set_count,
	};

	out.bindings.init(mem, self.bindings.len() > 0 ? self.bindings.len() : 1);
	foreach (binding : self.bindings)
	{
		ShaderBinding copied = binding;
		copied.name = binding.name.copy(mem);
		out.bindings.push(copied);
	}

	out.push_fields.init(mem, self.push_fields.len() > 0 ? self.push_fields.len() : 1);
	foreach (field : self.push_fields)
	{
		ShaderField copied = field;
		copied.name = field.name.copy(mem);
		out.push_fields.push(copied);
	}

	return out;
}

fn void ShaderLayout.free(&self)
{
	foreach (binding : self.bindings) if (binding.name.ptr != null) binding.name.free(mem);
	foreach (field : self.push_fields) if (field.name.ptr != null) field.name.free(mem);
	self.bindings.free();
	self.push_fields.free();
	*self = {};
}

<*
 Find a binding by the name it has in the shader.

 @return `A pointer into the list, or null. Invalid after the layout is freed.`
*>
fn ShaderBinding* ShaderLayout.binding_of(&self, String name)
{
	foreach (i, &binding : self.bindings) if (binding.name == name) return binding;
	return null;
}

<*
 Find a push-constant field by name — the map a material layer writes uniforms
 through.

 @return `A pointer into the list, or null. Invalid after the layout is freed.`
*>
fn ShaderField* ShaderLayout.field_of(&self, String name)
{
	foreach (i, &field : self.push_fields) if (field.name == name) return field;
	return null;
}

<*
 Not a Vulkan descriptor type, and deliberately not a legal one.

 vulkan.c3l's `DescriptorType` has no `MAX_ENUM` member, and a sentinel is
 needed for "the shader asked for something this pass cannot bind". Zero would
 be wrong — that is `SAMPLER`.
*>
const vk::DescriptorType DESCRIPTOR_TYPE_UNBINDABLE = (vk::DescriptorType)0xFFFF_FFFF;

<*
 Which Vulkan descriptor a Slang binding range is.

 Anything not listed arrives as `DESCRIPTOR_TYPE_UNBINDABLE`, which is refused by
 `MeshPipeline.init` with the parameter's name attached. That
 is the deliberate choice: a shader declaring an acceleration structure is not
 something this pass can bind, and guessing `STORAGE_BUFFER` for it would fail
 later and further away.
*>
fn vk::DescriptorType descriptor_type_of(uint binding_type)
{
	bool mutable = (binding_type & slang::BINDING_MUTABLE_FLAG) != 0;
	switch (binding_type & slang::BINDING_BASE_MASK)
	{
		case slang::BINDING_SAMPLER:
			return DESCRIPTOR_TYPE_SAMPLER;
		case slang::BINDING_TEXTURE:
			return mutable ? DESCRIPTOR_TYPE_STORAGE_IMAGE : DESCRIPTOR_TYPE_SAMPLED_IMAGE;
		case slang::BINDING_COMBINED_TEXTURE_SAMPLER:
			return DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
		case slang::BINDING_CONSTANT_BUFFER:
		case slang::BINDING_PARAMETER_BLOCK:
			return DESCRIPTOR_TYPE_UNIFORM_BUFFER;
		case slang::BINDING_RAW_BUFFER:
			return DESCRIPTOR_TYPE_STORAGE_BUFFER;
		case slang::BINDING_TYPED_BUFFER:
			return mutable ? DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER : DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER;
		case slang::BINDING_INPUT_RENDER_TARGET:
			return DESCRIPTOR_TYPE_INPUT_ATTACHMENT;
		default:
			return DESCRIPTOR_TYPE_UNBINDABLE;
	}
}

<*
 The Vulkan stage flag for a Slang stage.
*>
fn vk::ShaderStageFlags stage_flag_of(uint stage)
{
	switch (stage)
	{
		case slang::STAGE_VERTEX: return SHADER_STAGE_VERTEX_BIT;
		case slang::STAGE_HULL: return SHADER_STAGE_TESSELLATION_CONTROL_BIT;
		case slang::STAGE_DOMAIN: return SHADER_STAGE_TESSELLATION_EVALUATION_BIT;
		case slang::STAGE_GEOMETRY: return SHADER_STAGE_GEOMETRY_BIT;
		case slang::STAGE_FRAGMENT: return SHADER_STAGE_FRAGMENT_BIT;
		case slang::STAGE_COMPUTE: return SHADER_STAGE_COMPUTE_BIT;
		default: return (vk::ShaderStageFlags)0;
	}
}

<*
 Every stage the module contains, as one flag set.

 **This is the union, not the per-binding truth**, and that is on purpose.
 `spIsParameterLocationUsed` would say precisely which stages touch which
 binding, and being wrong about it in the tight direction is a descriptor the
 shader reads and the layout does not declare — undefined behaviour, reported by
 nothing. A stage flag wider than necessary is legal, costs nothing at draw time,
 and cannot be wrong. It is still *derived* — the entry points come from
 reflection — which is what M4 is about.
*>
fn vk::ShaderStageFlags stage_union(ShaderEntry[] entries)
{
	vk::ShaderStageFlags flags = (vk::ShaderStageFlags)0;
	foreach (entry : entries) flags |= stage_flag_of(entry.stage);
	return flags;
}

<*
 Walk a compiled program's reflection into a `ShaderLayout`.

 The result owns copies of every name, because the reflection they point into
 dies with the compile request.
*>
fn ShaderLayout reflect_layout(slang::Reflection reflection, ShaderEntry[] entries)
{
	ShaderLayout out;
	out.bindings.init(mem, 4);
	out.push_fields.init(mem, 8);
	out.stages = stage_union(entries);

	if (reflection == null) return out;

	@pool()
	{
		List{slang::Descriptor} descriptors;
		descriptors.tinit(8);
		reflection.descriptors(&descriptors);

		uint highest = 0;
		foreach (descriptor : descriptors)
		{
			out.bindings.push({
				.name = descriptor.name.copy(mem),
				.set = descriptor.set,
				.binding = descriptor.binding,
				.count = descriptor.count,
				.type = descriptor_type_of(descriptor.type),
				.stages = out.stages,
			});
			if (descriptor.set + 1 > highest) highest = descriptor.set + 1;
		}
		out.set_count = highest;

		List{slang::Field} fields;
		fields.tinit(8);
		out.push_size = reflection.push_block(&fields);
		foreach (field : fields)
		{
			out.push_fields.push({
				.name = field.name.copy(mem),
				.offset = field.offset,
				.size = field.size,
			});
		}
	};

	return out;
}
