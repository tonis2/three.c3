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
	MATERIAL_TEXTURE_UNKNOWN,
	MATERIAL_UNIFORM_UNKNOWN,
	MATERIAL_UNIFORM_WIDTH,
	MATERIAL_NEEDS_DEVICE,
	MATERIAL_REPEAT_IS_ZERO;

<*
 The material every node draws with until it is given another.

 Index 0 of `MeshPass.materials`, built in `MeshPass.init` from the same
 `mesh.slang` pipeline the pass has always used, so a scene that never mentions a
 material renders exactly as it did before this file existed.
*>
const uint DEFAULT_MATERIAL = 0;

<*
 Which faces a material keeps, in Three.js's own numbering.

 `FrontSide` is 0 there, `BackSide` 1 and `DoubleSide` 2, and matching the
 numbers rather than only the names means a script that hardcoded `side: 2` from
 memory of Three.js gets what it meant.
*>
const int SIDE_FRONT = 0;
const int SIDE_BACK = 1;
const int SIDE_DOUBLE = 2;

<*
 The cull mode a side means.

 **Culling is not an optional device feature**, unlike the wireframe fill mode
 `plan.md` §1 refuses to depend on: `cullMode` is core Vulkan with no capability
 bit behind it, so this needs no query and has no fallback path.

 The inversion is the thing to read twice. `BackSide` means *keep the back
 faces*, so it culls the front ones. Getting it the other way round renders a
 skydome that is invisible from inside — which is the exact bug this exists to
 fix, so it would look like nothing had changed.

 Anything unrecognised is `FrontSide`, the default every material had before
 this argument existed. The JS side refuses an unknown value by name before it
 reaches here; this is the floor under that, not the check.
*>
fn vk::CullModeFlags cull_for_side(int side)
{
	switch (side)
	{
		case SIDE_BACK: return CULL_MODE_FRONT_BIT;
		case SIDE_DOUBLE: return CULL_MODE_NONE;
		default: return CULL_MODE_BACK_BIT;
	}
}

<*
 How a material's colour combines with what is already on screen, in Three.js's
 own numbering.

 `NoBlending` is 0 there, `NormalBlending` 1 and `AdditiveBlending` 2 — matched
 for `SIDE_FRONT`'s reason: a script that wrote `blending: 2` from memory of
 Three.js gets what it meant. Three.js has `Subtractive` and `Multiply` at 3 and
 4 as well; they are not here, and leaving the numbers free is what lets them
 arrive later without renumbering anything a script may have hardcoded.

 The default is `NONE` and not `NORMAL`, which is worth stating because it is the
 opposite of what "a material has an opacity" suggests. An opaque pipeline
 ignores the alpha it writes, so a material that never asked to blend renders
 exactly as every material did before this existed, whatever its opacity says.
 Three.js behaves the same way — `opacity` without `transparent` does nothing —
 and the honest reason is the hardware's, not a rule anybody chose.
*>
const int BLENDING_NONE = 0;
const int BLENDING_NORMAL = 1;
const int BLENDING_ADDITIVE = 2;

<*
 The pipeline blend mode a `blending` number means.

 `cull_for_side`'s shape and its floor-not-check role: anything unrecognised is
 `NONE`, the behaviour every material had before blending existed, and the JS
 side refuses an unknown value **by name** before it reaches here. Two guards
 rather than one because they answer different questions — the boundary tells an
 agent what it typed wrong, and this makes sure a value that arrived any other
 way cannot select a pipeline nobody meant.
*>
fn BlendMode blend_for(int blending)
{
	switch (blending)
	{
		case BLENDING_NORMAL: return BlendMode.ALPHA;
		case BLENDING_ADDITIVE: return BlendMode.ADDITIVE;
		default: return BlendMode.NONE;
	}
}

<*
 The render state a blend mode is built over.

 One place rather than a switch at every `acquire`, because the *depth* half of
 the answer is the part that is easy to get wrong and impossible to see: an
 `ALPHA_STATE` written by hand with `depth_write: true` renders correctly in
 every scene where nothing overlaps itself. `ALPHA_STATE` has that argument.
*>
fn PipelineState state_for_blend(BlendMode blend)
{
	switch (blend)
	{
		case ALPHA: return ALPHA_STATE;
		case ADDITIVE: return ADDITIVE_STATE;
		case NONE: return SOLID_STATE;
	}
}

