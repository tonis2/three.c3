<*
 The mesh pipeline: one pipeline, one descriptor layout, one push block — and
 none of the three declared by hand.

 The permutation explosion a material system usually brings is avoided by one
 trick: the texture binding is *always* present and carries a 1x1 opaque white
 image when the material has none, so an untextured mesh and a textured one are
 the same pipeline.

 ## The push block

 Mirrors `shaders/mesh.slang` exactly:

 frame        0     8      -> FrameBlock, one per frame in flight
 instances    8     8      -> Instance[], already offset to this bucket
 draw        16     8      -> DrawRecord*, this bucket's own = 24 bytes

 That table is `MESH_PUSH_FIELDS` below, and it is checked against the shader on
 every pipeline build. As a comment it would be exactly as good as a `slangc`
 line in a manifest. Slang reflects the real offsets out of the module that is
 about to run, so a field added to one side and not the other is a sentence at
 startup instead of geometry read at the wrong address.

 128 bytes is the budget and it is not a coincidence — it is the push constant
 size every Vulkan implementation is required to offer, so this pass can never be
 refused by a device. When something new wants to ride in here, it goes in a
 buffer instead.

 That rule has been obeyed twice. First, the old block spent 64 of its 128 bytes
 on a per-draw `mvp`, which left no room for the instance-array pointer
 instancing needs — so the view-projection and the lighting moved into a
 `FrameBlock` written once a frame and reached through one pointer. That is also
 what makes a *list* of lights free: four more of them is 128 bytes of a buffer
 rather than 128 bytes of a budget every material is competing for.

 Second, `DrawRecord`. The mesh contract had grown to 76 bytes across eight
 fields, every one per-draw and none able to move to a per-*frame* block, which
 left material uniforms 52 bytes and made every future vertex stream an argument
 about who pays for it. So the whole contract moved into a buffer and the push
 block carries its address: what is pushed is 24 bytes that never grow again, and
 what a stream costs is 8 bytes of a buffer sized by the frame's bucket count.

 ## The descriptor set layout is derived

 `shader/reflect.c3` reads the bindings out of the compiled module and this file
 hands them to `vkCreateDescriptorSetLayout` unchanged. Nothing here names
 `base_color_map` or knows it is a combined image sampler, which is what makes an
 agent-written `ShaderMaterial` possible: a shader that declares a different
 binding gets a layout for the binding it declared.
*>
module three;

import std::io;
import std::math;
import std::math::matrix;
import std::collections::list;
import vk;
import slang;

faultdef
	NO_SCALAR_BLOCK_LAYOUT,
	PUSH_BLOCK_TOO_LARGE,
	PUSH_BLOCK_MISMATCH,
	SHADER_BINDING_UNSUPPORTED,
	SHADER_TOO_MANY_SETS,
	SHADER_MISSING_ENTRY_POINT;

const uint FLAG_HAS_NORMALS = 1;
const uint FLAG_HAS_UVS     = 2;
const uint FLAG_HAS_COLORS  = 4;
// The bucket carries joints and weights, and the vertex shader poses it.
const uint FLAG_HAS_SKIN    = 8;
// The compute pass posed it before the render pass began, so the vertex shader
// reads `DrawRecord.posed` and blends nothing. Set by `render/pass.c3`, and never
// together with `FLAG_HAS_SKIN` — the two are the two skinning paths, not two
// halves of one.
const uint FLAG_PRESKINNED  = 16;

<*
 `Instance.pose` is an offset in matrices with a selector in its top bit.

 Set means this frame's live palette — a character posed from its bone nodes, so
 a script can drive a look-at or an IK chain. Clear means the asset's baked table,
 which is every character that is just playing a clip.

 One bit rather than a second field or a second bucket. A palette pointer per
 bucket would force a live character and a baked one that share a mesh and a
 material into two draw calls — and the whole reason the pose is a buffer is that
 they should not be.
*>
const uint POSE_LIVE = 0x80000000;
const uint POSE_MASK = 0x7fffffff;

// The size every implementation must offer. Treated as a budget, not a limit to
// grow into.
const uint PUSH_BUDGET = 128;

// The entry points `mesh.slang` is required to contain, and the stages they are
// compiled for. Named rather than discovered — see `compile_slang`.
const ShaderEntry[*] MESH_ENTRIES = {
	{ "vertexMain", slang::STAGE_VERTEX },
	{ "fragmentMain", slang::STAGE_FRAGMENT },
};

// `shaders/skin.slang`'s one entry point. A compute module has no fragment stage
// and no attachment formats, which is most of why it gets its own pipeline type
// rather than a flag on the mesh one.
const ShaderEntry[*] SKIN_ENTRIES = {
	{ "computeMain", slang::STAGE_COMPUTE },
};

<*
 `shaders/shadow.slang`'s one entry point.

 One, and a vertex one. A depth-only pipeline needs no fragment stage — there is
 nothing to write but the depth the rasteriser already produced — so this list
 has a single element and `MeshPipeline.init_shadow` builds a pipeline with one
 `VkPipelineShaderStageCreateInfo`. That is also why the entry list is a
 parameter of `build_layouts` rather than a constant inside it: `MESH_ENTRIES`
 would fail this module for missing a `fragmentMain` it is right not to have.
*>
const ShaderEntry[*] SHADOW_ENTRIES = {
	{ "vertexMain", slang::STAGE_VERTEX },
};

// The workgroup size `skin.slang` declares. Here so the dispatch and the shader
// cannot drift: one thread per (instance, vertex), rounded up to whole groups,
// and the shader drops the tail itself.
const uint SKIN_WORKGROUP = 64;

<*
 How many lights the frame block carries, and so how many a script may have.

 Four because the fifth is `plan.md` §19's trigger for clustered forward: a loop
 this short costs less than the compute pass that would bin it, and the number
 that makes that stop being true is the one the plan already names. The shaders
 spell it as a literal in their `FrameBlock` declarations, because those are a
 wire format and `FrameBlock::size` is what holds the two together.
*>
const uint MAX_LIGHTS = 4;

<*
 One light, as the three shading shaders declare it.

 **Light zero is the sun.** `render/shadow.c3` fits the shadow map around it and
 it is the only one that casts; the rest light and do not shadow. A second caster
 is a second fit and a second depth pass — `plan.md` §19's atlas is what turns
 that into a tiling question rather than an allocation one.
*>
struct Light
{
	// xyz surface-to-light in world space, w unused. Not normalized: the shaders
	// normalize on read, so a script's magnitude has never meant anything, and
	// normalizing at the door would answer `three.light.direction` with numbers
	// nobody wrote.
	float[4] direction;
	// rgb the light's colour, linear. w its intensity, which the shader multiplies
	// in — so a colour stays a colour a picker can produce and a light can still be
	// brighter than white.
	float[4] color;
}

<*
 What every draw in a frame shares. One per frame in flight, written before
 recording and read through `MeshPush.frame`.
*>
struct FrameBlock
{
	Matrix4f view_projection;
	// x the ambient floor, y how many of `lights` are lit this frame,
	// z game clock seconds (`s.time` / `v.time`), w unused.
	float[4] lighting;
	// This frame's live joint matrices — `MeshPass.write_live_poses`. Zero in a
	// frame with no live character.
	// 
	// Here rather than in the draw record, and that is the field's whole argument:
	// the record is per bucket, and a single palette pointer there would split a
	// live character away from the baked copies it shares a mesh and a material
	// with. One buffer per frame keeps them in one draw.
	ulong live_poses; // Matrix4f*
	<*
	 The light's own view-projection, as `render/shadow.c3` fitted it this frame.

	 Identity in a frame with no shadow pass, and unread in one — `shadow[3]` is
	 what says which. Written here rather than pushed because both ends need it and
	 they are different pipelines: `shaders/shadow.slang` rasterises the map with
	 it and both shading shaders read the map back with it, so one fit reaching one
	 buffer is what keeps the two from disagreeing.
	*>
	Matrix4f light_view_projection;
	<*
	 x texel size in uv, y depth bias in ndc, z normal offset in world units,
	 w intensity — and w is zero when no shadow pass ran this frame.

	 One number for "off" and for "as dark as the shadows are" because the shader
	 cannot tell the two apart and should not have to: an intensity of zero and a
	 white 1x1 map are both "nothing is occluded".
	*>
	float[4] shadow;
	<*
	 The debug view, as `three.debug.view` set it. x is the mode — 0 draws the
	 scene, 1 the shadow factor, 2 what the shadow lookup would read — and yzw are
	 room for a view that needs an argument.

	 A whole float4 for one number, because the block is already aligned to one: a
	 scalar here costs the same sixteen bytes and would have to be repacked the
	 first time a second view wanted a parameter.
	*>
	float[4] debug;
	<*
	 Where the camera is, in world space, with w unused.

	 Read by the specular term and by nothing else — a highlight is the one thing
	 in a shading body that depends on which way the surface is being looked at,
	 and inverting `view_projection` per fragment to recover it would be work for a
	 value the CPU already has.
	*>
	float[4] camera;
	<*
	 The sky, as the surfaces that reflect it need it.

	 x  intensity, and **zero means there is no environment** — the one number
	 the shading branches on, so a scene with no sky and a scene whose sky
	 is turned all the way down are the same frame.
	 y  rotation about world Y in radians, the same angle `shaders/sky.slang`
	 turns the background by. One number in one place, or a metal would
	 reflect a sky pointing somewhere else than the one on screen.
	 z  the highest mip level of the environment image, which is what turns
	 `roughness` into a blur.
	 w  unused.

