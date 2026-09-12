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
 A piece of the module's text, and what a diagnostic should call it.
*>
struct ShaderSource
{
	String name;
	String source;
}

<*
 A whole program.

 The wire structs and the push block are written by `append_shader_def` from the
 C3 types the host fills; everything else a module says is in its sources. That
 is the whole split: a declaration the host must agree with is walked rather than
 written twice, and a declaration only the shader cares about - the stage
 interface, a binding it reads, its own entry points - is in the file, where a
 person reading the shader will find it.
*>
struct ShaderDef
{
	String name;   // diagnostics and cache identity: "sky", "material"

	// The module's text, in the order it is written out. A pass whose source is
	// more than one file lists them here - a shared piece first, then the file
	// that is the pass - and the whole of what a reader needs is in them.
	ShaderSource[] sources;
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
	append_push_block(out, $Type);

	// What the generated lines after a body are called. A body is numbered from
	// one under its own name, so the module's own text needs a name of its own
	// for the two to be told apart in a diagnostic.
	String restore = string::tformat("three.%s", def.name);
	foreach (source : def.sources) append_shader_source(out, source, restore);
}
