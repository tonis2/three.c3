<*
 What a mesh is drawn *with*: a pipeline, and the uniform bytes that go with it.

 ## The uniforms ride in the push block, not in a uniform buffer

 `shaders/material.slang` appends the agent's uniforms to the same push block the
 mesh contract already uses. That is the whole storage story for *values*.

 Textures are not in it and never were. A sampler is a descriptor, so the ones a
 material declares cost the push block nothing and the budget below is only ever
 about floats.

 The alternative, a `ConstantBuffer<Params>` reached by descriptor, costs four
 things that do not exist here: reflection of uniform-block *members* (Slang
 reports a constant buffer as one opaque binding, and the externs to walk into it
 are not declared in `lib/slang.c3l`), a `UNIFORM_BUFFER` usage bit on
 `Gpu.create_dynamic`, a descriptor pool sized for it, and a per-frame-slot ring
 so a buffer the GPU may still be reading is never overwritten. The push block
 costs none of them: reflection of push fields by name and byte offset is already
 built, already tested byte-for-byte, and already how `base_color` reaches the
 shader.

 What it refuses is a material with more uniforms than the block has room for —
 no long arrays, no matrices beyond a couple. `MATERIAL_UNIFORM_BUDGET` is where
 the conversation about widening it starts, and `MATERIAL_TABLE_BUDGET` is what
 already happened to the table half.

 ## A material is an index, and the default one is shared

 `Node.material` is a `uint` into `MeshPass.materials`, and every node starts on
 `DEFAULT_MATERIAL`. It has to be a shared index rather than a per-node value:
 a thousand instances stop being one draw call the moment two nodes drawing the
 same mesh disagree about their material, and handing every new node its own
 material id would keep every test's numbers green while quietly turning one draw
 call into a thousand.
*>
module three;

import std::collections::list;
import std::io;
import vk;

faultdef
	MATERIAL_UNKNOWN,
	MATERIAL_TEXTURE_UNKNOWN,
	// A name that is not one of this material's samplers. Separate from
	// `MATERIAL_TEXTURE_UNKNOWN`, which is about the *image*: one says the picture
	// is not there and the other says the shader has nowhere to put it, and the
	// two are fixed in different files.
	MATERIAL_SAMPLER_UNKNOWN,
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

 `FrontSide` is 0 there, `BackSide` 1 and `DoubleSide` 2. Matching the numbers
 rather than only the names means a script that hardcoded `side: 2` from memory
 of Three.js gets what it meant.
*>
const int SIDE_FRONT = 0;
const int SIDE_BACK = 1;
const int SIDE_DOUBLE = 2;

<*
 The cull mode a side means.

 `cullMode` is core Vulkan with no capability bit behind it, so this needs no
 query and has no fallback path.

 The inversion is the thing to read twice: `BackSide` means *keep the back
 faces*, so it culls the front ones. Getting it the other way round renders a
 skydome that is invisible from inside — the exact bug this exists to fix, so it
 would look like nothing had changed.

 Anything unrecognised is `FrontSide`. The JS side refuses an unknown value by
 name before it reaches here; this is the floor under that, not the check.
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
 for `SIDE_FRONT`'s reason. Three.js has `Subtractive` and `Multiply` at 3 and 4
 as well; they are not here, and leaving the numbers free lets them arrive later
 without renumbering anything a script may have hardcoded.

 The default is `NONE` and not `NORMAL`, which is the opposite of what "a
 material has an opacity" suggests. An opaque pipeline ignores the alpha it
 writes, so a material that never asked to blend renders exactly as every
 material did before this existed, whatever its opacity says. Three.js behaves
 the same way — `opacity` without `transparent` does nothing.
*>
const int BLENDING_NONE = 0;
const int BLENDING_NORMAL = 1;
const int BLENDING_ADDITIVE = 2;

<*
 The pipeline blend mode a `blending` number means.

 `cull_for_side`'s shape and its floor-not-check role: anything unrecognised is
 `NONE`, and the JS side refuses an unknown value *by name* before it reaches
 here. Two guards rather than one because they answer different questions — the
 boundary tells an agent what it typed wrong, and this makes sure a value that
 arrived any other way cannot select a pipeline nobody meant.
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
 every scene where nothing overlaps itself.
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

 A *material* rather than a flag on the mesh because a bucket is
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
 `draw` at 16+8, and `shaders/material.slang` declares those three fields first
 and in that order so `check_push_block` passes on a generated module exactly as
 it does on `mesh.slang`. The `$assert` is what makes this a derived number
 rather than a copied one, and it earned that twice: when `uv_transform` was
 added and this moved from 60 to 76, and when the whole mesh contract moved into
 `DrawRecord` and it fell to 24.