	 Beside `camera` rather than folded into its spare `w`, for the reason the
	 debug view is a whole `float4`: the block is aligned to sixteen bytes
	 already, so this costs nothing a scalar would not, and packing two unrelated
	 things into one vector is how the second one ends up in the wrong shader.
	*>
	float[4] environment;
	<*
	 The frame's lights, `lighting[1]` of them, light zero first. The rest of the
	 array is whatever was there last frame and no loop reaches it.

	 **At the end of the block deliberately.** Every field above kept the offset it
	 had when there was one light, and `shaders/shadow.slang` reads
	 `light_view_projection` at 88 by that offset rather than by name.
	*>
	Light[MAX_LIGHTS] lights;
	<*
	 This frame's morph weights — `MeshPass.write_morph_weights`. Zero in a frame
	 where nothing morphs, which is almost every frame of almost every project.

	 Here rather than in the draw record for `live_poses`' reason exactly: the
	 record is per bucket, and a weight pointer there would split a morphing copy
	 of a mesh away from the copies of it that are not morphing. One buffer per
	 frame keeps them in one draw.

	 **After `lights` rather than beside `live_poses`**, which is the rule the
	 comment above states: every field keeps the offset it had, so
	 `shaders/shadow.slang` goes on reading `light_view_projection` at 88 by that
	 offset and nothing had to be recompiled to agree.
	*>
	ulong morph_weights; // float*
}

<*
 One vertex as the compute pass leaves it: posed, in the character's own space.

 Interleaved, unlike the geometry streams, because one thread writes both halves
 and one thread reads them — see `shaders/mesh.slang`'s copy of this.
*>
struct SkinnedVertex
{
	Vec3 position;
	Vec3 normal;
}

<*
 One vertex's displacement for one morph target, as `shaders/mesh.slang` declares
 it.

 **Displacements and not positions**, which is what glTF stores and the only form
 that composes: a face with a smile target and a blink target has to be able to do
 both at once, and adding two absolute positions is not a face.

 Interleaved for `SkinnedVertex`'s reason and the same 24 bytes: one lane reads
 both halves. A target with no NORMAL accessor gets zeroes here rather than a
 second flag — the sum is a displacement either way, and adding zero is cheaper
 than branching per target per vertex.
*>
struct MorphDelta
{
	Vec3 position;
	Vec3 normal;
}

<*
 One bucket's geometry and surface, as `shaders/mesh.slang`'s `Draw` declares it.

 Written per bucket per frame into a host-visible buffer, which is the difference
 between this and everything above it: `FrameBlock` is one per frame and
 `Instance` is one per copy, and this is one per *draw*. `MeshPass.record` fills
 it as it walks the buckets and pushes the address of the one it just filled.

 Scalar layout, so it packs the way the C3 struct does — 8-byte pointers, then
 two float4s at 4-byte alignment, then the flags:

 positions       0     8
 normals         8     8
 uvs            16     8
 colors         24     8
 joints         32     8
 weights        40     8
 palette        48     8
 posed          56     8
 morph          64     8
 base_color     72    16
 flags          88     4
 skin_stride    92     4
 morph_targets  96     4
 uv_transform  100    16
 surface       116    16    = 132, and four bytes of tail padding to the
 struct's own eight-byte alignment

 The stride between records is this struct's size, decided on the C3 side alone:
 the shader is handed a pointer to one record and never indexes past it, so
 Slang's own array stride for `Draw` is not part of the wire format the way the
 field offsets are.
*>
struct DrawRecord
{
	ulong positions;
	ulong normals;
	ulong uvs;
	// glTF's COLOR_0, read only by a material body — see `shaders/mesh.slang`. The
	// first field added since the record replaced the push block, and the whole of
	// what it cost is this line and 8 bytes per bucket per frame.
	ulong colors;
	// glTF's JOINTS_0 and WEIGHTS_0, and the asset's baked joint matrices — the
	// three fields this record exists to make possible. They cost 24 bytes of a
	// buffer sized by the frame's bucket count, and nothing at all from the 128 the
	// material uniforms are still spending.
	ulong joints;
	ulong weights;
	ulong palette;
	// Where the compute pass wrote this bucket's posed vertices, or zero.
	// `SkinnedVertex*`, one copy of the mesh per instance.
	ulong posed;
	// This mesh's morph target displacements, or zero — `morph_targets` blocks of
	// `vertex_count` each. Per bucket because the geometry is: which targets exist
	// is a property of the mesh, and how much of each is applied is a property of
	// the copy and lives on the instance.
	ulong morph;
	float[4] base_color; // rgb albedo factor, a material alpha
	uint flags;
	// The mesh's vertex count, and the stride two readers need: between one
	// instance's posed copy and the next under `FLAG_PRESKINNED`, and between one
	// morph target's block of displacements and the next under `morph_targets`.
	// Zero when neither is running.
	uint skin_stride;
	// How many blocks `morph` holds, and so how many weights this bucket's
	// instances index. Zero on every mesh without targets, which is the shader's
	// whole test for whether to run the loop at all.
	uint morph_targets;
	// xy repeat, zw offset — `material.repeat` and `material.offset`, applied to
	// the uv before the sample. Added when it turned out that a surface mapping its
	// texture exactly once makes texel density a function of how big the mesh is:
	// `examples/village` covered its ground with 484 separate plane meshes purely
	// so one 128px grass texture would not stretch across 132 units.
	float[4] uv_transform;
	// x roughness, y metalness, z reflectance, w unused — `material.roughness`,
	// `.metalness` and `.reflectance`, which is everything the specular term reads
	// off a material.
	// 
	// Here rather than in a material's uniforms for `uv_transform`'s reason: only a
	// ShaderMaterial has uniforms, and the surface most likely to want a highlight
	// is a `MeshLambertMaterial` on a floor.
	float[4] surface;
}

struct MeshPush
{
	ulong frame; // FrameBlock*
	ulong instances; // Instance*, offset to this bucket's first
	ulong draw; // DrawRecord*, this bucket's own
}

<*
 What one compute-skinning dispatch is handed, as `shaders/skin.slang`'s
 `SkinPush` declares it.

 Its own 128 bytes. A compute pass has no material and no uniforms appended to
 the tail, so this can be eleven fields where the draw path had to move its
 geometry contract into a buffer to make room.
*>
struct SkinPush
{
	ulong positions;
	ulong normals;
	ulong joints;
	ulong weights;
	ulong instances; // Instance*, offset to this bucket's first
	ulong baked; // Matrix4f*, the asset's table
	ulong live; // Matrix4f*, this frame's live palette
	ulong output; // SkinnedVertex*, this bucket's slice
	// The same pair the draw path carries, for the same reason: a character routed
	// through the compute pass has to morph exactly as one left in the vertex
	// shader does, or turning `skinning: 'compute'` on changes how it looks.
	ulong morph; // MorphDelta*, or zero
	ulong morph_weights; // float*, this frame's, or zero
	uint vertex_count;
	uint instance_count;
	uint flags;
	uint morph_targets;
}

$assert SkinPush::size <= PUSH_BUDGET : "the skinning push block outgrew the 128 bytes every device must offer";

const PushFieldLayout[*] SKIN_PUSH_FIELDS = {
	{ "positions", 0, 8 },
	{ "normals", 8, 8 },
	{ "joints", 16, 8 },
	{ "weights", 24, 8 },
	{ "instances", 32, 8 },
	{ "baked", 40, 8 },
	{ "live", 48, 8 },
	{ "output", 56, 8 },
	{ "morph", 64, 8 },
	{ "morph_weights", 72, 8 },
	{ "vertex_count", 80, 4 },
	{ "instance_count", 84, 4 },
	{ "flags", 88, 4 },
	{ "morph_targets", 92, 4 },
};

$assert MeshPush::size <= PUSH_BUDGET : "the mesh push block outgrew the 128 bytes every device must offer";

// The C3 structs against their tables, at compile time. `check_push_block` holds
// the *shader* to these; `@layout_matches` holds this side to them, so neither
// declaration is the definition of the other and a field added to one alone does
// not build. `POST_PUSH_FIELDS` has no counterpart here — a post pass pushes no
// struct this file declares.
$assert @layout_matches(MeshPush, MESH_PUSH_FIELDS) : "MeshPush no longer lays out the way MESH_PUSH_FIELDS says";
$assert @layout_matches(SkinPush, SKIN_PUSH_FIELDS) : "SkinPush no longer lays out the way SKIN_PUSH_FIELDS says";
$assert @layout_matches(
	DrawRecord,
	DRAW_RECORD_FIELDS
) : "DrawRecord no longer lays out the way DRAW_RECORD_FIELDS says";
$assert @layout_matches(
	FrameBlock,
	FRAME_BLOCK_FIELDS
) : "FrameBlock no longer lays out the way FRAME_BLOCK_FIELDS says";
// Not a bound but an equality, because these numbers are a wire format shared
// with `shaders/mesh.slang` and a silent change to either side is a misread
// buffer rather than an error. `Instance` is in `scene/scene.c3`.
$assert MeshPush::size == 24 : "the push block no longer matches the layout documented above";
$assert DrawRecord::size == 136 : "DrawRecord no longer matches shaders/mesh.slang's Draw";
$assert FrameBlock::size == 352 : "FrameBlock no longer matches shaders/mesh.slang";
$assert Light::size == 32 : "Light no longer matches shaders/mesh.slang";
$assert Instance::size == 164 : "Instance no longer matches shaders/mesh.slang";
$assert SkinnedVertex::size == 24 : "SkinnedVertex no longer matches shaders/skin.slang";
$assert MorphDelta::size == 24 : "MorphDelta no longer matches shaders/mesh.slang";

<*
 One field of the push block as this side lays it out.

 The `$assert`s above check the C3 struct against itself; this checks it against
 the *shader*, through reflection.
