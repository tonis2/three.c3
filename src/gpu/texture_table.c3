<*
 One descriptor array holding every texture on the device, indexed by the slot
 the registry already gave it.

 ## Why combined image samplers and not a sampler array beside an image array

 `Gpu.finish_texture` builds a sampler *per texture*, and two of its three
 settings are properties of the image rather than of the material asking for it:
 `maxLod` is that image's own level count, and `nearest` picks the filter and the
 mipmap mode together. So a shared `SamplerState samplers[K]` would need one entry
 per (filter, level count) pair — sixty-four of them — and every one would have to
 be kept in step with `finish_texture` by hand, for the sole benefit of splitting
 one index into two. A combined array is one `uint` per texture, which is also
 exactly what a material's table row wants to carry.

 If the engine ever grows address modes or anisotropy per *material*, that is the
 point at which the split earns itself; nothing here would move except this
 binding's descriptor type.

 ## The one descriptor pool in the project

 `Gpu`'s header says there are no descriptor pools anywhere, and that is still
 true of everything a draw pushes: `MeshPipeline` layouts carry
 `PUSH_DESCRIPTOR_BIT` and their sets are specified inline. This set is the
 opposite kind of thing — it is written when a texture is uploaded and read for
 the rest of that texture's life — so it is allocated once, from a pool of one
 set, and never touched per frame.

 `UPDATE_AFTER_BIND` is what makes that legal: a texture uploaded in the middle of
 a frame writes its descriptor immediately, with no regard for command buffers
 already recorded against the set, and `PARTIALLY_BOUND` is what lets the slots
 nothing has claimed yet stay unwritten.
*>
module three;

import vk;

// One index per texture, and nothing reads two arrays.
const uint TEXTURE_TABLE_BINDING = 0;

<*
 Which set the table is bound at, in every pipeline layout that samples anything.

 Set 1 rather than set 0 because set 0 is the material's own push-descriptor set
 and every template numbers its bindings into it. Two pipeline layouts are only
 compatible up to set N when sets 0..N were built from identical layouts, and set
 0 differs per shader — so the table is rebound whenever the pipeline changes
 rather than once per frame. That is a handful of commands per frame at this
 project's pipeline counts.
*>
const uint TEXTURE_TABLE_SET = 1;

// A ceiling on top of whatever the device offers. 16384 combined image samplers
// is 256 KB of descriptors and more textures than any scene here has had; the
// point of the cap is that a device reporting 1048576 should not be taken at its
// word for an allocation nothing will use.
const uint TEXTURE_TABLE_MAX = 16384;

<*
 How many textures one array may hold on this device, or 0 when it may not have
 one at all.

 The smallest of the four update-after-bind counts, because a combined image
 sampler spends one sampler *and* one sampled image, per stage and per set.
*>
fn uint GpuLimits.texture_table_size(&self)
{
	if (!self.bindless) return 0;

	uint smallest = self.max_update_after_bind_sampled_images;
	if (self.max_update_after_bind_samplers < smallest) smallest = self.max_update_after_bind_samplers;
	if (self.max_set_update_after_bind_sampled_images < smallest) smallest = self.max_set_update_after_bind_sampled_images;
	if (self.max_set_update_after_bind_samplers < smallest) smallest = self.max_set_update_after_bind_samplers;
	return smallest < TEXTURE_TABLE_MAX ? smallest : TEXTURE_TABLE_MAX;
}

struct TextureTable
{
	vk::DescriptorSetLayout layout;
	vk::DescriptorPool pool;
	vk::DescriptorSet set;
	uint capacity;
	// Slots pointing at a real image right now — `stats().textureSlots`. Not the
	// high-water mark: a released slot goes back to the fallback and comes off this
	// count, which is what makes it comparable with `stats().textures`.
	uint used;
	// The 1x1 white a released slot is pointed at, so a material still carrying a
	// dead index samples white instead of a destroyed image. Handed over by
	// `Assets` once its own white exists; until then a release simply leaves the
	// slot alone, which `PARTIALLY_BOUND` allows.
	vk::DescriptorImageInfo fallback;
	bool has_fallback;
	bool ready;
}

<*
 Builds the layout, the pool and the one set.

 A no-op that leaves `ready` false on a device without the features, which is what
 keeps the old path the path: nothing asks the table for anything it has not got.