*>
const uint MATERIAL_PUSH_START = 24;

$assert MESH_PUSH_FIELDS[MESH_PUSH_FIELDS.len - 1].offset + MESH_PUSH_FIELDS[MESH_PUSH_FIELDS.len - 1].size == MATERIAL_PUSH_START :
	"the mesh push block moved; material uniforms no longer start where the template puts them";
$assert MATERIAL_PUSH_START + MATERIAL_UNIFORM_BUDGET == PUSH_BUDGET :
	"the material uniform budget and the push budget disagree";

// One `float4` — the width of an `animated` layer's tint-and-opacity uniform,
// which `Material.layer_params` reads out of the push block.
const uint LAYER_PARAMS_BYTES = 4 * (uint)float::size;

<*
 What `Material.table_pointer` holds when a material's uniforms fit the push
 block, which is almost every material.

 `uint::max` rather than zero, because zero is a real offset in a push block —
 the same hazard `NO_TEXTURE` is -1 for.
*>
const uint NO_TABLE_POINTER = uint::max;

<*
 One material: a pipeline to bind, and the bytes to push with it.

 `block` is laid out *as the push block itself* rather than as a list of values.
 Everything below `MATERIAL_PUSH_START` is overwritten per draw with the mesh's
 own push data; everything at or above it is the material's, written once when a
 uniform is set and memcpy'd straight out at record time. So setting a uniform
 costs a bounds check and a copy of at most 16 bytes, and drawing costs no
 per-uniform loop at all.

 `pipeline` is borrowed from `MeshPass.pipelines`, which hands out heap-boxed
 entries precisely so a live pointer survives the cache growing.

 ## Three fields are shaped around C3's zero fill

 A designated initializer leaves out what it does not name and C3 writes zero
 there, so every field here needs an answer to "what does a construction site
 that forgot me produce". There are three strategies in use, and which is right
 depends entirely on whether zero is a *legal value* of the field:

 - `texture` — zero is an ordinary texture index, so no encoding saves it.
   `NO_TEXTURE` is -1 and every construction site names the field, which makes
   forgetting possible on purpose: the mistake shows up as a wrong picture rather
   than being silently absorbed.
 - `uv_transform` — zero is a legal number but a meaningless *transform*, so the
   all-zero value is read as "unset" and the boundary refuses a script that tries
   to write one. Nobody has to remember anything.
 - `one_minus_opacity` — zero is both legal and meaningful (fully transparent),
   and the *common* case is the one that must be free. So the field stores the
   complement: zero fill spells opacity 1, and an opacity of exactly 0 is still
   representable rather than being stolen by a sentinel.

 The pattern: encode when zero is meaningful and the default is not zero; require
 naming when no encoding is honest.