*>
struct PushFieldLayout
{
	String name;
	uint offset;
	uint size;
}

<*
 Does this C3 struct lay out exactly the way this table says it does?

 `Type::members` reports each member's name, offset and size at compile time, so
 the C3 side of a wire format is a `$assert` and not a test — strictly better
 than a check that has to be run: a struct that stopped matching its table no
 longer builds, and it names the field.

 Order matters and is part of the claim. The table is walked against the members
 in declaration order, so a field moved rather than resized still fails.

 @param $Type : `The struct — DrawRecord, FrameBlock, MeshPush, SkinPush.`
 @param $fields : `The table it must match, in declaration order.`
*>
macro bool @layout_matches($Type, $fields)
{
	$if $Type::members.len != $fields.len:
		return false;
	$endif
	$foreach $i, $m : $Type::members:
		$if $m.name != $fields[$i].name ||| $m.offset != $fields[$i].offset ||| $m.size != $fields[$i].size:
			return false;
		$endif
	$endforeach
	return true;
}

const PushFieldLayout[*] MESH_PUSH_FIELDS = {
	{ "frame", 0, 8 },
	{ "instances", 8, 8 },
	{ "draw", 16, 8 },
};

<*
 The frame block's own contract, in the same terms and for the same reason as
 `DRAW_RECORD_FIELDS`.

 `FrameBlock` is reached through a pointer, so Slang does not reflect it and
 nothing compares it against the C3 struct — survivable while `mesh.slang` and
 `material.slang` were the only two files declaring it and both were edited
 together. `shaders/shadow.slang` is a third, it reads `light_view_projection` at
 offset 88, and a field inserted above that in two files out of three is a shadow
 map rendered with whatever sixteen floats happen to sit there.

 `the_frame_block_matches_the_shader` closes it the way the draw record's check
 does: the declaration is cut out of `shaders/mesh.slang` and compiled *as* a
 push block, which is a layout Slang will report.

 view_projection          0    64
 lighting                64    16
 live_poses              80     8
 light_view_projection   88    64
 shadow                 152    16
 debug                  168    16
 camera                 184    16
 environment            200    16
 lights                 216   128    = 344, and no tail padding
*>
const PushFieldLayout[*] FRAME_BLOCK_FIELDS = {
	{ "view_projection", 0, 64 },
	{ "lighting", 64, 16 },
	{ "live_poses", 80, 8 },
	{ "light_view_projection", 88, 64 },
	{ "shadow", 152, 16 },
	{ "debug", 168, 16 },
	{ "camera", 184, 16 },
	{ "environment", 200, 16 },
	{ "lights", 216, 128 },
	{ "morph_weights", 344, 8 },
};

<*
 The draw record's own contract, in the same terms and for the same reason.

 Slang reflects a push block and does not reflect the type behind a pointer, so
 without this nothing would compare `Draw` against `DrawRecord` and a field added
 to one and not the other would be geometry read at the wrong address.

 `the_draw_record_matches_the_shader` closes that by cutting the `struct Draw`
 declaration out of `shaders/mesh.slang` and compiling it *as* a push block,
 which is a layout Slang will reflect. Both are scalar-layout structs under
 `-force-glsl-scalar-layout`, so what comes back is what the record has.

 The C3 half is the `$assert` below, not part of that test — so the two sides are
 checked independently, and the side that can be checked without running anything
 is.
*>
const PushFieldLayout[*] DRAW_RECORD_FIELDS = {
	{ "positions", 0, 8 },
	{ "normals", 8, 8 },
	{ "uvs", 16, 8 },
	{ "colors", 24, 8 },
	{ "joints", 32, 8 },
	{ "weights", 40, 8 },
	{ "palette", 48, 8 },
	{ "posed", 56, 8 },
	{ "morph", 64, 8 },
	{ "base_color", 72, 16 },
	{ "flags", 88, 4 },
	{ "skin_stride", 92, 4 },
	{ "morph_targets", 96, 4 },
	{ "uv_transform", 100, 16 },
	{ "surface", 116, 16 },
};

<*
 The whole of the post pass's push contract: one `float4` and nothing else.

 `shaders/post.slang` declares `info` first — xy the target's extent, z seconds
 since the shader was set, w reserved — then `planes`, the camera's near and far,
 and the agent's uniforms after those. So `POST_PUSH_START` is 24 and the budget
 is the other 104.

 It shares nothing with `MESH_PUSH_FIELDS` and that is deliberate: a post pass
 has no geometry, no instances and no frame block, so a contract requiring
 `positions` would be requiring a pointer nothing could supply. Which list a
 pipeline is checked against is the argument `check_push_block` takes, rather
 than a second copy of the check.
*>
const PushFieldLayout[*] POST_PUSH_FIELDS = {
	{ "info", 0, 16 },
	{ "planes", 16, 8 },
};

<*
 How a material's colour reaches the attachment: not at all, over what is there,
 or added to it.

 A field rather than a command, and that was measured rather than assumed.
 KosmicKrisp on this machine advertises `VK_EXT_extended_dynamic_state3` and
 reports every one of its colour-blend feature bits false — `ColorBlendEnable`,
 `ColorBlendEquation` and `ColorWriteMask` all zero — because Metal carries
 blending inside `MTLRenderPipelineColorAttachmentDescriptor`, in the compiled
 pipeline state, with no encoder command that can change it mid-pass. So
 `vkCmdSetColorBlendEnableEXT` is unusable here and a blend mode has to be baked
 in.

 That is the exact inverse of the topology case, where the bit says no and the
 driver honours the switch anyway — which is why neither direction is worth
 guessing at.

 The cost is small and bounded, unlike the cull mode's: this is a closed set of
 three values shared by every material that asks for one, so it is a handful of
 `VkPipeline` objects for the life of the process and no extra Slang call at all
 — `PipelineCache` keys the compile on the source and the pipeline on the state.
 `material.side`, by contrast, is an axis an agent varies freely.

 `NONE` is first so C3's zero fill spells "opaque".
*>
enum BlendMode : char
{
	NONE,
	ALPHA,
	ADDITIVE,
}

<*
 The fixed-function state a pipeline is *built* with — as opposed to the state it
 is *told* at record time.

 ## The cull mode is not in here, and that is the interesting part

 Four things vary across the pipelines this project needs: topology, cull mode,
 and the two depth flags. All four are settable dynamically on a Vulkan 1.3
 device, so in principle none of them needs a pipeline of its own.

 Topology is the exception, and it was measured rather than assumed. With
 `dynamicPrimitiveTopologyUnrestricted` false — which is what this machine's
 device reports — `vkCmdSetPrimitiveTopology` may only pick a topology in the
 same *class* as the one the pipeline was built with, and triangles and lines are
 different classes. The bundled KosmicKrisp honours the switch anyway, pixel for
 pixel, because Metal takes the primitive type at draw time. It is still
 undefined behaviour, and the validation layer names it on every draw:

 VUID-vkCmdDrawIndexed-dynamicPrimitiveTopologyUnrestricted-07500

 A validation error on every frame is how a real one gets missed, so the line
 pass gets a pipeline and topology stays here.

 The cull mode went dynamic, and that is where the saving was. It is the one of
 the four a *script* varies — `material.side` — so under a static cull mode every
 distinct side an agent asked for was another `VkPipeline`. It is now
 `vk::cmdSetCullMode` per bucket, which costs one command and no pipeline, and it
 puts the field where it belongs: topology and depth describe the pass, the cull
 mode describes the material.

 The depth flags could go the same way and deliberately have not. They would save
 nothing — the line pass differs in topology regardless — and a pipeline that no
 longer states its own depth behaviour is harder to read for no gain.

 Everything left in here is core Vulkan with no capability bit behind it. That is
 also why a wireframe is a line-list index buffer rather than `POLYGON_MODE_LINE`:
 `fillModeNonSolid` is false on the bundled KosmicKrisp, and so is `wideLines`.
*>
struct PipelineState
{
	vk::PrimitiveTopology topology;
	bool depth_test;
	bool depth_write;
	// How the fragment's colour is combined with what is already there. In here
	// and not in a command because it cannot be a command on this device — see
	// `BlendMode`.
	BlendMode blend;
}

<*
 What everything drew with before there was a choice: solid triangles, back faces
 culled, depth tested and written.
*>
const PipelineState SOLID_STATE = {
	.topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	.depth_test = true,
	.depth_write = true,
};

<*
 What debug geometry draws with: line segments, no culling, and no depth test at
 all.

 The depth part is the one worth defending, because Three.js's helpers are
 depth-tested and these are not.

 A debug line exists to answer "where is this thing", and the times that question
 is asked are exactly the times the thing is somewhere it should not be — inside
 a wall, behind the terrain, buried in the masonry. A box helper hidden by the
 same stone that swallowed the window it was drawn around would be no help at all.

 It also removes the one hard case for free. A wireframe drawn over its own mesh
 is exactly coplanar with it, and coplanar depth is a speckle rather than a line —
 which is the failure the helper is supposed to *diagnose*, appearing in the
 diagnostic. With no depth test there is nothing to fight.

 The cost is that debug geometry does not sort with the scene, so it has to be
 drawn after all of it. `Scene.build_draw_list` puts the line material last for
 that reason, and it is not an ordering that can be got right by luck.
*>
const PipelineState LINE_STATE = {
	.topology = PRIMITIVE_TOPOLOGY_LINE_LIST,
	.depth_test = false,
	.depth_write = false,
};

