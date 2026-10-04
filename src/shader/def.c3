<*
 A shader program as the host describes it: the name, and the text.

 The file is the program. A `shaders/*.shady` holds its stage interface, the
 bindings it reads, its spec constants, its entry points and its code, in the
 order a person reads them - and nothing else writes those declarations.

 What this adds is the one part only C3 knows: the wire structs and the push
 block, walked from the structs the host fills (`abi.c3`), so a field added on
 one side and not the other cannot be a read at the wrong offset that nothing
 complains about.

 Nothing here is a preprocessor: no markers, no `#define`s. The half a generator
 supplies - a material's fragment stage, chosen per material at runtime - arrives
 as a function the file *declares* and the spliced text defines, so one module is
 still one program with its two halves written in different places.
*>
module three;

import shady;

<*
 A region of a module's text: a shipped file, or text a caller supplies.
*>
struct ShaderSource
{
	String name;      // what diagnostics call the region: `#line 1 "sky"`
	ShaderFile file;  // the shipped file, or `ShaderFile.NONE` for spliced text
	String source;    // the spliced text, when there is no file
}

<*
 Where a script's uniforms live, which is also whether the module has a set.

 Decided by the builder from the list - `material_spills` is the one place a
 material's answer is made - and read here and by the compile, so the emitted
 region, the push block and the reflected offsets cannot disagree.
*>
enum UniformForm : char
{
	NONE,    // no `Uniforms` and no push member: a pass with nothing declared
	PUSHED,  // the struct is a member of the push block
	SPILLED, // the struct is in a device buffer and the push block points at it
}

<*
 How a script's declared images are spelled in the module.
*>
enum TextureForm : char
{
	NONE,
	MAPS,     // a `Textures` struct of `Map`s, rows of the device-wide table - a material
	SAMPLERS, // a `Sampler2D` per name in the pass's own set - a post pass
}

<*
 Text that fills one of a template's holes - a `@required` or `@fallback`
 function the template's own code calls.

 The text is either whole functions, the hole's among them and helpers beside
 it as the author likes, or only the statements of the hole's body, which the
 def wraps in the hole's signature as the template wrote it. `shady` tells the
 two apart (`defines_functions`); either way every line keeps its own number
 under `region`, so a diagnostic names the line its author typed. Empty text
 fills nothing: a `@fallback` hole keeps its default, and a `@required` one is
 refused at the template.
*>
struct HoleFill
{
	String hole;   // the template's function: "shade", "displace", "post"
	String region; // what diagnostics call the text: "material", "vertex", "post_body"
	String text;
}

<*
 A whole program.

 The wire structs and the push block are written by `append_shader_def` from the
 C3 types the host fills; everything else a module says is in its sources. That
 is the whole split: a declaration the host must agree with is walked rather than
 written twice, and a declaration only the shader cares about - the stage
 interface, a binding it reads, its own entry points - is in the file, where a
 person reading the shader will find it.

 What a script declared - uniforms, images, the text of its holes - is carried
 as the lists themselves rather than as text generated from them, so the one
 emitter writes the region and the compile computes the offsets from the same
 list instead of reading its own output back.
*>
struct ShaderDef
{
	String name;   // diagnostics and cache identity: "sky", "material"

	UniformForm uniform_form;
	MaterialUniform[] uniforms;

	TextureForm texture_form;
	MaterialTexture[] textures;
	uint texture_first; // the table row or binding the first texture gets

	// The module's text, in the order it is written out. A pass whose source is
	// more than one file lists them here - a shared piece first, then the file
	// that is the pass - and the whole of what a reader needs is in them.
	ShaderSource[] sources;

	// The author's text, after every source: whatever it defines is then the
	// second definition of its name, so a clash is reported on the author's line.
	HoleFill[] fills;
}

// --- Emitters ----------------------------------------------------------------

fn uint append_shader_body(DString* out, String body)
{
	uint lines = 0;
	usz  start = 0;
	while (start < body.len)
	{
		usz end = start;
		while (end < body.len && body[end] != '\n') end++;
		usz stop = end;
		if (stop > start && body[stop - 1] == '\r') stop--;
		out.append_string(body[start:stop - start]);
		out.append_char('\n');
		lines++;
		start = end + 1;
	}
	return lines;
}

fn uint shader_lines(String text)
{
	uint lines = 0;
	foreach (c : text) if (c == '\n') lines++;
	return lines;
}

