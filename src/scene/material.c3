<*
 What a mesh is drawn *with*: a pipeline, and the uniform bytes that go with it.

 `plan.md`'s source tree has carried a line for this file since M0 and M2
 deliberately did not write it: "at M2 a material is a base colour factor and a
 texture index, both carried on `GpuMesh`, and both resolve to the one pipeline —
 a `Material` struct with exactly those two fields would be a name for something
 that already has one. It arrives at M5 with `ShaderMaterial`, which is the first
 thing that makes a material a choice between pipelines."

 ## The uniforms ride in the push block, not in a uniform buffer

 `shaders/material.slang` appends the agent's uniforms to the same push block the
 mesh contract already uses, after `flags`. That is 68 free bytes — 17 floats —
 and it is the whole storage story.

 The alternative, a `ConstantBuffer<Params>` reached by descriptor, costs four
 things that do not exist yet: reflection of uniform-block *members* (Slang
 reports a constant buffer as one opaque binding and the externs to walk into it
 are not even declared in `lib/slang.c3l`), a `UNIFORM_BUFFER` usage bit on
 `Gpu.create_dynamic`, a descriptor pool sized for it, and a per-frame-slot ring
 so a buffer the GPU may still be reading is never overwritten (`plan.md` §6, the
 trap that tore crig's pose palette). The push block costs none of them: reflection
 of push fields by name and byte offset is already built, already tested
 byte-for-byte, and already the mechanism `base_color` reaches the shader through.

 What it refuses is a material with more than 68 bytes of uniforms — no textures
 of its own, no arrays, no matrices beyond a couple. That is the right trade for
 tier 2, whose whole claim is "a fragment function, not a pipeline". The day a
 material wants its own texture is the day the uniform buffer gets written, and
 `MATERIAL_UNIFORM_BUDGET` is where that conversation starts.

 ## A material is an index, and the default one is shared

 `Node.material` is a `uint` into `MeshPass.materials`, and every node starts on
 `DEFAULT_MATERIAL`. It has to be a shared index rather than a per-node value:
 `a_thousand_instances_are_one_draw_call` is the project's central claim, and it
 stops being true the moment two nodes drawing the same mesh disagree about their
 material. Handing every new node its own material id would keep every test's
 numbers green while quietly turning one draw call into a thousand.
*>
module three;

import std::collections::list;
import std::io;
import vk;

faultdef
	MATERIAL_UNKNOWN,
	MATERIAL_UNIFORM_UNKNOWN,
	MATERIAL_UNIFORM_WIDTH,
	MATERIAL_NEEDS_DEVICE;

<*
 The material every node draws with until it is given another.

 Index 0 of `MeshPass.materials`, built in `MeshPass.init` from the same
 `mesh.slang` pipeline the pass has always used, so a scene that never mentions a
 material renders exactly as it did before this file existed.
*>
const uint DEFAULT_MATERIAL = 0;

<*
 Where a material's uniforms begin in the push block.

 The mesh contract owns everything below this: `MESH_PUSH_FIELDS` ends with
 `flags` at 56+4, and `shaders/material.slang` declares those seven fields first
 and in that order so `check_push_block` passes on a generated module exactly as
 it does on `mesh.slang`. The `$assert` is what makes this a derived number
 rather than a copied one.
*>
const uint MATERIAL_PUSH_START = 60;

$assert MESH_PUSH_FIELDS[6].offset + MESH_PUSH_FIELDS[6].size == MATERIAL_PUSH_START :
	"the mesh push block moved; material uniforms no longer start where the template puts them";
$assert MATERIAL_PUSH_START + MATERIAL_UNIFORM_BUDGET == PUSH_BUDGET :
	"the material uniform budget and the push budget disagree";

<*
 One material: a pipeline to bind, and the bytes to push with it.

 `block` is laid out *as the push block itself* rather than as a list of values.
 Everything below `MATERIAL_PUSH_START` is overwritten per draw with the mesh's
 own push data; everything at or above it is the material's, written once when a
 uniform is set and memcpy'd straight out at record time. That means setting a
 uniform costs a bounds check and a copy of at most 16 bytes, and drawing costs
 no per-uniform loop at all.

 `pipeline` is borrowed from `MeshPass.pipelines`, which hands out heap-boxed
 entries precisely so a live pointer survives the cache growing.
*>
struct Material
{
	MeshPipeline* pipeline;
	// The body the agent wrote, owned. Kept for `toJSON` and for the error
	// message when a uniform name does not resolve — "that material has no
	// uniform called X" is only actionable next to the source that declared them.
	String fragment;
	char[PUSH_BUDGET] block;
}

<*
 Point a uniform at new values.

 The name is resolved through the pipeline's *reflected* push fields rather than
 through anything this side remembers, which is what makes the offsets right by
 construction: Slang decided them, and `-force-glsl-scalar-layout` is what makes
 them tight and predictable. A name below `MATERIAL_PUSH_START` resolves — it is
 a real field — and is refused anyway, because writing `base_color` or
 `positions` through this door would corrupt a BDA pointer and crash in the
 driver rather than here.

 ## One row at a time, because a table is a column of them

 A uniform declared with rows is `float3 tint[4]` in the shader — one column of
 the material's table, selected per instance by `Surface.variant`. It is written
 a row at a time rather than whole, so the caller needs no view of the whole
 column and `material.uniforms.tint[2] = [1, 0, 0]` is one crossing.

 **The shape is stated rather than inferred**, which is what keeps the width
 check exact. `field.size` alone cannot tell a `float4` from two `float2`s, so
 asking the caller for both numbers and requiring `width * rows` to be the size
 the shader reflected refuses a caller that has the shape wrong — instead of
 silently writing half a row.

 @param values : `One to four floats. Must match the width the shader declared.`
 @param row : `Which row of the column, 0 for a plain uniform.`
 @param rows : `How many rows the caller believes the column has. 1 for a plain uniform.`
 @return? MATERIAL_UNIFORM_UNKNOWN : `No uniform of that name in this material.`
 @return? MATERIAL_UNIFORM_WIDTH : `The shader declared a different number of components, a different number of rows, or the row is past the end.`
*>
fn void? Material.set_uniform(&self, String name, float[] values, uint row = 0, uint rows = 1)
{
	ShaderField* field = self.pipeline.shader.field_of(name);
	if (field == null || field.offset < MATERIAL_PUSH_START) return MATERIAL_UNIFORM_UNKNOWN~;

	uint width = (uint)(values.len * float::size);
	if (width == 0 || rows == 0 || row >= rows) return MATERIAL_UNIFORM_WIDTH~;
	if (field.size != width * rows) return MATERIAL_UNIFORM_WIDTH~;

	uint at = field.offset + row * width;
	if (at + width > PUSH_BUDGET) return MATERIAL_UNIFORM_WIDTH~;

	mem::copy(&self.block[at], values.ptr, width);
}

<*
 Every uniform this material declared, in the order the shader laid them out.

 Reads the reflected push fields and drops the mesh contract's seven, which is
 the same cut `set_uniform` makes. Used by the JS side to build the accessors on
 `material.uniforms` — the prelude cannot enumerate them any other way, because
 the QuickJS shim has no property enumeration at all.
*>
fn void Material.uniform_fields(&self, List{ShaderField}* out)
{
	foreach (field : self.pipeline.shader.push_fields)
	{
		if (field.offset >= MATERIAL_PUSH_START) out.push(field);
	}
}

fn void Material.free(&self)
{
	if (self.fragment.len > 0) self.fragment.free(mem);
	*self = { };
}