<*
 What a transparent material draws with: solid triangles that blend over what is
 behind them, depth *tested* but not *written*.

 Reading depth is what keeps glass behind a wall behind the wall, so the test
 stays on. Writing it is the half that has to go, and the reason is this
 renderer's central claim rather than a convention borrowed from elsewhere.

 A bucket is `(asset, mesh, material)` drawn as one instanced call, and the
 copies inside it are not sortable against each other — they are one
 `vkCmdDrawIndexed` and the hardware picks the order. If such a draw wrote depth,
 two overlapping copies of one mesh would each occlude the other depending on
 which the rasteriser reached first: the picture would change between runs, or
 between drivers, with nothing in the scene having moved. Not writing depth makes
 the overlap *blend* instead, which is order-dependent in colour but never in
 visibility — the same answer Three.js's `depthWrite: false` default gives.

 What it costs is the case a depth write would have got right: a transparent
 surface behind another transparent surface of the *same* bucket is not hidden by
 it. `Scene.build_draw_list` sorts the buckets back to front, which fixes it
 between buckets and cannot fix it within one.
*>
const PipelineState ALPHA_STATE = {
	.topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	.depth_test = true,
	.depth_write = false,
	.blend = BlendMode.ALPHA,
};

<*
 `ALPHA_STATE` with the source added to the destination rather than replacing a
 share of it: fire, sparks, glows — anything that only ever brightens.

 Same depth behaviour and the same argument for it. The difference is entirely in
 the blend factors, and it is the one blend mode where ordering genuinely does not
 matter — addition is commutative. It is sorted with the rest anyway, because it
 still has to land *after* the opaque geometry it brightens.
*>
const PipelineState ADDITIVE_STATE = {
	.topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	.depth_test = true,
	.depth_write = false,
	.blend = BlendMode.ADDITIVE,
};

<*
 What a material bakes with: solid triangles, no depth at all, nothing blended.

 Not `SOLID_STATE` with a comment, because every difference is load-bearing. A
 bake rasterises the mesh in *uv* space, so depth is meaningless — every triangle
 sits at z = 0, and a depth test would let whichever one the rasteriser reached
 first hide the rest of the layout. Blending is off so the answer written is the
 body's own rather than the body's over whatever the last mesh left there.

 The cull mode is dynamic, as it is for everything here, and `MaterialBaker` sets
 it to none: a triangle's winding in uv space says nothing about which way it
 faces in the world.
*>
const PipelineState BAKE_STATE = {
	.topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	.depth_test = false,
	.depth_write = false,
};

fn ulong PipelineState.hash(self)
{
	return ((ulong)self.topology * 0xbf58476d1ce4e5b9) ^ (self.depth_test ? 0x94d049bb133111ebUL
		: 0) ^ (self.depth_write ? 0x2545f4914f6cdd1dUL
			: 0) // Multiplied rather than xor'd with a constant per value, so the three modes
			// are three different numbers and `NONE` still contributes nothing — every
			// state written before blending existed hashes exactly as it did.
			^ ((ulong)self
				.blend
				.ordinal
				* 0x9e3779b97f4a7c15);
}

fn bool PipelineState.equals(self, PipelineState other)
{
	return self.topology == other.topology && self.depth_test == other.depth_test
		&& self.depth_write
			== other
				.depth_write // The line that makes a blended variant its own cache entry: one Slang
				// compile, about a millisecond for the extra `VkPipeline`.
		&& self.blend == other.blend;
}

struct MeshPipeline
{
	vk::Pipeline handle;
	vk::PipelineLayout layout;
	vk::DescriptorSetLayout descriptor_layout;
	// What the shader said it wants: bindings by name, push fields by name. Owned
	// by the pipeline and freed with it — see `MeshPipeline.init`.
	ShaderLayout shader;
}

<*
 Checks the shader's push block against the contract a pipeline draws under.

 Every field the contract expects must be present at the same offset and the same
 size. Extra fields in the shader are not an error — a field this side never
 reads is harmless, and refusing it would mean a shader cannot carry anything the
 pass does not use. That is what makes a material's uniforms legal: they are
 exactly such extra fields.

 The contract is a parameter because there are two: `MESH_PUSH_FIELDS` for
 anything that draws geometry and `POST_PUSH_FIELDS` for the pass that draws one
 triangle over the frame. A second copy of this function would be a second place
 for the budget check to be forgotten.

 @param fields : `The push contract to hold the shader to — MESH_PUSH_FIELDS or POST_PUSH_FIELDS.`
 @return ? PUSH_BLOCK_MISMATCH : `The shader's push block does not lay out the way the contract does. The offending field is printed, because "they disagree" is not something anyone can act on.`
*>
fn void? check_push_block(ShaderLayout* layout, PushFieldLayout[] fields)
{
	// Against the budget, not against `MeshPush::size`. Extra fields are allowed —
	// capping the whole block at the mesh struct's size would leave four spare
	// bytes and make a material uniform impossible. What the cap is actually for
	// is that `MeshPass.record` pushes into a `PUSH_BUDGET`-sized staging block, so
	// the budget is the real bound and the device's own limit is checked separately
	// in `MeshPipeline.init`.
	if (layout.push_size > PUSH_BUDGET)
	{
		@advise("shader: the push block is %d bytes and the budget is %d", layout.push_size, PUSH_BUDGET);
		return PUSH_BLOCK_MISMATCH~;
	}

	foreach (expected : fields)
	{
		ShaderField* found = layout.field_of(expected.name);
		if (found == null)
		{
			@advise("shader: the push block has no field '%s'", expected.name);
			return PUSH_BLOCK_MISMATCH~;
		}
		if (found.offset != expected.offset || found.size != expected.size)
		{
			@advise(
				"shader: push field '%s' is at %d+%d and the contract has it at %d+%d",
				expected.name,
				found.offset,
				found.size,
				expected.offset,
				expected.size
			);
			return PUSH_BLOCK_MISMATCH~;
		}
	}
}

<*
 Checks the module contains the entry points that will be named at pipeline
 creation.

 `spAddEntryPoint` already fails loudly for a name that is not in the source, so
 this catches the other direction: a module that compiled but emitted a stage
 under a different name — which is what happens without
 `-fvk-use-entrypoint-name`, where both entry points come out called `main`.

 @return ? SHADER_MISSING_ENTRY_POINT : `The compiled module does not contain an entry point the pipeline names.`
*>
fn void? check_entry_points(ShaderModule* mod, ShaderEntry[] entries = MESH_ENTRIES[..])
{
	foreach (wanted : entries)
	{
		bool found = false;
		foreach (entry : mod.entries)
		{
			if (entry.name == wanted.name && entry.stage == wanted.stage) found = true;
		}
		if (!found)
		{
			@advise("shader: the module has no '%s' entry point", wanted.name);
			return SHADER_MISSING_ENTRY_POINT~;
		}
	}
}

<*
 Everything a pipeline needs before there is a `VkPipeline`: the checks, the
 descriptor set layout and the pipeline layout.

 Shared by `init` and `init_post` because it is the half that has nothing to do
 with how the pass rasterises — it is the module's own declarations turned into
 Vulkan objects, and a module is a module. What the two constructors differ by is
 entirely below: attachments, depth, blending and culling.

 The one thing that varies here is which push contract the shader is held to.

 @param fields : `MESH_PUSH_FIELDS or POST_PUSH_FIELDS — see check_push_block.`
 @param entries : `Which entry points the module must contain. Defaults to the two a shading pipeline has; the shadow pass passes SHADOW_ENTRIES, which is a vertex stage alone.`
 @return ? NO_SCALAR_BLOCK_LAYOUT : `The shader reads tightly packed float3 streams, which is only legal with VK_EXT_scalar_block_layout.`
 @return ? PUSH_BLOCK_TOO_LARGE : `The device offers fewer push-constant bytes than the block needs.`
 @return ? SHADER_TOO_MANY_SETS : `The shader declares bindings in more than one descriptor set and this creates one.`
 @return ? SHADER_BINDING_UNSUPPORTED : `The shader declares something no Vulkan descriptor type covers.`
*>
fn void? MeshPipeline.build_layouts(
	&self,
	Gpu* gpu,
	ShaderModule* mod,
	PushFieldLayout[] fields,
	ShaderEntry[] entries = MESH_ENTRIES[..]
)
{
	if (!gpu.limits.scalar_block_layout) return NO_SCALAR_BLOCK_LAYOUT~;
	// The *shader's* block, not `MeshPush::size`. A material appends its uniforms
	// to the tail, so what gets pushed is not bounded by the C3 struct — checking
	// the struct would let a 128-byte material block through on a device offering
	// 64.
	if (mod.layout.push_size > gpu.limits.max_push_constants_size) return PUSH_BLOCK_TOO_LARGE~;

	check_entry_points(mod, entries)!;
	check_push_block(&mod.layout, fields)!;

	if (mod.layout.set_count > 1)
	{
		@advise("shader: %d descriptor sets declared and this pass creates one", mod.layout.set_count);
		return SHADER_TOO_MANY_SETS~;
	}

	// Derived, not declared: every field of this array comes out of the module
	// that is about to be loaded.
	@pool()
	{
		List{vk::DescriptorSetLayoutBinding} bindings;
		bindings.tinit(4);
		foreach (binding : mod.layout.bindings)
		{
			if (binding.type == DESCRIPTOR_TYPE_UNBINDABLE)
			{
				@advise("shader: cannot bind '%s' — no Vulkan descriptor type for it", binding.name);
				return SHADER_BINDING_UNSUPPORTED~;
			}
			bindings.push(
				{
					.binding = binding.binding,
					.descriptorType = binding.type,
					.descriptorCount = binding.count,
					.stageFlags = binding.stages,
				}
			);
		}

		// `PUSH_DESCRIPTOR_BIT` makes this a layout that is never allocated from.
		// Sets for it are specified inline by `cmdPushDescriptorSetKHR` at draw
		// time, which is why `Assets` has no pool, no set list and — the part that
		// mattered — no reason to know a pipeline exists.
		// 
		// A module with no bindings still gets a layout, and `setBindings` is what
		// has to be skipped rather than the layout: the builder takes the address of
		// the slice's first element, so an empty slice faults inside the binding
		// rather than producing the empty layout it looks like it would. An empty
		// descriptor set layout is legal and keeps the pipeline layout and `free` a
		// single shape for all three constructors.
		vk::DescriptorSetLayoutCreateInfo set_layout = vk::descriptorSetLayoutCreateInfo()
			.setFlags(DESCRIPTOR_SET_LAYOUT_CREATE_PUSH_DESCRIPTOR_BIT);
		if (bindings.len() > 0) set_layout = set_layout.setBindings(bindings.array_view());
		self.descriptor_layout = set_layout.build(gpu.handle)!;
	};

	vk::PushConstantRange push_range = {
		.stageFlags = mod.layout.stages,
		.offset = 0, // The shader's own size rather than `MeshPush::size`: reflection reports the
		// bytes that are used, not what the C3 struct occupies with its tail
		// padding, and a range longer than the block is a validation error on some
		// drivers. `check_push_block` has already proved they agree field for field.
		.size = mod.layout.push_size,
	};

	self.layout = vk::pipelineLayoutCreateInfo().setSetLayouts({ self.descriptor_layout })
		.setPushConstantRanges({ push_range })
		.build(gpu.handle)!;
}

