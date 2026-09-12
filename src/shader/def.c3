<*
 A shader program as the host describes it.

 The old flow wrote the declarations into the shader text and spliced the host's
 values in with markers and `#define`s: the push block, the resources and the
 feature flags existed twice, once in C3 and once in Slang. This is the other
 half of that: the program is written from C3, and the only text that arrives
 from outside is code - the ported shading library, and the body a script wrote.

 What a def carries, and where each part used to be:

  - the wire structs, from `abi.c3` (were written in every shader file);
  - the push block, from a C3 struct (was written in every shader file);
  - descriptors with their set and binding (were written in the shader file, or
    numbered by the assembler's constants);
  - feature constants (were `#define`s the assembler emitted and `#ifdef`ed
    around whole functions);
  - stage IO (was written in the shader file);
  - entry points with the body injected (were templates with marker lines).

 Nothing here is a preprocessor. A feature is a specialization constant rather
 than a macro, so the same module serves every value of it; a body is text
 spliced once, so it cannot rewrite a name it never wrote.
*>
module three;

<*
 Which stage an entry point is.
*>
enum ShaderStageKind : char
{
	VERTEX,
	FRAGMENT,
	COMPUTE,
}

<*
 One descriptor: what it is, what it is called, and where it is bound.

 `type` is the shady spelling - `Sampler2D`, `texture2d`, `sampler`,
 `Sampler2DShadow`. `runtime_array` is the bindless table, whose length comes
 from the device rather than from the shader.
*>
struct ShaderResource
{
	String name;
	String type;
	uint   set;
	uint   binding;
	bool   runtime_array;
}

<*
 One feature knob: a value the host may set when the pipeline is created.

 Scalars only, as `@spec` is: a boolean gates a pass, a uint bounds a loop, a
 float scales a kernel. Anything that changes the interface - a descriptor, a
 varying, an entry point - is a different module instead; see the variant policy
 in `shader_plan.md`.
*>
struct ShaderFeature
{
	String name;
	String type;   // bool, uint, int, float
	String value;  // the default, as the shader source writes it
	uint   id;
}

<*
 One member of a struct the generator writes rather than walks.

 Stage IO is the shader's own vocabulary - nothing on the CPU side names a
 `VertexOutput` - so there is no C3 struct to walk and the def describes it.
 `type` is the shady spelling; `attribute` is `@position`, `@builtin(name)`,
 `@flat`, or empty.
*>
struct ShaderIoField
{
	String name;
	String type;
	String attribute;
}

struct ShaderIo
{
	String name;
	ShaderIoField[] fields;
}

<*
 One entry point: its interface, its code, and what a diagnostic calls the code.

 `body` is text - the ported shading code, or the body a script wrote. The
 signature around it is generated, and the `#line` before it is what makes an
 error inside it name the file its author wrote rather than this module.
*>
struct ShaderStage
{
	ShaderStageKind kind;
	String entry;      // "vertexMain"
	String input;      // the parameter list, as written: "VertexOutput input"
	String returns;    // "VertexOutput", "float4", "void"
	String body;
	String body_name;  // what `#line` calls the body: "sky", "material"
	String threads;    // compute only: "64, 1, 1"
}

<*
 A whole program.
*>
struct ShaderDef
{
	String name;   // diagnostics and cache identity: "sky", "material"
	ShaderIo[]   io;
	ShaderResource[] resources;
	ShaderFeature[]  features;
	ShaderStage[]    stages;
}

// --- Emitters ----------------------------------------------------------------

fn void append_shader_io(DString* out, ShaderIo io)
{
	out.append_string("struct ");
	out.append_string(io.name);
	out.append_string("\n{\n");
	foreach (field : io.fields)
	{
		out.append_char('\t');
		out.append_string(field.type);
		out.append_char(' ');
		out.append_string(field.name);
		if (field.attribute.len)
		{
			out.append_char(' ');
			out.append_string(field.attribute);
		}
		out.append_string(";\n");
	}
	out.append_string("}\n");
}

fn void append_shader_features(DString* out, ShaderFeature[] features)
{
	foreach (feature : features)
	{
		out.append_string("const ");
		out.append_string(feature.type);
		out.append_char(' ');
		out.append_string(feature.name);
		out.appendf(" @spec(%d) = ", (int)feature.id);
		out.append_string(feature.value);
		out.append_string(";\n");
	}
}

fn void append_shader_resources(DString* out, ShaderResource[] resources)
{
	foreach (resource : resources)
	{
		out.append_string(resource.type);
		out.append_char(' ');
		out.append_string(resource.name);
		if (resource.runtime_array) out.append_string("[]");
		out.appendf(" @set(%d) @binding(%d);\n", (int)resource.set, (int)resource.binding);
	}
}

<*
 Append a body line by line, normalising the ending, and say how many lines that
 was.

 The count is the point: `#line` restores numbering by absolute line, so the
 generator has to know exactly how tall the body it just wrote is - and a body
 that arrived without a trailing newline, or with a `\r` on every line because
 it was authored on Windows, must not change the answer. `assemble.c3` counted
 for the same reason; the difference is that counting here is the only case
 that exists rather than one of several.
*>
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

<*
 One entry point: the signature and the stage attribute from the def, the body
 as it arrived.

 The body is bracketed by `#line` directives - a body of its own numbered from
 one, then back to the module's numbering - so a fault inside ported or
 script-written code is reported where its author wrote it. The restore number
 is counted rather than computed from a template's shape, which is what makes it
 right for a body of any height.
*>
fn void append_shader_stage(DString* out, ShaderStage stage, String restore_name)
{
	out.append_string("fn ");
	out.append_string(stage.returns);
	out.append_char(' ');
	out.append_string(stage.entry);
	out.append_char('(');
	out.append_string(stage.input);
	out.append_string(") ");

	switch (stage.kind)
	{
		case VERTEX:
			out.append_string("@vertex");
		case FRAGMENT:
			out.append_string("@fragment");
		case COMPUTE:
			out.append_string("@compute");
			if (stage.threads.len)
			{
				out.append_string(" @threads(");
				out.append_string(stage.threads);
				out.append_char(')');
			}
	}
	out.append_string("\n{\n");

	out.append_string("#line 1 \"");
	out.append_string(stage.body_name);
	out.append_string("\"\n");
	append_shader_body(out, stage.body);

	uint next = shader_lines(out.str_view()) + 2;
	out.appendf("#line %d \"%s\"\n", (int)next, restore_name);
	out.append_string("}\n");
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

	foreach (io : def.io) append_shader_io(out, io);
	append_shader_features(out, def.features);
	append_shader_resources(out, def.resources);

	// What the generated lines after a body are called. A body is numbered from
	// one under its own name, so the module's own text needs a name of its own
	// for the two to be told apart in a diagnostic.
	String restore = string::tformat("three.%s", def.name);
	foreach (stage : def.stages) append_shader_stage(out, stage, restore);
}
