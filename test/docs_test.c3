<*
 The Markdown in `docs/` against the API it describes.

	`c3c test --trust=full --test-filter three_tests::docs`

 The folder is the whole of the documentation: nothing compiles it into the
 engine, the MCP points agents at it where it lies, and a release ships it beside
 the binary. So these read the files themselves, the way an agent does, and ask
 the running prelude what there is to document.
*>
module three_tests::docs;

import three;
import std::core::test;
import std::io::file;

macro @with_js(; @body(three::JsRuntime* run))
{
	three::MeshPass pass;
	pass.assets.init();
	pass.init_scenes();
	pass.camera = three::default_camera();
	defer pass.free_scenes();
	defer pass.assets.free(null);

	three::JsRuntime runtime;
	runtime.open(&pass)!!;
	defer runtime.close();

	@body(&runtime);
}

fn String doc(String name)
{
	return (String)file::load_temp(string::tformat("docs/%s", name))!!;
}

fn void the_docs_describe_the_surface() @test
{
	test::@check(doc("stats.md").contains("drawCalls"), "the stats block is described");
	test::@check(doc("differences.md").contains("Exactly one scene is rendered at a time"),
		"and so is every divergence from Three.js");
}

fn void the_docs_describe_the_click() @test
{
	String functions = doc("functions.md");
	test::@check(functions.contains("\n## three.onClick(fn)\n"), "onClick has its own entry");
	test::@check(functions.contains("\n## three.input.pointer\n"), "and so does the pointer it reads");
	test::@check(doc("differences.md").contains("onClick"), "and the differences say how it is not Three.js's");
}

<*
 Every name the API exposes is documented where it belongs.

 A check that the docs contain some string asserts that docs exist rather than
 that they are true: adding `ShaderMaterial` and never mentioning it would pass
 it green. A doc that has silently stopped covering the surface is worth less
 than none, because it is trusted.

 So this asks the surface itself — the module's exports, and every public member
 of every exported class walked off the prototype chain — and requires each to be
 documented *in its own entry*: a class under its own `## Name` in `classes.md`,
 each of its members inside that entry, and everything else in `functions.md`.
 A sweep of the whole folder would be too weak to catch anything: renaming the
 `ShaderMaterial` entry to `_ShaderMaterialUndocumented` still contains the
 string `ShaderMaterial`, and prose in `differences.md` mentioning a class would
 count as documenting it.
*>
fn void the_docs_name_everything_the_api_exposes() @test
{
	DString source;
	source.init(mem, 512 * 1024);
	defer source.free();

	source.append_string("const functions = ");
	three::append_json_string(&source, doc("functions.md"));
	source.append_string(";\nconst classes = ");
	three::append_json_string(&source, doc("classes.md"));
	source.append_string(`;
		// One entry per '## Name' heading: its text is the key, and everything
		// down to the next one is the entry.
		const entries = {};
		for (const part of classes.split(/^## /m).slice(1)) {
			const newline = part.indexOf('\n');
			entries[part.slice(0, newline).trim()] = part.slice(newline);
		}
		const elsewhere = functions + JSON.stringify(Object.keys(entries));

		const members = (ctor) => {
			const out = new Set();
			let p = ctor.prototype;
			while (p && p !== Object.prototype) {
				for (const n of Object.getOwnPropertyNames(p)) {
					if (n !== 'constructor' && !n.startsWith('_')) out.add(n);
				}
				p = Object.getPrototypeOf(p);
			}
			return [...out];
		};

		const missing = [];
		for (const name of Object.keys(three)) {
			const exported = three[name];
			const isClass = typeof exported === 'function' && /^[A-Z]/.test(name);
			if (!isClass) {
				if (!elsewhere.includes(name)) missing.push(name);
				continue;
			}
			const entry = entries[name];
			if (entry === undefined) { missing.push('classes.' + name); continue; }
			for (const m of members(exported)) {
				if (!entry.includes(m)) missing.push(name + '.' + m);
			}
		}
		return missing;
	`);

	@with_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(source.str_view());
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(
			result.value == "[]",
			"every exported name is documented in its own entry; these are not: %s",
			result.value
		);
	};
}