<*
 What a graphics pipeline in this project looks like when nothing has asked for
 anything unusual, and the fields the three constructors below vary.

 Splatted the way `IMAGE_BARRIER` is — `{ ...GRAPHICS_PIPELINE, .stages = … }` —
 so each constructor names exactly the settings its own doc block enumerates and
 says nothing about the rest. A function taking these positionally would put four
 booleans and two enums in a row at the call site.

 Everything *not* here is the same for every pipeline in the project and lives in
 `build_graphics`: an empty vertex input state, `defaultMultisampleState`, one
 viewport and one scissor, and `POLYGON_MODE_FILL` with counter-clockwise front
 faces.
*>
struct GraphicsPipelineDesc
{
	// One entry is a depth-only pipeline; two is vertex plus fragment. There is no
	// third case here.
	vk::PipelineShaderStageCreateInfo[] stages;
	// The attachment formats the pass will actually begin with. Dynamic rendering
	// checks these against the real attachments, so a wrong one is a validation
	// error rather than a wrong picture.
	vk::PipelineRenderingCreateInfo* rendering;
	// One attachment for a pass that writes colour, zero for one that does not.
	vk::PipelineColorBlendStateCreateInfo* color_blend;
	vk::PrimitiveTopology topology;
	// Ignored when `dynamic_cull` is set — see the rasterization state below.
	vk::CullModeFlags cull;
	// Declare `DYNAMIC_STATE_CULL_MODE` and let `MeshPass.record` set the
	// material's own per bucket. Off for the post and shadow passes, deliberately:
	// each runs on a path where an inherited dynamic value would decide whether the
	// frame appears at all.
	bool dynamic_cull;
	bool depth_test;
	bool depth_write;
}

<*
 A pipeline that draws opaque triangles, culls nothing, and neither tests nor
 writes depth. Every field is overridden by somebody; the point is that a
 constructor states its differences and not its agreements.
*>
const GraphicsPipelineDesc GRAPHICS_PIPELINE = {
	.topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	.cull = CULL_MODE_NONE,
	.dynamic_cull = false,
	.depth_test = false,
	.depth_write = false,
};

<*
 The half of a graphics pipeline that is the same whatever the pass rasterises.

 `build_layouts` is the other shared half — the module's declarations turned into
 Vulkan objects — and this is the fixed-function description that would otherwise
 be written out three times, once per constructor, agreeing in about forty lines
 and differing in the eight `GraphicsPipelineDesc` carries.

 Counter-clockwise, the same as glTF's own convention, and the negative viewport
 does not change that. It is tempting to reason that `gpu/target.c3`'s
 negative-height viewport mirrors the image and therefore reverses the winding.
 It does not, and getting this backwards culls exactly the faces that should be
 visible — which looks like a broken pipeline rather than a raster setting,
 because validation is perfectly happy and the screen is empty. The negative
 viewport exists to *undo* Vulkan's Y-down NDC; undoing a flip is not a flip.

 `POLYGON_MODE_FILL` only, whatever the topology: `fillModeNonSolid` is false on
 the bundled driver, which is why `LINE_STATE` reaches lines through
 `PRIMITIVE_TOPOLOGY_LINE_LIST` and an index buffer of pairs.

 The depth compare op is always `LESS_OR_EQUAL`. Vulkan ignores it when
 `depthTestEnable` is false, so the post pass carrying it costs nothing and the
 alternative is a branch that reads as though it mattered.

 @param mod : `Only its layout is read, and it is copied rather than moved — see the note at the end.`
*>
fn MeshPipeline? MeshPipeline.build_graphics(&self, Gpu* gpu, ShaderModule* mod, GraphicsPipelineDesc desc)
{
	// Empty, and that is the point: geometry arrives as buffer device addresses.
	// There is no attribute-binding layer in this project.
	vk::PipelineVertexInputStateCreateInfo vertex_input = vk::pipelineVertexInputStateCreateInfo();

	vk::PipelineInputAssemblyStateCreateInfo input_assembly = vk::pipelineInputAssemblyStateCreateInfo()
		.setTopology(desc.topology)
		.setPrimitiveRestartEnable(vk::FALSE);

	vk::PipelineRasterizationStateCreateInfo rasterization = vk::defaultRasterizationState().setCullMode(desc.cull)
		.setFrontFace(FRONT_FACE_COUNTER_CLOCKWISE)
		.setPolygonMode(POLYGON_MODE_FILL);

	vk::PipelineMultisampleStateCreateInfo multisample = vk::defaultMultisampleState();

	vk::PipelineDepthStencilStateCreateInfo depth = vk::defaultDepthStencilState()
		.setDepthTestEnable(desc.depth_test ? vk::TRUE : vk::FALSE)
		.setDepthWriteEnable(desc.depth_write ? vk::TRUE : vk::FALSE)
		.setDepthCompareOp(COMPARE_OP_LESS_OR_EQUAL);

	// `CULL_MODE` alongside the two the swapchain needs, and only when the pass
	// wants it. Core in Vulkan 1.3 with no feature bit, so there is nothing to
	// query and nothing to fall back to — see `PipelineState` for why topology is
	// not here beside it.
	vk::DynamicState[3] dynamic_states = {
		DYNAMIC_STATE_VIEWPORT,
		DYNAMIC_STATE_SCISSOR,
		DYNAMIC_STATE_CULL_MODE,
	};
	usz dynamic_used = desc.dynamic_cull ? 3 : 2;
	vk::PipelineDynamicStateCreateInfo dynamic = vk::pipelineDynamicStateCreateInfo()
		.setDynamicStates(dynamic_states[:dynamic_used]);

	vk::PipelineViewportStateCreateInfo viewport = vk::pipelineViewportStateCreateInfo().setViewportCount(1)
		.setScissorCount(1);

	self.handle = vk::graphicsPipelineCreateInfo().setNext(desc.rendering).setStages(desc.stages)
		.setVertexInputState(&vertex_input)
		.setInputAssemblyState(&input_assembly)
		.setViewportState(&viewport)
		.setRasterizationState(&rasterization)
		.setMultisampleState(&multisample)
		.setColorBlendState(desc.color_blend)
		.setDepthStencilState(&depth)
		.setDynamicState(&dynamic)
		.setLayout(self.layout)
		.build(gpu.handle, gpu.driver_cache.handle)!;

	// A copy, not a move. A module now produces one pipeline per render state —
	// the line pass and the solid pass are one `mesh.slang`, and a material's two
	// sides are one source — so the module has to survive with its layout intact.
	// 
	// Still owned by the pipeline and still freed with it. `ShaderLayout.copy` has
	// the argument against borrowing instead.
	self.shader = mod.layout.copy();

	return *self;
}

<*
 Builds the mesh pipeline from a compiled Slang module.

 No vertex input state, no `VkRenderPass`, no `VkFramebuffer`: attachment formats
 are declared here through `PipelineRenderingCreateInfo` and the attachments
 themselves at record time.

 @param mod : `A module from compile_slang. Its layout is copied, not moved — the caller keeps the module and may build more pipelines from it.`
 @return ? NO_SCALAR_BLOCK_LAYOUT : `The shader reads tightly packed float3 streams, which is only legal with VK_EXT_scalar_block_layout. Refusing here beats rendering geometry read at the wrong stride.`
 @return ? PUSH_BLOCK_TOO_LARGE : `The device offers fewer push-constant bytes than the block needs. Cannot happen on a conformant device — 128 is the required minimum — so this is a sentence rather than a fallback.`
 @return ? SHADER_TOO_MANY_SETS : `The shader declares bindings in more than one descriptor set and this pass creates one. Not a limitation of the reflection, which reads them all.`
 @return ? SHADER_BINDING_UNSUPPORTED : `The shader declares something this pass cannot bind — an acceleration structure, say. Named rather than guessed at.`
