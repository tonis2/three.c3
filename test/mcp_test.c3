<*
 The three tools, driven over the wire in-process.

	`c3c test --trust=full --test-noleak --test-filter three_tests::mcp`

 **Raw JSON-RPC in, parsed JSON out, no socket and no subprocess.** `plan.md` §5
 asks for exactly this, and the reason is that it makes the whole tool surface
 testable at unit-test speed: `Server.handle_message` is the entire protocol, and
 everything else in `mcp.c3l` is a way of getting bytes to it. A suite that
 spawned a process to check a JSON shape would run in seconds instead of
 milliseconds and would be the first thing skipped.

 The check that matters most is the last one: the §4 example, arriving as a
 string over JSON-RPC, coming back as a PNG plus the stats block. That is M3's
 done condition written out.
*>
module three_tests::mcp;

import three;
import vk;
import image;
import mcp;
import qjs;
import std::core::test;
import std::io;
import std::io::file;
import std::encoding::base64;

const String FIXTURE = "test/fixtures/textured.glb";

<*
 A headless renderer, a JS runtime over it, and a server in front of both.

 `ToolHost` is addressed by pointer and handed to every tool, so it — and the
 renderer and runtime it names — must not move for as long as the server lives.
*>
macro @with_server(; @body(mcp::Server* server))
{
	vk::Instance instance = three::create_instance(false, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 160, 120)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	three::ToolHost host = { .runtime = &runtime, .renderer = &renderer };
	mcp::Server server = three::new_mcp_server(&host);

	@body(&server);
}

<*
 The same server with the validation layer loaded, which is what `--mcp` gives a
 caller by default (`main.c3`, and `plan.md` §4: run the layers whenever a script
 is executing).

 It also installs two host functions of its own. That is the point of the
 fixture: the claim under test is that a validation error *raised by a script*
 becomes that script's error, and asserting it needs something the script can
 call. Installing them from the test rather than putting a hook in `js/runtime.c3`
 keeps the production surface exactly what an agent gets — the functions go in
 the same way `install_console` puts `console` there, through the public context.

 The layer is not on every machine and `create_instance` skips it when it is
 missing, so every check below asks `gpu.validation` first rather than assuming
 there is anything to capture.
*>
macro @with_validating_server(; @body(mcp::Server* server, three::JsRuntime* runtime))
{
	vk::Instance instance = three::create_instance(true, headless: true)!!;
	defer instance.free();

	three::Renderer renderer;
	renderer.init(instance, (vk::SurfaceKHR)null, 160, 120, validate: true)!!;
	defer renderer.free();

	renderer.pass.init(&renderer.gpu, &renderer.target)!!;

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, &renderer)!!;
	defer runtime.close();

	qjs::Value global = runtime.js.global();
	runtime.js.set_property(
		global,
		"provokeValidationError",
		runtime.js.function(&js_provoke_error, "provokeValidationError", 0, &renderer)
	);
	runtime.js.set_property(
		global,
		"provokeValidationWarning",
		runtime.js.function(&js_provoke_warning, "provokeValidationWarning", 0, &renderer)
	);
	runtime.js.release(global);

	three::ToolHost host = { .runtime = &runtime, .renderer = &renderer };
	mcp::Server server = three::new_mcp_server(&host);

	@body(&server, &runtime);
}

<*
 `provokeValidationError()` in a script: a real error from the Khronos layer,
 raised from inside the run.

 A zero-size buffer breaks VUID-VkBufferCreateInfo-size-00912, and the layer
 checks it *before* forwarding the call — so the message is genuine and nothing
 invalid ever reaches the driver. `plan.md` §4's own example of a validation bug
 is a hang; a test suite is the wrong place to find one.
*>
fn void js_provoke_error(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
)
{
	three::Renderer* renderer = (three::Renderer*)opaque;
	vk::Buffer? refused = vk::bufferCreateInfo()
		.setSize(0)
		.setUsage((vk::BufferUsageFlags)vk::BufferUsageFlagBits.BUFFER_USAGE_TRANSFER_SRC_BIT)
		.build(renderer.gpu.handle);
	// The layer refuses it, so there is normally nothing here. Guarded rather
	// than assumed: without the layer the call succeeds and this would leak.
	if (try made = refused) vk::destroyBuffer(renderer.gpu.handle, made, null);
}