*>
struct Material
{
	MeshPipeline* pipeline;
	// Which faces survive, as `material.side` chose them. Set at record time with
	// `vk::cmdSetCullMode` rather than baked into `pipeline`, so two materials
	// that differ only in their side share one `VkPipeline` and changing a side
	// builds nothing at all. `PipelineState` has the argument.
	vk::CullModeFlags cull;
	// The body the agent wrote, owned. Kept for `toJSON` and for the error message
	// when a uniform name does not resolve — "that material has no uniform called
	// X" is only actionable next to the source that declared them.
	String fragment;
	// The vertex body, owned, or an empty slice for a material that has none.
	// Kept for `toJSON` and for the same reason `fragment` is.
	String vertex;
	// How far this material's vertex body can move a vertex, in world units.
	//
	// A cull margin and nothing else. `build_draw_list` tests a mesh's own bounds
	// against the frustum, and those bounds describe the geometry as it was
	// uploaded — a body that pushes a vertex two metres out is drawing something
	// the box does not contain, so the draw is dropped while the displaced part is
	// still on screen. That reads as geometry vanishing at the edge of the view
	// and coming back when the camera turns.
	//
	// Zero for every material without a vertex body, which is exactly right for
	// them. Deliberately not derived: nothing can read a bound out of an arbitrary
	// shader body, and a conservative guess would either cost draw calls
	// everywhere or be wrong in the one case it mattered.
	float bounds;
	// `material.map` — an index into `Assets.textures`, or `NO_TEXTURE` for
	// "whatever the mesh brought". Holds one reference to that slot for as long as
	// it names it; `MeshPass.set_material_map` is the only thing that moves it, so
	// the retain and the release cannot get out of step.
	//
	// This must be set explicitly at every site that builds a `Material`. C3
	// zero-fills what a designated initializer leaves out, and zero is a perfectly
	// ordinary texture index — so a forgotten `.texture` does not render
	// untextured, it renders whatever the *first* image the table uploaded happens
	// to be. `NO_TEXTURE` is -1 rather than 0 so the mistake is possible to make;
	// a biased index-plus-one makes it impossible and makes every read arithmetic.
	int texture;
	// The samplers the body declared, at bindings 1..N. Binding 0 is `texture`
	// above and is not in here. See `TextureSlots`.
	TextureSlots textures;
	// `material.repeat` and `material.offset` — xy is how many times the texture
	// repeats across the surface, zw is where it starts.
	//
	// All zeros means unset, and is read as the identity. Zero would otherwise be
	// a repeat of zero, which collapses a whole surface onto one texel — a black
	// or single-colour shape, on a material nobody gave a transform to. Rather
	// than require every construction site to remember,
	// `uv_transform_or_identity` treats the zero value as "none", and a script
	// that writes a zero repeat is refused by name at the boundary.
	float[4] uv_transform;
	// Which blend mode the material's pipeline was built with — `material.blend`
	// and `material.transparent`, decided once, at construction.
	//
	// A copy of what `PipelineState.blend` already says, kept here because the two
	// readers cannot get at that: `Scene`'s draw ordering needs to know which
	// buckets are transparent without reaching into a `MeshPipeline`, and the
	// exporter needs it to write `alphaMode`.
	//
	// There is no setter, unlike `cull`. Blending is baked into the pipeline on
	// this device, so changing it would mean re-acquiring — a device, a target and
	// the assembled source read back out of the cache — to save a script one line.
	// Building a new material is that line.
	BlendMode blend;
	// `material.opacity`, stored as 1 - opacity so the zero fill is the common
	// case.
	//
	// A plain `opacity` field would make every forgotten initializer produce an
	// invisible material — geometry that does not render, on a material nobody
	// said anything about. A sentinel would have cost the one value a fade-out has
	// to reach.
	//
	// Never read directly outside `Material.opacity`.
	float one_minus_opacity;
	// `material.roughness`, stored as `1 - roughness` for the same reason opacity
	// is stored as its complement: C3 zero-fills what an initializer leaves out,
	// and a *zero* roughness is a mirror — every material nobody said anything
	// about would come out as one.
	//
	// Never read directly outside `Material.surface`.
	float one_minus_roughness;
	// `material.metalness` and `material.reflectance`, both 0 by default, so the
	// zero fill is already the right answer and neither needs inverting.
	//
	// ## Why reflectance is 0 rather than the 4% that real dielectrics reflect
	//
	// Because the standing constraint at the bottom of `plan.md` says a default is
	// invented when the answer stops depending on the scene, and this one has not:
	// every scene in this project was authored against a Lambert renderer, and
	// turning a 4% highlight on for all of them would relight all of them. So the
	// physical value is one line away — `material.reflectance = 0.5` — and off
	// until asked for, exactly as shadows are.
	//
	// The same argument is why the glTF importer does not apply the file's
	// `metallicFactor` and `roughnessFactor`, whose spec defaults are 1 and 1: a
	// file that says nothing is a fully metallic surface under those, and this
	// renderer has no environment for a metal to reflect. `GpuMaterial` carries
	// both so a script can read them and decide.
	float metalness;
	float reflectance;
	char[PUSH_BUDGET] block;
	// The uniform table, when it did not fit the block. Empty for every material
	// whose uniforms fit — almost all of them — and then nothing below this line
	// costs anything.
	//
	// A CPU shadow rather than the device buffer itself. `set_uniform` writes
	// here, and `MeshPass.prepare` copies it into that frame slot's table buffer
	// once per frame, which is what makes writing a uniform safe while frames are
	// in flight: the GPU may still be reading last frame's copy.
	//
	// Laid out as the shader lays the table out, so the copy is one memcpy with no
	// per-uniform loop, and every offset in it came from reflection.
	char[] table;
	// Where in the push block the pointer to that buffer goes — the reflected
	// offset of `material_table` — or `NO_TABLE_POINTER` for a material with no
	// table. Cached rather than looked up per draw: `record` binds a material per
	// bucket, and a name scan there would be a scan per bucket per frame.
	uint table_pointer;
	// Where this material's table sits inside the frame's shared table buffer.
	// Assigned by `MeshPass.prepare` every frame, because a material collected and
	// reused moves.
	uint table_offset;
	// Whether this slot holds a material at all. False for a slot whose material
	// was collected, which stays in the list so every index ever handed out keeps
	// meaning what it meant — and is handed to the next `create_material` rather
	// than growing the list forever.
	//
	// Never set at a construction site: `MeshPass.claim_slot` is the only thing
	// that makes a material live, so C3's zero-fill cannot produce a material that
	// is dead the moment it is built.
	bool alive;
	// Whether the script's handle has been given back — `material.dispose()`.
	//
	// Not the same as dead. A material is collected when this is true *and* no
	// node still names it, the rule `texture.dispose()` already follows: giving
	// back a handle is a statement about the handle, and a mesh that is still
	// drawing with the material is not wrong for doing so.
	bool released;
	// What a `three.LayeredMaterial` *is*, beside what it compiled to. Empty for
	// every other material, including a hand-written `ShaderMaterial`.
	ScriptLayers script_layers;
}