*>
fn MeshPipeline? MeshPipeline.init(
	&self,
	Gpu* gpu,
	Target* target,
	ShaderModule* mod,
	PipelineState state,
	PushFieldLayout[] contract = MESH_PUSH_FIELDS[..]
)
{
	self.build_layouts(gpu, mod, contract)!;

	vk::ShaderModule module_handle = vk::loadShaderModule(gpu.handle, mod.spirv)!;
	defer module_handle.free(gpu.handle);

	vk::PipelineShaderStageCreateInfo[2] stages = {
		vk::pipelineShaderStageCreateInfo()
		.setStage(SHADER_STAGE_VERTEX_BIT)
		.setMod(module_handle)
		.setName("vertexMain"), vk::pipelineShaderStageCreateInfo().setStage(SHADER_STAGE_FRAGMENT_BIT)
			.setMod(module_handle)
			.setName("fragmentMain"), };

	vk::PipelineRenderingCreateInfo rendering = vk::pipelineRenderingCreateInfo()
		.setColorAttachmentFormats((vk::Format[]) { target.color_format })
		.setDepthAttachmentFormat(target.depth_format);

	// Baked in, because it cannot be anything else on this device. Every
	// colour-blend bit of `VK_EXT_extended_dynamic_state3` is false on the
	// KosmicKrisp build this targets — Metal keeps blending inside the compiled
	// pipeline state — so unlike the cull mode, which `dynamic_cull` turns into a
	// command per bucket, this is a pipeline per mode. See `BlendMode`.
	// 
	// `vk::defaultColorBlendAttachment` is *already* standard alpha —
	// SRC_ALPHA / ONE_MINUS_SRC_ALPHA over ONE / ONE_MINUS_SRC_ALPHA — so the
	// `ALPHA` case is the helper unchanged and the opaque case is the one that has
	// to turn something off.
	vk::PipelineColorBlendAttachmentState blend = vk::defaultColorBlendAttachment();
	switch (state.blend)
	{
		case NONE:
			blend.blendEnable = vk::FALSE;
		case ALPHA:
			// The helper's own defaults are already this mode. Written as an
			// explicit `break` rather than left to fall off the end, because C3
			// refuses a case that is only a comment — and rightly: "nothing to do
			// here" and "somebody deleted a line" look identical otherwise.
			break;
		case ADDITIVE:
			// Source over destination with nothing taken away. The alpha channel
			// accumulates the same way, which matters only for an offscreen target
			// somebody reads back — `Target.capture` forces it opaque.
			blend.dstColorBlendFactor = BLEND_FACTOR_ONE;
			blend.dstAlphaBlendFactor = BLEND_FACTOR_ONE;
	}
	vk::PipelineColorBlendStateCreateInfo color_blend = vk::defaultColorBlendState(
		(vk::PipelineColorBlendAttachmentState[]) { blend }
	);

	return self.build_graphics(
		gpu,
		mod,
		{
			...GRAPHICS_PIPELINE,
			.stages = stages[..],
			.rendering = &rendering,
			.color_blend = &color_blend,
			.topology = state
				.topology, // Ignored, because `dynamic_cull` is set just below and `MeshPass.record`
				// supplies the material's own per bucket. Written as the old default rather
				// than left as the struct's `CULL_MODE_NONE`, because a reader who missed
				// the dynamic state would take that zero for a choice.
			.cull = CULL_MODE_BACK_BIT,
			.dynamic_cull = true,
			.depth_test = state.depth_test,
			.depth_write = state.depth_write,
		}
	);
}

<*
 Builds the post-processing pipeline from a compiled Slang module.

 The same object as `init` produces, so `Gpu.retire_pipeline` and
 `MeshPipeline.free` cover it with no new machinery. Four things differ, and each
 would be a bug if it did not:

 - No depth attachment, no depth test and no depth write. Dynamic rendering
 matches the pipeline's declared depth format against the one the attachment
 actually carries, so declaring a depth format and then beginning a pass
 without one is a validation error rather than a wasted attachment.
 - No blending. A post pass writes every pixel of the frame from the image it
 just sampled; blending it over the previous contents would compose it with an
 attachment that is about to be cleared anyway.
 - `CULL_MODE_NONE`, statically. The fullscreen triangle is clockwise on screen,
 the opposite of everything else this project draws, and
 `DYNAMIC_STATE_CULL_MODE` is deliberately *not* declared: the post draw
 follows `MeshPass.record`, which sets the cull mode per bucket, so an
 inherited dynamic value would decide whether the frame appears. Getting this
 wrong is an empty frame with no validation message.
 - `POST_PUSH_FIELDS`, not the mesh contract. There is no geometry to point at,
 so a shader required to declare `positions` could not be written.

 ## The colour format is a parameter

 In a chain every pass a script writes reads float and writes float, and the
 engine's own tonemap is the only thing that writes `target.color` — so there are
 exactly two answers, `POST_CHAIN_FORMAT` and the target's, and which one a
 pipeline was built with is not something the pipeline can be asked afterwards.

 Passing it is what keeps it out of the cache key. Deriving it from the pass's
 position would make the same body at slot 3 and at slot N two `VkPipeline`s,
 put output format in the key, and turn reordering a chain into a recompile.

 @param mod : `A module from post_source + compile_slang_cached. Its layout is copied, not moved.`
 @param color_format : `What this pass writes — POST_CHAIN_FORMAT for a chain pass, target.color_format for the tonemap. Dynamic rendering checks it against the attachment, so a wrong one is a validation error rather than a wrong colour.`
 @return ? PUSH_BLOCK_MISMATCH : `The module does not begin its push block with a 16-byte 'info'. Reachable from a hand-written shader, not from post_source.`
*>
fn MeshPipeline? MeshPipeline.init_post(&self, Gpu* gpu, ShaderModule* mod, vk::Format color_format)
{
	self.build_layouts(gpu, mod, POST_PUSH_FIELDS[..])!;

	vk::ShaderModule module_handle = vk::loadShaderModule(gpu.handle, mod.spirv)!;
	defer module_handle.free(gpu.handle);

	vk::PipelineShaderStageCreateInfo[2] stages = {
		vk::pipelineShaderStageCreateInfo()
		.setStage(SHADER_STAGE_VERTEX_BIT)
		.setMod(module_handle)
		.setName("vertexMain"), vk::pipelineShaderStageCreateInfo().setStage(SHADER_STAGE_FRAGMENT_BIT)
			.setMod(module_handle)
			.setName("fragmentMain"), };

	// Colour only. `setDepthAttachmentFormat` is absent rather than set to
	// FORMAT_UNDEFINED for readability; the zero the struct starts with is
	// FORMAT_UNDEFINED, which is how "there is no depth attachment" is spelled.
	vk::PipelineRenderingCreateInfo rendering = vk::pipelineRenderingCreateInfo()
		.setColorAttachmentFormats((vk::Format[]) { color_format });

	vk::PipelineColorBlendAttachmentState blend = vk::defaultColorBlendAttachment();
	blend.blendEnable = vk::FALSE;
	vk::PipelineColorBlendStateCreateInfo color_blend = vk::defaultColorBlendState(
		(vk::PipelineColorBlendAttachmentState[]) { blend }
	);

	// No depth of any kind, and `CULL_MODE_NONE` statically — both are the header's
	// argument, and `dynamic_cull` staying false keeps an inherited cull mode from
	// deciding whether the frame appears.
	return self.build_graphics(
		gpu,
		mod,
		{
			...GRAPHICS_PIPELINE,
			.stages = stages[..],
			.rendering = &rendering,
			.color_blend = &color_blend,
		}
	);
}

<*
 Builds the shadow pass's pipeline from a compiled `shaders/shadow.slang`.

 The third constructor on this type, and the one that draws no colour at all. It
 shares `build_layouts` with the other two and differs in five places, each of
 which would be a validation error or a wrong picture if it did not:

 - One shader stage. A depth-only pipeline is allowed to have no fragment shader.
 `SHADOW_ENTRIES` is what `build_layouts` is held to instead of `MESH_ENTRIES`,
 so a module with a `fragmentMain` is not required and one without it is not
 refused.
 - No colour attachment, and a depth format that is not the target's. The shadow
 map is its own image at its own extent, and dynamic rendering checks the
 declared formats against the attachments the pass actually begins with.
 - `CULL_MODE_NONE`, statically. Two reasons pointing the same way: a closed mesh
 is unaffected — its back faces are further from the light and lose the depth
 test — while an open one, a plane or a leaf card, casts nothing at all with
 either face culled from *some* light direction. And
 `DYNAMIC_STATE_CULL_MODE` is absent for `init_post`'s reason.
 - Depth tested and written, which is the whole output. `SOLID_STATE`'s two
 trues, spelled out here rather than taken from it, because `PipelineState`
 also carries a topology and a blend mode and neither means anything to a pass
 with no colour attachment.
 - `MESH_PUSH_FIELDS`, the same contract the shading pipelines are held to. That
 is not a coincidence to be tidied away: the shadow pass reads the same
 instance array and the same draw record the main pass reads, out of the same
 buffers, which is what makes a skinned character's shadow the shadow of the
 pose it is actually in.

 @param mod : `A module from compile_slang containing vertexMain. Its layout is copied, not moved.`
 @param depth_format : `The shadow map's format — see ShadowMap.ensure, which picks one the device will both render to and sample.`
 @return ? SHADER_MISSING_ENTRY_POINT : `The module has no vertexMain.`
 @return ? PUSH_BLOCK_MISMATCH : `The module does not lay its push block out the way the mesh contract does. Reachable by editing shaders/shadow.slang and nothing else.`