<*
 `provokeValidationWarning()` in a script.

 Handed to the loader rather than provoked, because the interesting warnings are
 driver-specific and none of them can be relied on to appear. Going through
 `vkSubmitDebugUtilsMessageEXT` keeps what is under test honest anyway: the
 loader dispatches to registered messengers, so the severity mask and the
 `pUserData` are exercised exactly as a real message would exercise them.
*>
fn void js_provoke_warning(
	qjs::ContextRef ctx,
	qjs::Value* this_val,
	int argc,
	qjs::Value* args,
	void* opaque,
	qjs::Value* out
)
{
	three::Renderer* renderer = (three::Renderer*)opaque;
	ZString id = "THREE-TEST-WARNING";
	ZString text = "advice, not a defect";
	vk::DebugUtilsMessengerCallbackDataEXT data = vk::debugUtilsMessengerCallbackDataEXT()
		.setMessageIdName((char*)id)
		.setMessage((char*)text);
	vk::submitDebugUtilsMessageEXT(
		renderer.gpu.instance,
		vk::DebugUtilsMessageSeverityFlagBitsEXT.DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT,
		(vk::DebugUtilsMessageTypeFlagsEXT)vk::DebugUtilsMessageTypeFlagBitsEXT.DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT,
		&data
	);
}

<*
 One request in, one response out. The response is owned by the caller.
*>
fn String ask(mcp::Server* server, String message, alloc::Allocator allocator = mem)
{
	String raw = server.handle_message(message);
	defer raw.free(mem);
	return raw.copy(allocator);
}

<*
 `tools/call`, with `arguments` supplied as raw JSON.
*>
fn String call(mcp::Server* server, String name, String arguments, alloc::Allocator allocator = mem)
{
	String request = string::tformat(
		`{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"%s","arguments":%s}}`,
		name,
		arguments
	);
	return ask(server, request, allocator);
}

<*
 A script as a `tools/call` arguments object, escaped the way a client would
 have to escape it. Writing this by hand in the test source is how a newline or
 a quote in a script silently becomes a different script.
*>
fn String script_arguments(String source, alloc::Allocator allocator = mem)
{
	DString out;
	out.init(allocator, source.len + 32);
	defer out.free();
	out.append_string(`{"source":"`);
	mcp::json_escape_into(&out, source);
	out.append_string(`"}`);
	return out.copy_str(allocator);
}

<*
 The base64 payload of the response's image block, or the empty string.
*>
fn String image_payload(String response, alloc::Allocator allocator = mem)
{
	// Unescaped: the content array is spliced into the response verbatim, so
	// only the report *inside* the text block is escaped JSON.
	sz? opens = response.index_of(`"data":"`);
	if (catch err = opens) return "".copy(allocator);

	String rest = response[(usz)(opens + 8)..];
	sz? closes = rest.index_of(`"`);
	if (catch err = closes) return "".copy(allocator);
	return rest[:(usz)closes].copy(allocator);
}

// ============================================================================
// The protocol
// ============================================================================

fn void the_server_introduces_itself() @test
{
	@with_server(; mcp::Server* server)
	{
		String response = ask(server, `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{}}}`);
		defer response.free(mem);

		test::@check(response.contains("three.c3"), "it names itself: %s", response);
		test::@check(response.contains(`"id":1`), "and answers the request it was asked");
	};
}

<*
 Three tools, and the count is asserted rather than the names alone.

 `plan.md` §5 is specific that there are three and no more: every scene verb is
 already a JavaScript call, so a fourth tool would be a second spelling of
 something `run_script` can do and one more thing to keep in step.