<*
 One layer of a stack a script described, as the host can still read it.

 `js/prelude/layers.js` turns a layer stack into a fragment body and a set of
 samplers, and that is all that would otherwise cross: `fragment` holds "the
 blend was a multiply" as Slang text, and no reader on this side can get it back
 out. Without this record, a scene built with `new three.LayeredMaterial(...)`
 exports as a flat material while the *same stack loaded from a `.glb`* exports
 intact, because `scene/export.c3` can read that one out of the source document.

 ## Bindings and offsets rather than values

 A layer's images are named by sampler binding, not by device slot, and its
 animated tint by push offset, not by number. Both are live:
 `mat.layers[1].map = moss` writes through `setMaterialTexture` into
 `Material.textures`, and an animated tint writes through `setUniform` into
 `Material.block`. Storing the values here would mean a second copy every setter
 had to remember to update, and the one that forgot would export the image the
 material used to have.

 Nothing here retains anything. Every image a layer names is either
 `Material.texture` or one of `Material.textures`, both of which the material
 already holds a reference to for its whole life — which is what makes a binding
 safe to keep and a device slot not.

 A disabled layer never arrives: `LayeredMaterial` drops `enabled: false` before
 it generates anything.
*>
struct ScriptLayer
{
	// Owned. Empty for a layer the script did not name.
	String name;
	float[3] tint;
	float[3] emissive_factor;
	float opacity;
	// Bindings in this material's own pipeline, or 0 for "the layer has none".
	// Zero can mean that because binding 0 is the template's own `base_color_map`
	// and is never a declared sampler — `TextureSlots.at` refuses it for the same
	// reason.
	uint map_binding;
	uint normal_binding;
	uint emissive_binding;
	// The layer's *own* mask. Zero for a layer reading a channel of the stack's
	// shared mask, which is the ordinary case and the economy the extension's
	// per-layer channel field exists for.
	uint mask_binding;
	// Push-block offset of the `float4` holding this layer's tint and opacity for
	// a layer that asked to be `animated`, or -1 for one whose tint and opacity
	// were baked into the shader as literals. `Material.layer_params` reads it.
	int params_offset;
	// `gltf::LayerBlendMode`, `LayerMaskChannel` and `LayerMaskSource` ordinals,
	// passed through untranslated: naming them on both sides would be two tables
	// to keep in step with the extension's enum.
	uint blend_mode;
	uint mask_channel;
	uint mask_source;
	bool invert;
}

<*
 A script's whole layer stack.

 `present` is false for every material that is not a `LayeredMaterial`, so this
 costs a bool and an empty list on the rest.