fn void append_shader_source(DString* out, ShaderSource source, String restore_name)
{
	out.append_string("#line 1 \"");
	out.append_string(source.name);
	out.append_string("\"\n");
	append_shader_body(out, source.source);

	uint next = shader_lines(out.str_view()) + 2;
	out.appendf("#line %d \"%s\"\n", (int)next, restore_name);
}

<*
 The whole program: the wire structs, the push block, the stage interface, the
 feature constants, the resources, and the entry points.

 `$Type` is the push block, and it is a type parameter rather than a field of
 `ShaderDef` because a struct cannot hold a type - and the push block is walked
 rather than described, so the layout cannot drift from the C3 struct the pass
 fills.
*>
macro void append_shader_def(DString* out, ShaderDef def, $Type)
{
	append_shader_abi(out);

	// What the generated lines after a body are called. A body is numbered from
	// one under its own name, so the module's own text needs a name of its own
	// for the two to be told apart in a diagnostic.
	String restore = string::tformat("three.%s", def.name);

	// Above the push block, because the push block has a member of it - or a
	// pointer to it, when the set spilled.
	if (def.uniform_form != UniformForm.NONE)
	{
		bool spilled = def.uniform_form == UniformForm.SPILLED;
		DString region;
		region.tinit(256);
		append_shady_uniforms(&region, def.uniforms, spilled);
		append_shader_source(out, { .name = "uniforms", .source = region.str_view() }, restore);
		append_push_block(out, $Type, spilled
			? string::tformat("Uniforms* %s", MATERIAL_TABLE_FIELD)
			: "Uniforms uniforms");
	}
	else
	{
		append_push_block(out, $Type);
	}

	if (def.texture_form != TextureForm.NONE)
	{
		bool maps = def.texture_form == TextureForm.MAPS;
		DString region;
		region.tinit(256);
		append_shady_textures(&region, def.textures, def.texture_first, maps);
		if (region.str_view().len > 0)
		{
			append_shader_source(out, { .name = maps ? "material_textures" : "post_textures", .source = region.str_view() }, restore);
		}
	}

	foreach (source : def.sources)
	{
		// An empty region says nothing and needs no `#line` of its own: a def
		// carries the regions a script may fill whether or not it filled them.
		if (source.file == ShaderFile.NONE)
		{
			if (source.source.len == 0) continue;
			append_shader_source(out, source, restore);
			continue;
		}

		// Read here rather than when the def was written, so a disk edit is seen
		// by the next compile without the def changing.
		append_shader_source(out, { .name = source.name, .source = load_source(source.file, tmem)!! }, restore);
	}

	foreach (fill : def.fills) append_hole_fill(out, def, fill, restore);
}

<*
 One hole's text, after the module it fills.

 Whole functions go in as they are. A bare body is wrapped in the hole's own
 signature, read off the template by `shady::holes`: the signature line and the
 body's first line are both numbered 1 under the region, so a "missing return"
 against the signature and an error on the first statement both read as the
 author's line one. When the template has no such hole the text goes in as it
 is, and the compiler's refusal of a stray `return` is the message.
*>
fn void append_hole_fill(DString* out, ShaderDef def, HoleFill fill, String restore)
{
	if (fill.text.trim().len == 0) return;

	bool? whole = shady::defines_functions(fill.text);
	String signature = "";
	if (try whole && !whole) signature = hole_signature(def, fill.hole);

	if (signature.len == 0)
	{
		append_shader_source(out, { .name = fill.region, .source = fill.text }, restore);
		return;
	}

	out.appendf("#line 1 \"%s\"\n%s\n{\n#line 1 \"%s\"\n", fill.region, signature, fill.region);
	append_shader_body(out, fill.text);
	uint next = shader_lines(out.str_view()) + 2;
	out.appendf("#line %d \"%s\"\n}\n", (int)next, restore);
}

<*
 The signature the def's template gives a hole, or "" when no source declares
 it. Asked of the shipped files only - a hole is the template's, never the
 author's - and only for a bare body, which is the one case that needs it.
*>
fn String hole_signature(ShaderDef def, String hole)
{
	foreach (source : def.sources)
	{
		if (source.file == ShaderFile.NONE) continue;
		String? text = load_source(source.file, tmem);
		if (catch text) continue;
		if (!text.contains("@required") && !text.contains("@fallback")) continue;
		shady::Hole[]? holes = shady::holes(text, tmem);
		if (catch holes) continue;
		foreach (h : holes) if (h.name == hole) return h.signature;
	}
	return "";
}
