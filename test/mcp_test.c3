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
import std::core::test;
import std::io;
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

fn void get_api_docs_describes_the_scripting_api() @test
{
	@with_server(; mcp::Server* server)
	{
		String response = call(server, "get_api_docs", "{}");
		defer response.free(mem);

		test::@check(response.contains("drawCalls"), "the stats block is in there");
		test::@check(response.contains("three.Mesh"), "and the classes");
		test::@check(response.contains("one scene at a time"), "and the divergences: %s", response);
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

		test::@check(!response.contains(`"error"`), "the call succeeded: %s", response);
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