*>
struct ScriptLayers
{
	bool present;
	// The mask several layers read a channel of, as a binding. Zero when no two
	// layers shared one — the mirror of `GpuLayers.mask_texture`, which the
	// importer arrives at by hoisting and the generator by declaring one sampler
	// for the whole stack.
	uint mask_binding;
	// The *base* material's normal map, as a binding, or zero.
	//
	// Not a layer's — it is the one under all of them, and it is here rather than
	// on `Material` beside `texture` because a `LayeredMaterial` is the only thing
	// in this renderer that has one: the core materials have no normal map
	// property at all. `scene/export.c3` writes it as the glTF material's own
	// `normalTexture`.
	uint base_normal_binding;
	List{ScriptLayer} layers;
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
 every call site has to remember to undo.
*>
fn float Material.opacity(&self)
{
	return 1.0f - self.one_minus_opacity;
}

<*
 The three numbers the specular term reads, in `DrawRecord.surface`'s order.

 One accessor rather than three fields read directly, so the roughness complement
 is undone in exactly one place — `Material.opacity` is the same shape for the
 same reason.
*>
fn float[4] Material.surface(&self)
{
	return { 1.0f - self.one_minus_roughness, self.metalness, self.reflectance, 0 };
}

<*
 `Material.texture` for a material that has none of its own.

 The mesh's texture is what such a material draws with, which is what every
 material did before `map` existed and is why a glTF's own materials still work
 unchanged: the file's image rides on the `GpuMesh`.
*>
const int NO_TEXTURE = -1;

<*
 The textures sitting in one shader's own sampler bindings.

 A struct rather than a field on `Material` because a post pass has exactly the
 same thing — samplers above the ones its template reserves, filled by name,
 bound every draw — and the bias below is not something two files should each
 know about.

 ## Indexed by the binding itself

 An array subscripted by `binding - <first>` is exact only while both kinds of
 shader reserve the same number of bindings, and they no longer do. Carrying the
 base into the accessors was the other option and is worse: it would have to be
 passed correctly at every call site, and a call site passing a material's base
 for a post pass would read a real texture out of the wrong slot rather than
 fault. Indexing by the absolute binding cannot be got wrong — a binding is the
 same number to everybody — at a cost of `MAX_SAMPLED_BINDINGS` ints per material
 instead of one.

 ## What is stored is the index plus one

 Zero is an ordinary texture index, and this is an *array*: requiring every
 construction site to spell it out, the way `Material.texture` is spelled out,
 would mean four entries at each of them, and the site that wrote three would
 bind whatever image the table uploaded first to the fourth. So this takes the
 third of `Material`'s three strategies — encode when zero is meaningful and the
 default is not zero. The zero fill means "nothing here", a real index `n` is
 stored as `n + 1`, and the arithmetic lives only in the two accessors below.
*>
struct TextureSlots
{
	int[MAX_SAMPLED_BINDINGS] stored;
}

<*
 Which texture is in one binding.

 The only reader of the bias, so nothing above this has to remember it was there.

 A binding outside the range answers `NO_TEXTURE` rather than faulting, which is
 the call `Assets.texture_at` makes about an unknown index and for the same
 reason: the caller is `record`, the answer picks an image, and white is a
 picture that is visibly wrong rather than a draw that does not happen.

 Binding 0 is refused in both kinds, which is what lets `sampler_binding_of`
 answer 0 for "no such sampler": it is the template's own in a material
 (`base_color_map`) and in a post pass (`prev`), reached through `material.map`
 and through the chain respectively, and never by name.

 @param binding : `The shader's own binding index, from its kind's first agent binding up.`
 @return `An index into Assets.textures, or NO_TEXTURE for a binding nothing was put in.`
*>
fn int TextureSlots.at(&self, uint binding)
{
	if (binding == 0 || binding >= MAX_SAMPLED_BINDINGS) return NO_TEXTURE;
	int stored = self.stored[binding];
	return stored == 0 ? NO_TEXTURE : stored - 1;
}

<*
 Puts a texture in one binding.

 The only writer of the bias. It takes no references and gives none back —
 retaining the new index and releasing the old one belongs to whoever has the
 `Assets` and a device to wait on, which is `MeshPass.set_material_texture` for a
 material and `PostPass.hold_textures` for a post pass. Writing through here
 directly leaks a reference.