*>
fn MeshPipeline? MeshPipeline.init_shadow(&self, Gpu* gpu, ShaderModule* mod, vk::Format depth_format)
{
	self.build_layouts(gpu, mod, MESH_PUSH_FIELDS[..], SHADOW_ENTRIES[..])!;

	vk::ShaderModule module_handle = vk::loadShaderModule(gpu.handle, mod.spirv)!;
	defer module_handle.free(gpu.handle);

	vk::PipelineShaderStageCreateInfo[1] stages = {
		vk::pipelineShaderStageCreateInfo()
		.setStage(SHADER_STAGE_VERTEX_BIT)
		.setMod(module_handle)
		.setName("vertexMain"), };

	// Depth alone. `setColorAttachmentFormats` is not called rather than being
	// called with an empty slice, for the reason `init_post` leaves the depth
	// format out: the zero the struct starts with already spells "there is none".
	vk::PipelineRenderingCreateInfo rendering = vk::pipelineRenderingCreateInfo()
		.setDepthAttachmentFormat(depth_format);

	// Zero attachments, which is legal precisely because the rendering info above
	// declares none. Passed rather than left null so nothing has to reason about
	// which of the two spellings a driver accepts.
	vk::PipelineColorBlendStateCreateInfo color_blend = vk::pipelineColorBlendStateCreateInfo();

	// Depth tested and written is the whole output; `CULL_MODE_NONE` statically for
	// the two reasons in the header.
	return self.build_graphics(
		gpu,
		mod,
		{
			...GRAPHICS_PIPELINE,
			.stages = stages[..],
			.rendering = &rendering,
			.color_blend = &color_blend,
			.depth_test = true,
			.depth_write = true,
		}
	);
}

fn void MeshPipeline.free(&self, Gpu* gpu)
{
	if (self.handle != null) self.handle.free(gpu.handle);
	if (self.layout != null) self.layout.free(gpu.handle);
	if (self.descriptor_layout != null) self.descriptor_layout.free(gpu.handle);
	self.shader.free();
	*self = { };
}

// ============================================================================
// Compute skinning
// ============================================================================

<*
 The pipeline `shaders/skin.slang` becomes.

 The only compute pipeline in the project, and the only thing it has in common
 with `MeshPipeline` is the push-block check: there is no vertex input state to
 leave empty, no attachment format to declare, no blend mode, no cull mode, and
 no `PipelineState` to key a cache on. One shader, one pipeline, built once when
 a character first asks to be skinned this way.

 No descriptor set layout either. The mesh path needs one for its texture; this
 reads nothing but buffer device addresses, so its pipeline layout is a push
 range and nothing else.
*>
struct SkinPipeline
{
	vk::Pipeline handle;
	vk::PipelineLayout layout;
	ShaderLayout shader;
	bool ready;
}

<*
 Compiles the skinning shader and builds the compute pipeline from it.

 The same runtime compile every other shader here goes through — `compile_slang`
 takes the entry points it wants by name and stage, and `slang::STAGE_COMPUTE` is
 one of them.

 @param mod : `A module from compile_slang containing computeMain.`
 @return ? NO_SCALAR_BLOCK_LAYOUT : `The shader reads tightly packed float3 streams, and so does everything else here.`
 @return ? PUSH_BLOCK_TOO_LARGE : `The device offers fewer push bytes than the block needs.`
 @return ? SHADER_MISSING_ENTRY_POINT : `The module has no computeMain.`
 @return ? PUSH_BLOCK_MISMATCH : `The shader's push block is not the one SKIN_PUSH_FIELDS describes.`
*>
fn SkinPipeline? SkinPipeline.init(&self, Gpu* gpu, ShaderModule* mod)
{
	if (!gpu.limits.scalar_block_layout) return NO_SCALAR_BLOCK_LAYOUT~;
	if (mod.layout.push_size > gpu.limits.max_push_constants_size) return PUSH_BLOCK_TOO_LARGE~;

	check_entry_points(mod, SKIN_ENTRIES[..])!;
	check_push_block(&mod.layout, SKIN_PUSH_FIELDS[..])!;

	vk::PushConstantRange push_range = {
		.stageFlags = SHADER_STAGE_COMPUTE_BIT,
		.offset = 0,
		.size = mod.layout.push_size,
	};

	// No set layouts at all: everything this shader reads it reaches by address.
	self.layout = vk::pipelineLayoutCreateInfo().setPushConstantRanges({ push_range }).build(gpu.handle)!;

	vk::ShaderModule module_handle = vk::loadShaderModule(gpu.handle, mod.spirv)!;
	defer module_handle.free(gpu.handle);

	vk::ComputePipelineCreateInfo info = vk::computePipelineCreateInfo()
		.setStage(vk::pipelineShaderStageCreateInfo().setStage(SHADER_STAGE_COMPUTE_BIT).setMod(module_handle)
			.setName("computeMain"))
		.setLayout(self.layout);

	vk::Pipeline handle;
	vk::createComputePipelines(gpu.handle, gpu.driver_cache.handle, 1, &info, null, &handle)!;
	self.handle = handle;

	// Moved, exactly as `MeshPipeline.init` moves it: the pipeline outlives the
	// module it was built from.
	self.shader = mod.layout;
	mod.layout = { };
	self.ready = true;

	return *self;
}

fn void SkinPipeline.free(&self, Gpu* gpu)
{
	if (self.handle != null) self.handle.free(gpu.handle);
	if (self.layout != null) self.layout.free(gpu.handle);
	self.shader.free();
	*self = { };
}

// ============================================================================
// The cache
// ============================================================================

<*
 One compiled shader the cache is keeping, and the source that produced it.

 A pipeline is `(source, render state)`. A *compile* is source alone — Slang
 emits byte-identical SPIR-V for a line pipeline and a solid one, because
 topology, cull mode and the depth flags are `VkGraphicsPipelineCreateInfo`
 fields the shader never sees.

 Keying both levels together costs nothing until something asks for two states
 over one source. Debug lines and `material.side` both ask, and under a single
 key each called Slang again on source it had already compiled: measured at
 `compiles=2, hits=0` for a `MeshPass.init` that builds one shader. Roughly 17 ms
 for the compile against 1 ms for the pipeline, so splitting the levels is worth
 seventeen eighteenths of the cost.
*>
struct CachedModule
{
	ulong hash;
	// The source that produced it, kept so a hash *hit* can be confirmed rather
	// than trusted — the same rule `gpu/texture.c3` follows when it compares
	// dimensions before believing its content hash. A 64-bit collision here would
	// build a pipeline out of a different shader, which renders something plausible
	// and wrong.
	String source;
	ShaderModule mod;
	// How many `CachedPipeline` entries were built from it. Not how many callers
	// asked: two render states over one source are two entries and one module, and
	// the SPIR-V has to outlive both. At zero the module is freed outright rather
	// than kept warm, because a source with no pipeline left is exactly the
	// accumulation eviction exists to stop.
	uint refs;
}

<*
 One pipeline the cache is keeping: which module, and over which state.

 The module is a pointer rather than a copy because a `CachedModule` holds the
 SPIR-V. It is borrowed from `PipelineCache.modules`, whose entries are heap-boxed
 for the same reason the pipelines are — a later `acquire` that grows either list
 must not move something already in use.
*>
struct CachedPipeline
{
	CachedModule* compiled;
	PipelineState state;
	MeshPipeline pipeline;
	// How many live borrows there are. `acquire` hands one out, `retain` takes
	// another, `release` gives one back — and an entry at zero is not yet freed,
	// only evictable. See `PipelineCache.trim`.
	uint refs;
	// The cache's own ordinal at the moment `refs` last reached zero, which makes
	// the eviction order least-recently-released rather than whichever the scan
	// reached first. Meaningless while `refs > 0`.
	ulong released_at;
}

<*
 Pipelines by content hash.

 An agent iterating on a shader in a loop would otherwise create hundreds of
 `VkPipeline` objects in a session, and a hit must skip the Slang call entirely
 rather than just the pipeline creation, because compilation is the expensive
 half — about 17 ms per compile against roughly 1 ms for the pipeline.

 That ratio is why there are two levels rather than one key. A shader compiles
 once; a pipeline is built once per render state over it. See `CachedModule`.

 Entries in both lists are heap-allocated and handed out by pointer, so a later
 `acquire` that grows either one does not move a pipeline something is already
 drawing with, or a module a pipeline entry points at.
*>
struct PipelineCache
{
	// Two levels, keyed differently. See `CachedModule` for why they are not one.
	List{CachedModule*} modules;
	List{CachedPipeline*} entries;
	// How many times Slang was actually invoked, and how many acquires were
	// answered without it. Not diagnostics: `the_pipeline_cache_skips_the_compile`
	// asserts on these, because "the same pointer came back" would also be true of
	// a cache that recompiled and threw the result away.
	uint compiles;
	uint hits;
	// How many modules came off `shader/disk_cache.c3` instead — a miss here and a
	// hit there, which is the case the disk cache exists for and the one the
	// in-memory counters above cannot see.
	// 
	// `compiles` keeps meaning "Slang ran", which is why this is a counter of its
	// own. Every existing test that asserts on `compiles` is asserting about
	// *Slang*, and a disk hit that incremented it would turn all of them into tests
	// of the wrong cache.
	uint disk_hits;
	// How many `VkPipeline` objects were built. Separate from `compiles` because
	// they are no longer the same number, and the whole point of the split is that
	// the cheap one can happen without the expensive one — a test that only watched
	// `compiles` would pass on a cache that had stopped caching pipelines at all.
	uint builds;
	// How many entries have been evicted and their pipelines retired. Asserted on
	// for the same reason `compiles` is: "the cache did not grow" would also be
	// true of a cache that never cached anything.
	uint evictions;
	// Ticks once per release-to-zero. Only its order is read — see
	// `CachedPipeline.released_at`.
	ulong clock;
}

<*
 How many unreferenced entries the cache keeps before it starts evicting.

 Not zero, and that is the whole design. Dropping an entry the instant its last
 borrow goes would make this a refcounted allocator rather than a cache: a script
 that disposes a material and builds the same one again — what an agent iterating
 on a scene does every run — would pay to rebuild a pipeline it had just given
 back.

 Not unbounded either, which is where it started: an agent iterating on a shader
 accumulated one `VkPipeline` per distinct source for the life of the process.

 Eight is one bucket per material an interactive scene plausibly cycles through,
 and it is not a number anybody measured.
 `the_pipeline_cache_evicts_what_nothing_uses` pins the behaviour rather than the
 constant.