*>
fn void there_are_exactly_three_tools() @test
{
	@with_server(; mcp::Server* server)
	{
		String response = ask(server, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`);
		defer response.free(mem);

		test::@check(response.contains(`"run_script"`), "run_script is listed");
		test::@check(response.contains(`"screenshot"`), "screenshot is listed");
		test::@check(response.contains(`"get_api_docs"`), "get_api_docs is listed");
		test::@check(count_of(response, `"inputSchema"`) == 3, "and nothing else is: %s", response);
	};
}

fn usz count_of(String haystack, String needle)
{
	usz found = 0;
	usz at = 0;
	while (at + needle.len <= haystack.len)
	{
		if (haystack[at:needle.len] == needle)
		{
			found++;
			at += needle.len;
			continue;
		}
		at++;
	}
	return found;
}

fn void an_unknown_method_is_refused() @test
{
	@with_server(; mcp::Server* server)
	{
		String response = ask(server, `{"jsonrpc":"2.0","id":3,"method":"nonsense"}`);
		defer response.free(mem);

		test::@check(response.contains("-32601"), "answered with method-not-found: %s", response);
	};
}

// ============================================================================
// The tools
// ============================================================================

<*
 A bare ask is the index: everything short, and the names of everything long.

 The whole object is about 113 KB, which is thirty thousand tokens spent before
 a line is written, so the default answer carries the sections that are read
 every time — the differences, the stats block, the examples — and turns the 83
 KB of class and function prose into a list of names. `three.load(path)`'s note
 is the marker for that prose: it is in the dump and must not be in the index.
*>
fn void get_api_docs_answers_with_an_index() @test
{
	@with_server(; mcp::Server* server)
	{
		String response = call(server, "get_api_docs", "{}");
		defer response.free(mem);

		test::@check(response.contains("drawCalls"), "the stats block is in there");
		test::@check(response.contains("three.Mesh"), "and the differences");
		test::@check(response.contains("one scene at a time"), "and the divergences: %s", response);
		test::@check(response.contains("ShaderMaterial"), "the class NAMES are there");
		test::@check(
			!response.contains("Read a .glb or .gltf"),
			"but not the prose behind them: %s",
			response
		);
		test::@check(response.contains("This is the INDEX"), "and it says so, with how to ask again");
	};
}

<*
 `all` is the old answer, whole, for a caller with the room for it.
*>
fn void get_api_docs_still_dumps_everything_when_asked() @test
{
	@with_server(; mcp::Server* server)
	{
		String response = call(server, "get_api_docs", `{"all":true}`);
		defer response.free(mem);

		test::@check(response.contains("Read a .glb or .gltf"), "the function prose is in there");
		test::@check(response.contains("drawCalls"), "and the stats block: %s", response[:512]);
	};
}

<*
 `search` is the grep the embedded docs otherwise cannot have.

 Hits are keyed by the path `section` takes, so an answer is both the fact and
 the way to ask for its neighbours. The check that matters is the negative one:
 a narrow search must not quietly become the dump again.
*>
fn void get_api_docs_searches_the_whole_surface() @test
{
	@with_server(; mcp::Server* server)
	{
		String response = call(server, "get_api_docs", `{"search":"convex hull"}`);
		defer response.free(mem);

		test::@check(response.contains("classes.ConvexGeometry"), "the class is a hit");
		test::@check(response.contains("differences.convex-geometry"), "and so is the difference");
		test::@check(response.contains("the bound of a scan"), "with the prose, not just the name");
		test::@check(
			!response.contains("Read a .glb or .gltf"),
			"and nothing that does not match: %s",
			response
		);
	};
}

<*
 `section` opens one name — by its path, or by the bare name read off the index.
*>
fn void get_api_docs_opens_one_section() @test
{
	@with_server(; mcp::Server* server)
	{
		String full = call(server, "get_api_docs", `{"section":"classes.ConvexGeometry"}`);
		defer full.free(mem);
		test::@check(full.contains("the bound of a scan"), "the entry came back: %s", full);
		test::@check(!full.contains("drawCalls"), "and only that entry");

		// The name as the index spells it, which is the name an agent has just
		// read when it asks.
		String bare = call(server, "get_api_docs", `{"section":"ConvexGeometry"}`);
		defer bare.free(mem);
		test::@check(bare.contains("classes.ConvexGeometry"), "a bare name resolves: %s", bare);

		String missing = call(server, "get_api_docs", `{"section":"NoSuchThing"}`);
		defer missing.free(mem);
		test::@check(missing.contains("No entry by that name"), "and a miss says so: %s", missing);
	};
}

<*
 `path` puts the docs on disk, which is the other half of being greppable.

 The answer is the path and the size rather than the docs: handing back 113 KB
 beside "it is in a file you can grep" would undo the reason for the file.
*>
fn void get_api_docs_writes_a_file_to_grep() @test
{
	String path = "build/api_docs.md";
	defer (void)file::delete(path);

	@with_server(; mcp::Server* server)
	{
		String response = call(server, "get_api_docs", `{"path":"build/api_docs.md"}`);
		defer response.free(mem);

		test::@check(response.contains(path), "the answer names the file: %s", response);
		test::@check(!response.contains("Read a .glb or .gltf"), "and is not the docs themselves");

		char[]? written = file::load(mem, path);
		test::@check(@ok(written), "the file is there");
		if (try bytes = written)
		{
			defer free(bytes);
			String markdown = (String)bytes;
			test::@check(markdown.contains("### classes.ConvexGeometry"), "one heading per entry");
			test::@check(markdown.contains("the bound of a scan"), "with the prose under it");
			test::@check(markdown.contains("Read a .glb or .gltf"), "and the whole surface in it");
		}
	};
}

<*
 M3's done condition (`plan.md` §5): the tier-1 example arrives over JSON-RPC as
 a string, runs, and comes back as a PNG plus the stats block.

 The example is §4's, with one change: `camera` is spelled `three.camera`, because
 §4's snippet uses a `camera` it never declares.
*>
fn void the_tier_one_example_arrives_as_a_string_and_comes_back_as_a_png() @test
{
	@with_server(; mcp::Server* server)
	{
		String source = `
			const kit  = await three.load("test/fixtures/textured.glb");
			const wall = kit.mesh(kit.meshes[0]);

			const scene = new three.Scene();
			for (let i = 0; i < 12; i++) {
			  const m = new three.Mesh(wall);
			  m.position.set(i * 2, 0, 0);
			  m.rotation.y = Math.PI / 2;
			  scene.add(m);
			}
			three.camera.frameAll();
			three.render(scene, three.camera);
			console.log(scene.stats());
		`;

		String arguments = script_arguments(source);
		defer arguments.free(mem);

		String response = call(server, "run_script", arguments);
		defer response.free(mem);

		// Escaped, because the report is a JSON string inside the content array
		// and its keys arrive as `\"error\"`. Spelled `"error"` this never
		// matched anything and the check was decoration.
		test::@check(!response.contains(`\"error\"`), "the call succeeded: %s", response);
		test::@check(response.contains(`\"drawCalls\":1`), "one draw call in the stats block: %s", response);
		test::@check(response.contains(`\"instances\":12`), "twelve instances");
		test::@check(response.contains(`\"ok\":true`), "and the run reported success");

		// The log is one of the four things a run always answers with, and this
		// is the example's own console.log arriving back.
		test::@check(response.contains(`\"log\"`), "the log came back too");

		String payload = image_payload(response);
		defer payload.free(mem);
		test::@check(payload.len > 0, "there is an image block");

		// Decoded rather than trusted: a base64 field carrying the characters of
		// nothing would satisfy every check above.
		char[]? bytes = base64::decode(mem, (char[])payload);
		if (try png = bytes)
		{
			defer alloc::free(mem, png);
			test::@check(png.len > 8, "the PNG has content");
			test::@check(
				png[0] == 0x89 && png[1] == 'P' && png[2] == 'N' && png[3] == 'G',
				"and it really is a PNG"
			);
		}
		else
		{
			test::@check(false, "the image block decodes as base64");
		}
	};
}

<*
 A failed script still answers with all four (`plan.md` §4).

 The one that is easy to get wrong is the log: a throw halfway through a script
 that logged its progress is exactly when the log is worth the most, and it is
 also exactly when an implementation that builds the report after the error path
 would drop it.
*>
fn void a_failed_script_still_returns_its_log_and_a_frame() @test
{
	@with_server(; mcp::Server* server)
	{
		String arguments = script_arguments(`console.log("built the scene"); throw new Error("then this");`);
		defer arguments.free(mem);

		String response = call(server, "run_script", arguments);
		defer response.free(mem);

		test::@check(response.contains(`\"ok\":false`), "the run reported failure: %s", response);
		test::@check(response.contains("built the scene"), "the log survived");
		test::@check(response.contains("then this"), "the message is there");

		String payload = image_payload(response);
		defer payload.free(mem);
		test::@check(payload.len > 0, "and a frame came back anyway");
	};
}

fn void a_call_with_no_source_says_what_it_wanted() @test
{
	@with_server(; mcp::Server* server)
	{
		String response = call(server, "run_script", "{}");
		defer response.free(mem);

		test::@check(response.contains("source"), "the missing argument is named: %s", response);
	};
}

// ============================================================================
// The command line: what it takes, and what it no longer takes
// ============================================================================

<*
 The validation flags are gone, and a line that still names one is refused.

 `--validate` and `--no-validate` used to be here, and `--mcp` used to imply the
 first of them in a debug build. All three went when the layers became a property
 of the build — `src/debug.c3` carries the argument and the 2x it costs. So did
 `--shader <path>`, which could only ever name one of the five templates
 `find_shader` looks up; `src/shader/load.c3` has that one.

 What is pinned here is not that they are absent, which nothing can observe, but
 that their absence is **loud**. A `.mcp.json`, a shell alias or a run script
 written before the change still carries the flag, and the two ways of meeting it
 are not close: refused, it stops with usage printed and the line gets fixed;
 ignored, a debug build validates when the line asked it not to, at the 2x, with
 nothing on screen to point at.

 The control line first, because a test that only checks for refusals passes just
 as well against a `parse_args` that refuses everything.

 **Proved by injection**, once per flag, since one `default:` arm serves all
 three and only a per-flag check says all three reach it. `case "--validate":`
 added back as a no-op: "--validate was accepted rather than refused". The same
 for `case "--no-validate":`: "--no-validate was accepted rather than refused".
 And `case "--shader":` restored with its value consumed: "--shader was accepted
 rather than refused".
*>
fn void the_flags_that_went_are_refused_rather_than_ignored() @test
{
	String[*] control = { "three", "--mcp", "--headless" };
	three::Options fine = three::parse_args(control[..])!!;
	test::@check(fine.headless, "the control line was not understood");
	test::@check(fine.mcp_port > 0, "the control line asked for no server");

	String[*] off = { "three", "--mcp", "--no-validate", "--headless" };
	three::Options? refused_off = three::parse_args(off[..]);
	test::@check(@catch(refused_off), "--no-validate was accepted rather than refused");

	String[*] on = { "three", "--validate" };
	three::Options? refused_on = three::parse_args(on[..]);
	test::@check(@catch(refused_on), "--validate was accepted rather than refused");

	// With a value after it, which is the shape that was removed — a `--shader`
	// refused only when bare would still swallow the path beside it.
	String[*] pointed = { "three", "--shader", "shaders/mesh.slang" };
	three::Options? refused_shader = three::parse_args(pointed[..]);
	test::@check(@catch(refused_shader), "--shader was accepted rather than refused");
}

<*
 `--script` takes a file, and takes it beside everything else on the line.

 The flag exists so a person can run what an agent would paste into
 `run_script`, and the three cases below are the three shapes that has: alone,
 which is the whole point; with `--mcp`, where the boot happens and *then* the
 server comes up over the scene it built; and beside a model, which is the trap
 `--mcp` already documents from the other side — a flag that swallowed the
 positional argument would boot the script and then report no file.
*>
fn void the_script_flag_names_a_file_beside_everything_else() @test
{
	String[*] alone = { "three", "--script", "examples/vfx.js" };
	three::Options only = three::parse_args(alone[..])!!;
	test::@check(only.script == "examples/vfx.js", "--script kept '%s'", only.script);
	test::@check(only.mcp_port == 0, "and asked for no server, got %d", only.mcp_port);

	String[*] served = { "three", "--mcp", "--script", "examples/vfx.js" };
	three::Options both = three::parse_args(served[..])!!;
	test::@check(both.script == "examples/vfx.js" && both.mcp_port > 0, "--mcp --script does both");

	String[*] with_model = { "three", "--script", "boot.js", "model.glb" };
	three::Options kept = three::parse_args(with_model[..])!!;
	test::@check(kept.script == "boot.js", "the script is '%s'", kept.script);
	test::@check(kept.model == "model.glb", "and the model is '%s'", kept.model);

	// A value it has no way to invent. The alternative — treating a bare
	// `--script` as "no script" — is a command line that opens the built-in
	// triangle and says nothing about why.
	String[*] naked = { "three", "--script" };
	three::Options? refused = three::parse_args(naked[..]);
	test::@check(@catch(refused), "a --script with no file is refused");
}

// ============================================================================
// The stdio relay, which is what a client actually launches
// ============================================================================

<*
 `--mcp-stdio` names a port however it is written.

 The flag's whole job is to reach the port the *other* process bound, and
 getting that wrong fails in the one way that is hard to read: a relay pointed
 at 8808 while three serves on 9100 answers the handshake perfectly — the
 catalog does not need the application — and then fails every call after it,
 which looks like a broken tool rather than like a mistyped port.

 The last case is the trap `--mcp` already documents. The port is optional, so a
 following argument is consumed only when it really is one; without that,
 `three --mcp-stdio model.glb` would relay to nowhere and report no file.
*>
fn void the_relay_flag_names_a_port_in_every_order() @test
{
	String[*] bare = { "three", "--mcp-stdio" };
	three::Options plain = three::parse_args(bare[..])!!;
	test::@check(plain.relay_stdio, "--mcp-stdio did not ask for the relay");
	test::@check(
		plain.mcp_port == three::DEFAULT_MCP_PORT,
		"a bare --mcp-stdio relays to %d rather than the default", plain.mcp_port
	);

	String[*] after = { "three", "--mcp", "9100", "--mcp-stdio" };
	three::Options follows = three::parse_args(after[..])!!;
	test::@check(follows.relay_stdio && follows.mcp_port == 9100, "--mcp 9100 --mcp-stdio went to %d", follows.mcp_port);

	String[*] before = { "three", "--mcp-stdio", "--mcp", "9200" };
	three::Options precedes = three::parse_args(before[..])!!;
	test::@check(precedes.relay_stdio && precedes.mcp_port == 9200, "--mcp-stdio --mcp 9200 went to %d", precedes.mcp_port);

	String[*] own = { "three", "--mcp-stdio", "9300" };
	three::Options carried = three::parse_args(own[..])!!;
	test::@check(carried.relay_stdio && carried.mcp_port == 9300, "--mcp-stdio 9300 went to %d", carried.mcp_port);

	String[*] with_model = { "three", "--mcp-stdio", "model.glb" };
	three::Options kept = three::parse_args(with_model[..])!!;
	test::@check(kept.model == "model.glb", "--mcp-stdio swallowed the model: '%s'", kept.model);
	test::@check(kept.mcp_port == three::DEFAULT_MCP_PORT, "and left the port at %d", kept.mcp_port);
}

<*
 A validation error raised by the script fails the run and arrives as the run's
 error.

 This is `plan.md` §4's "routes validation errors into the thrown JS exception",
 asserted on the thing rather than on the flag: nothing in JavaScript threw, and
 the run still has to come back failed with the layer's own words in it.

 `value` is checked alongside, because §4's other rule is that a run answers with
 all four whatever happened. A validation failure that threw away what the script
 returned would be the same "guess how far it got" the whole contract exists to
 remove.
*>
fn void a_validation_error_from_a_script_fails_the_run() @test
{
	@with_validating_server(; mcp::Server* server, three::JsRuntime* runtime)
	{
		if (!runtime.renderer.gpu.validation)
		{
			io::printn("  (skipped: VK_LAYER_KHRONOS_validation is not installed)");
			return;
		}

		three::RunResult result = runtime.run(`provokeValidationError(); return 7;`);
		defer result.free();

		test::@check(!result.ok, "the run reported success anyway: error=%s", result.error);
		test::@check(
			result.error.contains("VUID-VkBufferCreateInfo-size"),
			"the layer's own VUID is the error: %s",
			result.error
		);
		test::@check(result.error.contains("validation ERROR"), "with its severity: %s", result.error);
		test::@check(result.value == "7", "and the script's value survived: %s", result.value);
	};
}

<*
 The same error, all the way out through `run_script`.

 The last link in the chain and the only one an agent actually sees. It is
 asserted separately from the `RunResult` check above because the report only
 emits `error` when the run failed — so an implementation that captured the
 message and left `ok` alone would pass that check and drop the text here.
*>
fn void a_validation_error_comes_back_through_run_script() @test
{
	@with_validating_server(; mcp::Server* server, three::JsRuntime* runtime)
	{
		if (!runtime.renderer.gpu.validation) return;

		String arguments = script_arguments(`console.log("built the scene"); provokeValidationError();`);
		defer arguments.free(mem);

		String response = call(server, "run_script", arguments);
		defer response.free(mem);

		test::@check(response.contains(`\"ok\":false`), "the run reported failure: %s", response);
		test::@check(response.contains(`\"error\"`), "and the reply has an error field");
		test::@check(response.contains("VUID-VkBufferCreateInfo-size"), "carrying the VUID: %s", response);
		test::@check(response.contains("built the scene"), "and the log came back too");

		String payload = image_payload(response);
		defer payload.free(mem);
		test::@check(payload.len > 0, "and a frame, as a failed run always does");
	};
}

<*
 A run that did nothing wrong does not acquire an error from the layer being on.

 The check that keeps this feature honest. A messenger that captured the frame
 *before* it, or a sink that was never cleared, both show up as a clean script
 failing — and a false validation error is worse than none, because the agent
 goes looking for a bug that is not there.
*>
fn void a_clean_script_gains_no_validation_error() @test
{
	@with_validating_server(; mcp::Server* server, three::JsRuntime* runtime)
	{
		if (!runtime.renderer.gpu.validation) return;

		// The tier-one example, not an empty scene. A clean render is the claim,
		// and it is only worth making about the path that actually uploads
		// geometry and a texture and issues an instanced draw — an empty scene
		// records nothing and would hold however broken the draw was.
		String arguments = script_arguments(`
			const kit  = await three.load("test/fixtures/textured.glb");
			const wall = kit.mesh(kit.meshes[0]);
			const scene = new three.Scene();
			for (let i = 0; i < 12; i++) {
			  const m = new three.Mesh(wall);
			  m.position.set(i * 2, 0, 0);
			  scene.add(m);
			}
			three.camera.frameAll();
			three.render(scene, three.camera);
			return "fine";
		`);
		defer arguments.free(mem);

		String response = call(server, "run_script", arguments);
		defer response.free(mem);

		test::@check(response.contains(`\"ok\":true`), "the clean run succeeded: %s", response);
		test::@check(!response.contains(`\"error\"`), "and gained no error: %s", response);
	};
}

<*
 A warning is logged and the run still succeeds.

 Warnings and errors are answered with differently on purpose: an agent that
 cannot tell advice from a defect stops believing either, and a PERFORMANCE
 warning failing a run would make the layer unusable to leave on. So the text has
 to be somewhere it can be read, and `ok` has to stay true.
*>
fn void a_validation_warning_is_logged_without_failing_the_run() @test
{
	@with_validating_server(; mcp::Server* server, three::JsRuntime* runtime)
	{
		if (!runtime.renderer.gpu.validation) return;

		String arguments = script_arguments(`provokeValidationWarning(); return "fine";`);
		defer arguments.free(mem);

		String response = call(server, "run_script", arguments);
		defer response.free(mem);

		test::@check(response.contains(`\"ok\":true`), "a warning did not fail the run: %s", response);
		test::@check(!response.contains(`\"error\"`), "and produced no error field: %s", response);
		test::@check(response.contains("THREE-TEST-WARNING"), "and it is in the log where it can be read: %s", response);
		test::@check(response.contains("validation WARNING"), "labelled as advice, not a defect");
	};
}

<*
 A script that threw *and* tripped validation keeps both.

 The two are different facts and the second rarely explains the first. Replacing
 the script's own message with the layer's would hand the agent a Vulkan VUID for
 a plain TypeError three lines earlier, which is a worse error than either.
*>
fn void a_script_that_threw_keeps_its_own_error_beside_the_validation_one() @test
{
	@with_validating_server(; mcp::Server* server, three::JsRuntime* runtime)
	{
		if (!runtime.renderer.gpu.validation) return;

		three::RunResult result = runtime.run(
			`provokeValidationError(); throw new Error("the script had its own complaint");`
		);
		defer result.free();

		test::@check(!result.ok, "the run failed");
		test::@check(
			result.error.contains("the script had its own complaint"),
			"the script's message survived: %s",
			result.error
		);
		test::@check(
			result.error.contains("VUID-VkBufferCreateInfo-size"),
			"and the layer's is there too: %s",
			result.error
		);
	};
}

fn void screenshot_returns_a_png_of_the_scene() @test
{
	@with_server(; mcp::Server* server)
	{
		String build = script_arguments(`
			const kit = three.load("test/fixtures/textured.glb");
			const scene = new three.Scene();
			scene.add(new three.Mesh(kit.meshAt(0)));
			three.camera.frameAll();
		`);
		defer build.free(mem);
		String built = call(server, "run_script", build);
		defer built.free(mem);
		test::@check(built.contains(`\"ok\":true`), "the scene was built: %s", built);

		String response = call(server, "screenshot", "{}");
		defer response.free(mem);

		test::@check(response.contains(`\"width\":160`), "the frame is the target's size: %s", response);

		String payload = image_payload(response);
		defer payload.free(mem);
		test::@check(payload.len > 0, "and there is an image");
	};
}