 @param binding : `The shader's own binding index. Out of range is ignored.`
 @param texture : `An index into Assets.textures, or NO_TEXTURE to empty the binding.`
*>
fn void TextureSlots.set(&self, uint binding, int texture)
{
	if (binding == 0 || binding >= MAX_SAMPLED_BINDINGS) return;
	self.stored[binding] = texture == NO_TEXTURE ? 0 : texture + 1;
}

<*
 Which binding a sampler name means, through this material's own pipeline.

 One line, because the resolution itself is `sampler_binding_of` in
 `render/bind.c3` — shared with the post pass, which asks the identical question
 of a pipeline that is not a material's. Zero means no.
*>
fn uint Material.binding_of_texture(&self, String name)
	=> sampler_binding_of(self.pipeline, name, MATERIAL_BINDING_FIRST);

<*
 Points a uniform at new values.

 The name is resolved through the pipeline's *reflected* push fields rather than
 through anything this side remembers, which makes the offsets right by
 construction. A name below `MATERIAL_PUSH_START` resolves — it is a real field —
 and is refused anyway, because writing `base_color` or `positions` through this
 door would corrupt a BDA pointer and crash in the driver rather than here.

 ## One row at a time, because a table is a column of them

 A uniform declared with rows is `float3 tint[4]` in the shader — one column of
 the material's table, selected per instance by `Surface.variant`. It is written
 a row at a time, so the caller needs no view of the whole column and
 `material.uniforms.tint[2] = [1, 0, 0]` is one crossing.

 The shape is stated rather than inferred, which is what keeps the width check
 exact: `field.size` alone cannot tell a `float4` from two `float2`s, so asking
 the caller for both numbers and requiring `width * rows` to be the reflected
 size refuses a caller that has the shape wrong instead of silently writing half
 a row.

 @param values : `One to four floats. Must match the width the shader declared.`
 @param row : `Which row of the column, 0 for a plain uniform.`
 @param rows : `How many rows the caller believes the column has. 1 for a plain uniform.`
 @return? MATERIAL_UNIFORM_UNKNOWN : `No uniform of that name in this material.`
 @return? MATERIAL_UNIFORM_WIDTH : `The shader declared a different number of components, a different number of rows, or the row is past the end.`
*>
fn void? Material.set_uniform(&self, String name, float[] values, uint row = 0, uint rows = 1)
{
	ShaderField* field = self.pipeline.shader.field_of(name);
	// The `MATERIAL_PUSH_START` cut only applies to the block. A table field's
	// offset is inside the table buffer, where zero is a real offset and the mesh
	// contract does not exist.
	if (field == null) return MATERIAL_UNIFORM_UNKNOWN~;
	if (!field.indirect && field.offset < MATERIAL_PUSH_START) return MATERIAL_UNIFORM_UNKNOWN~;

	uint width = (uint)(values.len * float::size);
	if (width == 0 || rows == 0 || row >= rows) return MATERIAL_UNIFORM_WIDTH~;
	if (field.size != width * rows) return MATERIAL_UNIFORM_WIDTH~;

	uint at = field.offset + row * width;
	if (field.indirect)
	{
		if ((sz)(at + width) > self.table.len) return MATERIAL_UNIFORM_WIDTH~;
		mem::copy(&self.table[at], values.ptr, width);
		return;
	}
	if (at + width > PUSH_BUDGET) return MATERIAL_UNIFORM_WIDTH~;

	mem::copy(&self.block[at], values.ptr, width);
}

<*
 Every uniform this material declared, in the order the shader laid them out.

 Reads the reflected push fields and drops the mesh contract's, the same cut
 `set_uniform` makes. Used by the JS side to build the accessors on
 `material.uniforms` — the prelude cannot enumerate them any other way, because
 the QuickJS shim has no property enumeration at all.
*>
fn void Material.uniform_fields(&self, List{ShaderField}* out)
{
	foreach (field : self.pipeline.shader.push_fields)
	{
		// A table field is a uniform a script sets by name exactly as a pushed one
		// is; the pointer it hangs off is not, and is the one generated name that
		// has to be kept out of `material.uniforms`.
		if (field.indirect)
		{
			out.push(field);
			continue;
		}
		if (field.name == MATERIAL_TABLE_FIELD) continue;
		if (field.offset >= MATERIAL_PUSH_START) out.push(field);
	}
}

<*
 Gives this material somewhere to keep a uniform table, if its shader has one.