<*
 The material every debug line draws with.

 Index 1 of `MeshPass.materials`, built in `MeshPass.init` from the same
 `mesh.slang` the default material uses, over `LINE_STATE`.

 It is a *material* rather than a flag on the mesh because a bucket is
 `(asset, mesh, material)` and the material is what chooses the pipeline. Making
 topology a property of the geometry instead would mean every material needed a
 line variant of its pipeline, for a case in which nobody wants a custom shader:
 a debug line is a colour and a position, and `mesh.color` already carries the
 colour per copy for free.

 A script cannot name it. `three.AxesHelper` and its siblings set it themselves,
 and `MeshPass.set_material_side` refuses it — a line pipeline with a cull mode
 would be a pipeline built from a state nobody meant.
*>
const uint LINE_MATERIAL = 1;

<*
 Where a material's uniforms begin in the push block.

 The mesh contract owns everything below this: `MESH_PUSH_FIELDS` ends with
 `uv_transform` at 60+16, and `shaders/material.slang` declares those eight
 fields first and in that order so `check_push_block` passes on a generated
 module exactly as it does on `mesh.slang`. The `$assert` is what makes this a
 derived number rather than a copied one — and it earned that when
 `uv_transform` was added and this moved from 60 to 76 without anyone having to
 remember it existed.
*>
const uint MATERIAL_PUSH_START = 76;

$assert MESH_PUSH_FIELDS[MESH_PUSH_FIELDS.len - 1].offset + MESH_PUSH_FIELDS[MESH_PUSH_FIELDS.len - 1].size == MATERIAL_PUSH_START :
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

 ## Three fields are shaped around C3's zero fill, and each answers it differently

 A designated initializer leaves out what it does not name and C3 writes zero
 there, so every field here has to have an answer for "what does a construction
 site that forgot me produce". There are exactly three strategies in use and they
 are worth reading together, because which one is right depends entirely on
 whether zero is a *legal value* of the field:

 - `texture` — zero is a perfectly ordinary texture index, so no encoding saves
   it. `NO_TEXTURE` is -1 and **every construction site names the field**, which
   makes forgetting possible on purpose: the mistake shows up as a wrong picture
   rather than being silently absorbed.
 - `uv_transform` — zero is a legal number but a meaningless *transform*, so the
   all-zero value is read as "unset" and the boundary refuses a script that tries
   to write one. Nobody has to remember anything.
 - `one_minus_opacity` — zero is both legal and meaningful (fully transparent),
   and the *common* case is the one that must be free. So the field stores the
   complement: zero fill spells opacity 1, and an opacity of exactly 0 is still
   representable rather than being stolen by a sentinel.

 The pattern behind all three: encode when zero is meaningful and the default is
 not zero; require naming when no encoding is honest.