*>
const uint MAX_UNUSED_PIPELINES = 8;

fn void PipelineCache.init(&self)
{
	self.modules.init(mem, 2);
	self.entries.init(mem, 2);
}

<*
 The compiled module for this source, compiling it if it is new.

 Split out of `acquire` because it is the level with the cost in it: the SPIR-V
 depends on the source and on nothing else, so two render states over one shader
 come through here once.

 @return `Borrowed from the cache, which owns it. Null is never returned — a failure is a fault.`
*>
fn CachedModule*? PipelineCache.module_for(&self, String source, String name, String* diagnostic)
{
	ulong hash = content_hash((char[])source);

	foreach (existing : self.modules)
	{
		if (existing.hash != hash) continue;
		// Identity, not the hash — see `CachedModule.source`.
		if (existing.source != source) continue;
		self.hits++;
		return existing;
	}

	// Through the disk cache, so the *first* compile in a process can be free too —
	// the one level the in-memory cache above cannot reach. Everything below this
	// line is unchanged by which side answered, the diagnostic included: a stored
	// module carries the warning it was compiled with.
	bool ran         = false;
	ShaderModule mod = compile_slang_cached(source, name, MESH_ENTRIES[..], &ran)!;
	if (ran)
	{
		self.compiles++;
	}
	else
	{
		self.disk_hits++;
	}

	// Handed over before the `ok` check, because a successful compile can still
	// warn and the caller asked for the text, not for the failures.
	if (diagnostic != null && mod.diagnostic.len > 0) *diagnostic = mod.diagnostic.copy(mem);

	if (!mod.ok)
	{
		// Printed only when nobody took delivery: a compile that fails quietly is
		// the worst possible outcome, so the text has to reach *someone* on every
		// path.
		if (diagnostic == null) io::eprintn(mod.diagnostic);
		// Freed rather than kept. A cached failure would be handed to the next
		// caller as though it were a shader, and the next caller is usually the
		// agent having just fixed the typo.
		mod.free();
		return SHADER_COMPILE_FAILED~;
	}
	if (diagnostic == null && mod.diagnostic.len > 0) io::eprintn(mod.diagnostic);

	CachedModule* entry = mem::new(CachedModule);
	entry.hash = hash;
	entry.source = source.copy(mem);
	entry.mod = mod;
	self.modules.push(entry);
	return entry;
}

<*
 The pipeline for this source and this render state, compiling it if it is new.

 `diagnostic`, when non-null, receives Slang's text — on failure and on success
 alike, since a warning arrives with `ok == true` and is worth surfacing. The
 caller owns the string. Passing null prints to stderr instead, which is what the
 CLI and the built-in mesh pipeline want.

 @param name : `What diagnostics call the source.`
 @param state : `Topology, cull mode and depth behaviour. Part of the key, so two states over one source are two pipelines and one compile.`
 @param [out] diagnostic : `Receives Slang's output verbatim, or is left alone if null. Set on warnings as well as errors — check the fault, not this.`
 @return `A pointer owned by the cache. Valid until the cache is freed.`
*>
fn MeshPipeline*? PipelineCache.acquire(
	&self,
	Gpu* gpu,
	Target* target,
	String source,
	String name,
	PipelineState state,
	String* diagnostic = null,
	PushFieldLayout[] contract = MESH_PUSH_FIELDS[..]
)
{
	// The module first, and by source alone. A state this cache has not seen before
	// must not reach Slang: `CachedModule` has the measurement.
	CachedModule* compiled = self.module_for(source, name, diagnostic)!;

	foreach (entry : self.entries)
	{
		// Pointer identity is exact here in a way a hash is not — both entries came
		// out of `module_for`, which has already confirmed the source.
		if (entry.compiled != compiled || !entry.state.equals(state)) continue;
		// A hit takes a borrow like a miss does, so the caller's `release` is the
		// same call either way and does not have to know which it got.
		entry.refs++;
		return &entry.pipeline;
	}

	// Built into a local first, so a pipeline that fails to build leaves nothing
	// half-allocated behind. Nothing here can fail after this line.
	MeshPipeline built;
	built.init(gpu, target, &compiled.mod, state, contract)!;
	self.builds++;

	CachedPipeline* entry = mem::new(CachedPipeline);
	entry.compiled = compiled;
	entry.state = state;
	entry.pipeline = built;
	entry.refs = 1;
	// The module is kept alive by its pipelines and by nothing else. A build that
	// failed on the line above leaves a freshly compiled module at zero — cached,
	// so the retry is free, and released at `free` rather than by eviction, which
	// only ever runs off an entry.
	compiled.refs++;

	self.entries.push(entry);
	return &entry.pipeline;
}

<*
 The entry a handed-out pipeline belongs to, or null if it came from elsewhere.

 By pointer identity, which is what the cache promised: entries are heap-boxed
 precisely so the address it returned stays the address it owns.
*>
fn CachedPipeline* PipelineCache.entry_for(&self, MeshPipeline* pipeline)
{
	if (pipeline == null) return null;
	foreach (entry : self.entries)
	{
		if (&entry.pipeline == pipeline) return entry;
	}
	return null;
}

<*
 Takes another borrow of a pipeline `acquire` already handed out.

 For a second holder of one pointer that did not go through `acquire` to get it —
 `MeshPass.create_texture_material` copies `MeshPass.pipeline` rather than asking
 the cache for the built-in shader again, because it knows the answer.

 A pointer this cache never handed out is ignored rather than faulted on. There
 is exactly one caller and it cannot produce one; a fault path here would be an
 unreachable branch in every build.
*>
fn void PipelineCache.retain(&self, MeshPipeline* pipeline)
{
	CachedPipeline* entry = self.entry_for(pipeline);
	if (entry == null) return;
	entry.refs++;
}

<*
 Gives a borrow back.

 Not a free. At zero the entry becomes *evictable*, the same distinction
 `texture.dispose()` draws and for the same reason: the thing goes when nothing
 wants it and the cache has run out of room to be generous, not the instant one
 holder lets go. `MAX_UNUSED_PIPELINES` is where that room is argued.

 @param gpu : `The device the pipeline was built on, for the retire. Null defers the trim to the next release that has one — a pipeline cannot be destroyed without the device that made it, and holding an extra entry is the cheaper half of that trade.`
*>
fn void PipelineCache.release(&self, Gpu* gpu, MeshPipeline* pipeline)
{
	CachedPipeline* entry = self.entry_for(pipeline);
	if (entry == null || entry.refs == 0) return;

	entry.refs--;
	if (entry.refs > 0) return;

	entry.released_at = ++self.clock;
	self.trim(gpu);
}

<*
 Evicts least-recently-released entries until the unused ones fit in the cap.

 Linear in the number of entries, per eviction, which is the right shape here:
 the list is bounded by the cap plus whatever is live, and the alternative — a
 second list threaded in release order — is a second thing to keep in step for a
 scan over a few dozen pointers.
*>
fn void PipelineCache.trim(&self, Gpu* gpu)
{
	if (gpu == null) return;

	while (true)
	{
		uint unused = 0;
		sz oldest   = 0;
		bool found  = false;
		foreach (i, entry : self.entries)
		{
			if (entry.refs > 0) continue;
			unused++;
			if (!found || entry.released_at < self.entries[oldest].released_at)
			{
				oldest = (sz)i;
				found = true;
			}
		}
		if (!found || unused <= MAX_UNUSED_PIPELINES) return;
		self.evict_at(gpu, oldest);
	}
}

<*
 Drops one entry: off the list, into the deletion queue, and its module with it
 if that was the last pipeline holding it.

 The pipeline is copied out before the entry is freed, and retired rather than
 destroyed — a command buffer submitted two frames ago may still bind it.
*>
fn void PipelineCache.evict_at(&self, Gpu* gpu, sz index)
{
	CachedPipeline* entry = self.entries[index];
	self.entries.remove_at(index);

	gpu.retire_pipeline(entry.pipeline);

	CachedModule* compiled = entry.compiled;
	if (compiled != null && compiled.refs > 0)
	{
		compiled.refs--;
		// Freed outright rather than kept warm. A module whose pipelines have all
		// been evicted is SPIR-V for a source nothing draws with, and holding it
		// would leave half of the accumulation still accumulating.
		if (compiled.refs == 0) self.drop_module(compiled);
	}

	mem::free(entry);
	self.evictions++;
}

<*
 Frees a module and takes it off the list. Its last pipeline is already gone.
*>
fn void PipelineCache.drop_module(&self, CachedModule* compiled)
{
	foreach (i, existing : self.modules)
	{
		if (existing != compiled) continue;
		self.modules.remove_at((sz)i);
		break;
	}
	compiled.mod.free();
	if (compiled.source.ptr != null) compiled.source.free(mem);
	mem::free(compiled);
}

fn void PipelineCache.free(&self, Gpu* gpu)
{
	// Pipelines before modules, because a pipeline borrows the module it was built
	// from. Nothing here reads it — the layout was copied, not borrowed — but the
	// order is the one the ownership says, so a future field that does borrow does
	// not become a use-after-free discovered at teardown.
	foreach (entry : self.entries)
	{
		entry.pipeline.free(gpu);
		mem::free(entry);
	}
	self.entries.free();

	foreach (compiled : self.modules)
	{
		compiled.mod.free();
		if (compiled.source.ptr != null) compiled.source.free(mem);
		mem::free(compiled);
	}
	self.modules.free();
	*self = { };
}