 Called once, wherever a material is built, and idempotent. Two things come out
 of the reflected layout and neither can be derived from the uniform list on this
 side — the pointer's offset in the push block, and how large the table is —
 because both are Slang's answers rather than ours.

 A material whose uniforms fit the push block gets `NO_TABLE_POINTER`, an empty
 table and no allocation.
*>
fn void Material.bind_table(&self)
{
	self.table_pointer = NO_TABLE_POINTER;
	uint size = 0;
	foreach (field : self.pipeline.shader.push_fields)
	{
		if (field.indirect)
		{
			uint end = field.offset + field.size;
			if (end > size) size = end;
			continue;
		}
		if (field.name == MATERIAL_TABLE_FIELD) self.table_pointer = field.offset;
	}

	if (self.table.len > 0) mem::free(self.table);
	self.table = {};
	if (size == 0) return;
	// Zero-filled, exactly as `block` is: a uniform nobody set reads zero, and
	// that is the same promise on both sides of the spill.
	self.table = mem::new_array(char, (sz)size);
}

<*
 Starts a script's layer stack, discarding whatever it had.

 Called by `setMaterialLayers`, once, before the layers themselves — the shape
 `add_material_layers`/`add_layer` has on the writing side.

 @param mask_binding : `The sampler several layers read a channel of, or 0 for a stack where no two share one.`
 @param base_normal_binding : `The base material's normal map, or 0. Written as the glTF material's own normalTexture rather than as any layer's.`
*>
fn void Material.begin_script_layers(&self, uint mask_binding, uint base_normal_binding = 0)
{
	self.free_script_layers();
	self.script_layers.present = true;
	self.script_layers.mask_binding = mask_binding;
	self.script_layers.base_normal_binding = base_normal_binding;
	self.script_layers.layers.init(mem, 4);
}

<*
 Appends one layer. `layer.name` is copied.
*>
fn void Material.add_script_layer(&self, ScriptLayer layer)
{
	if (!self.script_layers.present) return;
	ScriptLayer copy = layer;
	copy.name = layer.name.copy(mem);
	self.script_layers.layers.push(copy);
}

fn void Material.free_script_layers(&self)
{
	if (!self.script_layers.present) return;
	foreach (layer : self.script_layers.layers) layer.name.free(mem);
	self.script_layers.layers.free();
	self.script_layers = { };
}

<*
 A layer's tint and opacity, as they are *now*.

 The literal ones the generator baked in for a plain layer, and the live contents
 of the push block for one that asked to be `animated` — `ScriptLayer` says why
 the second is read here rather than remembered when it was set.

 @return `[r, g, b, opacity].`
*>
fn float[4] Material.layer_params(&self, ScriptLayer* layer)
{
	float[4] baked = { layer.tint[0], layer.tint[1], layer.tint[2], layer.opacity };
	if (layer.params_offset < 0) return baked;

	uint at = (uint)layer.params_offset;
	if (at + LAYER_PARAMS_BYTES > PUSH_BUDGET) return baked;

	float[4] live;
	mem::copy(&live, &self.block[at], LAYER_PARAMS_BYTES);
	return live;
}

<*
 Where a uniform's bytes sit in the push block, or -1.

 The read half of the resolution `set_uniform` does on every write, split out
 because a layer resolves its `animated` float4 once at construction and reads it
 many times afterwards. The same two refusals apply.
*>
fn int Material.uniform_offset(&self, String name)
{
	ShaderField* field = self.pipeline.shader.field_of(name);
	if (field == null || field.offset < MATERIAL_PUSH_START) return -1;
	if (field.size != LAYER_PARAMS_BYTES) return -1;
	return (int)field.offset;
}

fn void Material.free(&self)
{
	if (self.fragment.len > 0) self.fragment.free(mem);
	if (self.vertex.len > 0) self.vertex.free(mem);
	if (self.table.len > 0) mem::free(self.table);
	self.table = {};
	self.free_script_layers();
	*self = { };
	// Not left at the zero fill. Zero is a perfectly ordinary texture index, and a
	// collected slot that read as naming texture 0 would have that slot released a
	// second time by `MeshPass.free`'s sweep at teardown.
	self.texture = NO_TEXTURE;
}