*>
struct Material
{
	MeshPipeline* pipeline;
	// Which faces survive, as `material.side` chose them. Set at record time with
	// `vk::cmdSetCullMode` rather than baked into `pipeline`, so two materials that
	// differ only in their side share one `VkPipeline` and changing a side builds
	// nothing at all. `PipelineState` has the argument, including why topology did
	// not get the same treatment.
	vk::CullModeFlags cull;
	// The body the agent wrote, owned. Kept for `toJSON` and for the error
	// message when a uniform name does not resolve — "that material has no
	// uniform called X" is only actionable next to the source that declared them.
	String fragment;
	// `material.map` — an index into `Assets.textures`, or `NO_TEXTURE` for
	// "whatever the mesh brought". Holds one reference to that slot for as long
	// as it names it; `MeshPass.set_material_map` is the only thing that moves
	// it, so that the retain and the release cannot get out of step.
	//
	// **This must be set explicitly at every site that builds a `Material`.**
	// C3 zero-fills what a designated initializer leaves out, and zero is a
	// perfectly ordinary texture index — so a forgotten `.texture` does not
	// render untextured, it renders whatever the *first* image the table
	// uploaded happens to be. That is a bug that looks like a texture bug, on a
	// material nobody gave a texture to. `NO_TEXTURE` is -1 rather than 0 so
	// that the mistake is possible to make; the alternative, a biased
	// index-plus-one, makes it impossible and makes every read arithmetic.
	int texture;
	// `material.repeat` and `material.offset` — xy is how many times the texture
	// repeats across the surface, zw is where it starts.
	//
	// **All zeros means unset, and is read as the identity.** That is the answer
	// to the hazard the `.texture` comment above spends a paragraph on: C3
	// zero-fills what an initializer omits, and here zero would be a repeat of
	// zero, which collapses a whole surface onto one texel — a black or
	// single-colour shape, on a material nobody gave a transform to. Rather than
	// require every construction site to remember, `uv_transform_or_identity`
	// treats the zero value as "none", and a script that writes a zero repeat is
	// refused by name at the boundary because a zero repeat means nothing anyone
	// wants.
	float[4] uv_transform;
	// Which blend mode the material's pipeline was built with — `material.blend`
	// and `material.transparent`, decided once, at construction.
	//
	// A copy of what `PipelineState.blend` already says, kept here because the two
	// readers cannot get at that: `Scene`'s draw ordering needs to know which
	// buckets are transparent without reaching into a `MeshPipeline`, and the
	// exporter needs it to write `alphaMode`. `NONE` is the zero fill and means
	// what every material meant before this field existed.
	//
	// **There is no setter**, unlike `cull`. Blending is baked into the pipeline
	// on this device (`BlendMode` has the measurement), so changing it would mean
	// re-acquiring — a device, a target and the assembled source read back out of
	// the cache — to save a script one line. Building a new material is that line.
	BlendMode blend;
	// `material.opacity`, stored as **1 - opacity** so that the zero fill is the
	// common case.
	//
	// Reading `1.0` out of a field nobody wrote is the whole reason for the
	// inversion, and the alternative was tried and thrown out: a plain `opacity`
	// field would make every forgotten initializer produce an invisible material —
	// geometry that does not render, on a material nobody said anything about,
	// which is the failure mode that costs an agent the most to diagnose. A
	// sentinel would have cost the one value a fade-out has to reach. See the
	// header for the other two answers to the same problem.
	//
	// Never read directly outside `Material.opacity`.
	float one_minus_opacity;
	char[PUSH_BUDGET] block;
	// Whether this slot holds a material at all. False for a slot whose material
	// was collected, which stays in the list so that every index ever handed out
	// keeps meaning what it meant — and is handed to the next `create_material`
	// rather than growing the list forever.
	//
	// Never set at a construction site: `MeshPass.claim_slot` is the only thing
	// that makes a material live, precisely so that C3's zero-fill cannot produce
	// a material that is dead the moment it is built.
	bool alive;
	// Whether the script's handle has been given back — `material.dispose()`.
	//
	// **Not the same as dead.** A material is collected when this is true *and*
	// no node still names it, which is the rule `texture.dispose()` already
	// follows: giving back a handle is a statement about the handle, and a mesh
	// that is still drawing with the material is not wrong for doing so.
	// `MeshPass.collect_materials` is where the two halves meet.
	bool released;
}

<*
 The identity uv transform: repeat once, start at the corner.
*>
const float[4] UV_IDENTITY = { 1, 1, 0, 0 };

<*
 What to push for this material's uv transform.

 See `Material.uv_transform` for why an all-zero value is "unset" rather than a
 repeat of zero. Checked on the scale only: an offset with no scale is still a
 transform somebody asked for, and a zero *scale* is the only part that is never
 meaningful.
*>
fn float[4] Material.uv_transform_or_identity(&self)
{
	if (self.uv_transform[0] == 0 && self.uv_transform[1] == 0) return UV_IDENTITY;
	return self.uv_transform;
}

<*
 What `material.opacity` reads back as: `1 - one_minus_opacity`.

 The only reader of the stored field. Everything else asks through here, so the
 complement stays an implementation detail of the struct rather than something
 every call site has to remember to undo — which is exactly how a stored
 complement turns into a bug the second time somebody touches it.
*>
fn float Material.opacity(&self)
{
	return 1.0f - self.one_minus_opacity;
}

<*
 `Material.texture` for a material that has none of its own.

 The mesh's texture is what such a material draws with, which is what every
 material did before `map` existed and is why a glTF's own materials still work
 unchanged: the file's image rides on the `GpuMesh`, and nothing about that
 moved.
*>
const int NO_TEXTURE = -1;

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
	// **Not left at the zero fill.** Zero is a perfectly ordinary texture index —
	// the hazard `Material.texture` spends a paragraph on — and a collected slot
	// that reads as naming texture 0 would have that slot released a second time
	// by `MeshPass.free`'s sweep at teardown.
	self.texture = NO_TEXTURE;
}
