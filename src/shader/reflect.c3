<*
 What a compiled module needs bound, and what its push block looks like.

 A module's own reflection produces both: the descriptors are read out of the
 SPIR-V that is about to run (`reflect_shady_module`), and the push block is
 walked from the C3 struct the pass fills (`compile_shady`), so neither can
 describe a different module than the one loaded.

 ## The stage union

 `ShaderLayout.stages` is the union of every entry point's stage, not which
 binding is read by which stage. Being wrong in the tight direction is a
 descriptor the shader reads and the layout does not declare — undefined
 behaviour, reported by nothing. A stage flag wider than necessary is legal,
 costs nothing at draw time, and cannot be wrong.
*>
module three;

import std::collections::list;
import vk;

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
	// True for a uniform that lives in the table buffer rather than in the push
	// block; `offset` is then within that buffer. `MATERIAL_TABLE_FIELD` is the
	// pointer these hang off, and `scene/material.c3` has why a table spills
	// there at all.
	bool indirect;
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
	// The union of every entry point's stage. See the header for why the union
	// rather than the precise per-binding set.
	vk::ShaderStageFlags stages;
	// How many distinct descriptor sets the bindings fall into. One, for
	// everything this project draws so far.
	uint set_count;
}

<*
 A deep copy, names included.

 One compiled module serves several pipelines — the line pass and the solid pass
 are the same mesh module over two fixed-function states, and `material.side`
 is one material source over two cull modes. `PipelineCache` keeps the module
 and hands each pipeline one of these.

 A copy rather than a shared pointer: a pipeline holding a pointer into the
 module outlives what it points at the moment a caller frees the module, and a
 layout is only a few dozen short strings.
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
	*self = { };
}

<*
 Finds a binding by the name it has in the shader.

 @return `A pointer into the list, or null. Invalid after the layout is freed.`
*>
fn ShaderBinding* ShaderLayout.binding_of(&self, String name)
{
	foreach (i, &binding : self.bindings) if (binding.name == name) return binding;
	return null;
}

<*
 Finds a push-constant field by name — the map a material layer writes uniforms
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
 The Vulkan stage flag for one of the engine's stage numbers.
*>
fn vk::ShaderStageFlags stage_flag_of(uint stage)
{
	switch (stage)
	{
		case STAGE_VERTEX: return SHADER_STAGE_VERTEX_BIT;
		case STAGE_HULL: return SHADER_STAGE_TESSELLATION_CONTROL_BIT;
		case STAGE_DOMAIN: return SHADER_STAGE_TESSELLATION_EVALUATION_BIT;
		case STAGE_GEOMETRY: return SHADER_STAGE_GEOMETRY_BIT;
		case STAGE_FRAGMENT: return SHADER_STAGE_FRAGMENT_BIT;
		case STAGE_COMPUTE: return SHADER_STAGE_COMPUTE_BIT;
		default: return (vk::ShaderStageFlags)0;
	}
}

<*
 Every stage the module contains, as one flag set.
*>
fn vk::ShaderStageFlags stage_union(ShaderEntry[] entries)
{
	vk::ShaderStageFlags flags = (vk::ShaderStageFlags)0;
	foreach (entry : entries) flags |= stage_flag_of(entry.stage);
	return flags;
}