*>
fn void? TextureTable.init(&self, Gpu* gpu)
{
	uint capacity = gpu.limits.texture_table_size();
	if (capacity == 0) return;

	vk::DescriptorBindingFlags[1] flags = {
		DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT | DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT
			| DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT,
	};
	vk::DescriptorSetLayoutBindingFlagsCreateInfo binding_flags = vk::descriptorSetLayoutBindingFlagsCreateInfo()
		.setBindingFlags(flags[..]);

	vk::DescriptorSetLayoutBinding[1] bindings = {
		{
			.binding = TEXTURE_TABLE_BINDING,
			.descriptorType = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
			.descriptorCount = capacity,
			.stageFlags = SHADER_STAGE_VERTEX_BIT | SHADER_STAGE_FRAGMENT_BIT,
		},
	};

	self.layout = vk::descriptorSetLayoutCreateInfo().setFlags(DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT)
		.setBindings(bindings[..])
		.setNext(&binding_flags)
		.build(gpu.handle)!;

	vk::DescriptorPoolSize[1] sizes = {
		{ .type = DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = capacity },
	};
	self.pool = vk::descriptorPoolCreateInfo().setFlags(DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT).setMaxSets(1)
		.setPoolSizes(sizes[..])
		.build(gpu.handle)!;

	// The whole array, asked for through the variable-count path rather than
	// implied by the layout: the feature is requested, so the allocation is the
	// place that proves it works.
	uint[1] counts = { capacity };
	vk::DescriptorSetVariableDescriptorCountAllocateInfo variable = vk::descriptorSetVariableDescriptorCountAllocateInfo()
		.setDescriptorCounts(counts[..]);
	vk::DescriptorSetLayout[1] layouts = { self.layout };
	vk::DescriptorSetAllocateInfo alloc = vk::descriptorSetAllocateInfo().setDescriptorPool(self.pool)
		.setSetLayouts(layouts[..])
		.setNext(&variable);

	vk::allocateDescriptorSets(gpu.handle, &alloc, &self.set)!;

	self.capacity = capacity;
	self.ready = true;
}

<*
 The slot the white fallback lives in: the last one.

 Reserved rather than shared with the registry, so "no texture here" is an index
 like any other and a shader never has to test one. Everything a material leaves
 unset points at it, and so does every slot a dispose gave back.
*>
fn uint TextureTable.fallback_slot(&self) => self.ready ? self.capacity - 1 : 0;

// How many slots the registry may hand out — everything but the fallback's.
fn uint TextureTable.usable(&self) => self.ready ? self.capacity - 1 : 0;

<*
 Fills the fallback slot with the 1x1 white and remembers it.

 Called once, when `Assets` builds its own white. Until it is, a release leaves
 the slot alone — which `PARTIALLY_BOUND` allows and nothing can reach anyway,
 because a material with no textures has no index to carry.
*>
fn void TextureTable.set_fallback(&self, Gpu* gpu, vk::DescriptorImageInfo info)
{
	if (!self.ready) return;
	self.fallback = info;
	self.has_fallback = true;
	self.write_slot(gpu, self.fallback_slot(), info);
}

// One descriptor, written where the set already is. Update-after-bind, so a
// command buffer recorded against this set stays valid.
fn void TextureTable.write_slot(&self, Gpu* gpu, uint index, vk::DescriptorImageInfo info)
{
	vk::DescriptorImageInfo[1] infos = { info };
	vk::WriteDescriptorSet write = vk::writeDescriptorSet().setDstSet(self.set)
		.setDstBinding(TEXTURE_TABLE_BINDING)
		.setDstArrayElement(index)
		.setDescriptorType(DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER)
		.setImageInfo(infos[..]);
	vk::updateDescriptorSets(gpu.handle, 1, &write, 0, null);
}

<*
 Points one slot at one image.

 Called from `Assets.install_texture`, so an index is written before anything can
 name it. Update-after-bind: no frame-slot copies, no waiting for the device, and
 a command buffer already recorded against this set stays valid.
*>
fn void TextureTable.write(&self, Gpu* gpu, uint index, vk::DescriptorImageInfo info)
{
	if (!self.ready || index >= self.usable()) return;

	self.write_slot(gpu, index, info);
	self.used++;
}

<*
 Points one slot back at the white fallback.

 The whole reason a released index is survivable: `Assets.release_texture`
 destroys the image, and anything still carrying that index reads white rather
 than a freed `VkImageView`.
*>
fn void TextureTable.release(&self, Gpu* gpu, uint index)
{
	if (!self.ready || index >= self.usable()) return;
	if (self.used > 0) self.used--;
	if (!self.has_fallback) return;

	self.write_slot(gpu, index, self.fallback);
}

<*
 Binds the table for one pipeline layout.

 Beside the pipeline bind rather than once at the top of the frame, because a
 descriptor set binding survives only while the layouts stay compatible up to its
 own set number — and set 0 is the material's, which differs per shader.
*>
fn void TextureTable.bind(&self, vk::CommandBuffer cmd, vk::PipelineLayout layout)
{
	if (!self.ready) return;
	vk::cmdBindDescriptorSets(cmd, PIPELINE_BIND_POINT_GRAPHICS, layout, TEXTURE_TABLE_SET, 1, &self.set, 0, null);
}

fn void TextureTable.free(&self, Gpu* gpu)
{
	if (!self.ready) return;
	// The set goes with the pool; there is no per-set free and nothing asks for one.
	vk::destroyDescriptorPool(gpu.handle, self.pool, null);
	self.layout.free(gpu.handle);
	*self = { };
}
