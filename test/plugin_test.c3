<*
 The ABI's JavaScript group, exercised the way a plugin exercises it.

 `plugin_abi.md` §8 and `plugin_plan.md` item 4. Nothing here loads a `.dylib`:
 `engine_api` is the same table `three_plugin_main` is handed, and calling
 through it is what a plugin does — so a test that fills its own verbs and reads
 its own arguments is the ABI under test rather than a mock of it.

 The one thing a real plugin has that these do not is a separate image, and that
 is exactly the thing these checks are not about. What they are about is the
 contract: a borrow that lasts one call, a copy that ends the conversation, a
 share that has to be dropped.
*>
module three_tests::plugin;

import std::io;
import three;
import three_abi;

// The plugin's own memory, in the only place a test has one: a module static.
// Two arrays rather than one so a check can prove a share is the plugin's
// storage and a copy is not.
float[4] owned = { 1.5, 2.5, 3.5, 4.5 };
float[4] scratch;

// What a verb saw, so a check can assert on the C3 side of the call as well as
// on the JavaScript side.
usz seen_bytes;
bool seen_null;
double summed;

<*
 A runtime with the host table filled and a plugin's verbs installable.

 `plugin_js_ready(null, ...)` is the whole of what a plugin's `install_js` needs
 from the host: it publishes the runtime the verbs will hang off. Passing null
 for the plugin skips the parts that need a loaded image — its scripts directory
 and its entry module — and leaves precisely the part under test.
*>
macro void @with_runtime(;@body(runtime))
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();

	three::plugin_js_ready(null, &runtime);
	// Frees the verb records and the shared-buffer list. Before `close` would
	// also be correct; after it is what a real run does, and the point of
	// `drop_plugin_verbs` forgetting rather than detaching is that both work.
	defer three::plugin_js_closed();

	@body(&runtime);
}

// ------------------------------------------------------------- arguments

// Sums a Float32Array argument. The shape every packing verb has: borrow, read,
// answer a number.
fn void js_sum(void* user, three_abi::JsCall call, int argc) @local
{
	char* bytes = null;
	usz len = three::engine_api.js_arg_buffer(call, 0, &bytes);

	seen_bytes = len;
	seen_null = bytes == null;

	double total = 0;
	if (bytes != null)
	{
		float[] values = ((float*)bytes)[:len / @sizeof(owned[0])];
		foreach (value : values) total += (double)value;
	}
	summed = total;
	three::engine_api.js_return_number(call, total);
}

<*
 A typed array crosses as bytes, and a view crosses as its own bytes.

 The subarray is the check that matters: a plugin handed the buffer underneath a
 view rather than the view would read the right length from the wrong place, and
 every number would be plausible.
*>
fn void a_typed_array_argument_crosses_as_bytes() @test
{
	@with_runtime(; three::JsRuntime* runtime)
	{
		three::engine_api.js_define("probe", "sum", 1, &js_sum, null);

		three::RunResult all = runtime.run("return probe.sum(new Float32Array([1, 2, 3, 4]));");
		defer all.free();
		test::@check(all.ok, "the verb runs (%s)", all.error);
		test::@check(all.value == "10", "four floats summed to 10, got %s", all.value);
		test::@check(seen_bytes == 16, "sixteen bytes crossed, got %d", seen_bytes);

		three::RunResult part = runtime.run(
			"return probe.sum(new Float32Array([1, 2, 3, 4, 5]).subarray(2));"
		);
		defer part.free();
		test::@check(part.value == "12", "a view is its own three elements, got %s", part.value);
		test::@check(seen_bytes == 12, "and its own twelve bytes, got %d", seen_bytes);
	};
}

<*
 Anything without contiguous bytes is no bytes, and says so quietly.

 The same answer `js_arg_number` gives for a string and `js_arg_text` gives for a
 number: zero, no exception, and the verb decides whether that is a problem. A
 plain `Array` is the case worth naming — it is what a script reaches for
 instead of a `Float32Array`, and answering with something for it would be
 answering with garbage.
*>
fn void what_is_not_a_buffer_is_no_bytes() @test
{
	@with_runtime(; three::JsRuntime* runtime)
	{
		three::engine_api.js_define("probe", "sum", 1, &js_sum, null);

		String[4] sources = { "[1, 2, 3]", "'abc'", "42", "undefined" };
		foreach (source : sources)
		{
			@pool()
			{
				three::RunResult ran = runtime.run(string::tformat("return probe.sum(%s);", source));
				defer ran.free();
				test::@check(ran.ok, "%s does not throw (%s)", source, ran.error);
				test::@check(seen_bytes == 0, "%s has no bytes, got %d", source, seen_bytes);
				test::@check(seen_null, "%s leaves the pointer null", source);
			};
		}

		// A missing argument is the same answer as a wrong one, which is what
		// lets a verb read argument 3 of a two-argument call without checking
		// `argc` first.
		three::RunResult none = runtime.run("return probe.sum();");
		defer none.free();
		test::@check(none.ok && seen_bytes == 0, "a missing argument reads as none");
	};
}

// ------------------------------------------------------------- answers

// Answers a copy of the plugin's scratch, which it is free to reuse afterwards.
fn void js_copy(void* user, three_abi::JsCall call, int argc) @local
{
	scratch = { 10, 20, 30, 40 };
	three::engine_api.js_return_buffer(
		call, (char*)&scratch[0], @sizeof(scratch), three_abi::BUFFER_F32, false
	);
	// The whole claim of the copy path: the plugin's memory is its own again
	// the moment the verb returns, and the script's array does not follow it.
	scratch = { 0, 0, 0, 0 };
}

// Answers a view over the plugin's real storage.
fn void js_share(void* user, three_abi::JsCall call, int argc) @local
{
	three::engine_api.js_return_buffer(
		call, (char*)&owned[0], @sizeof(owned), three_abi::BUFFER_F32, true
	);
}

<*
 A copy is the script's own array: it does not see the plugin afterwards, and
 the plugin does not see it.

 Both halves are the point. `js_copy` overwrites its scratch immediately after
 answering, so an array that tracked it would read zeroes.
*>
fn void a_copied_answer_belongs_to_the_script() @test
{
	@with_runtime(; three::JsRuntime* runtime)
	{
		three::engine_api.js_define("probe", "copy", 0, &js_copy, null);

		three::RunResult read = runtime.run("return Array.from(probe.copy());");
		defer read.free();
		test::@check(read.value == "[10,20,30,40]",
			"the copy carries the values it was made from, got %s", read.value);

		three::RunResult typed = runtime.run("return probe.copy().constructor.name;");
		defer typed.free();
		test::@check(typed.value == "\"Float32Array\"",
			"and it is the kind that was asked for, got %s", typed.value);

		// Writable, because it is nobody else's. A frozen copy would be
		// protecting memory that no longer has an owner to protect.
		three::RunResult written = runtime.run(
			"const a = probe.copy(); a[0] = 99; return a[0];"
		);
		defer written.free();
		test::@check(written.value == "99", "and the script may write it, got %s", written.value);
	};
}

<*
 A shared answer is the plugin's memory: the script reads it, and cannot write
 it.

 Read-only is the half that makes sharing safe to offer at all. A document whose
 arrays a panel could write would be an edit with no undo and no rebind behind
 it — the same argument `qjs::Context.freeze` carries, reached through the ABI.
*>
fn void a_shared_answer_is_the_plugins_own_memory() @test
{
	@with_runtime(; three::JsRuntime* runtime)
	{
		three::engine_api.js_define("probe", "share", 0, &js_share, null);

		three::RunResult read = runtime.run("return Array.from(probe.share());");
		defer read.free();
		test::@check(read.value == "[1.5,2.5,3.5,4.5]",
			"the view reads the plugin's values, got %s", read.value);

		// Zero-copy in the direction that proves it: the plugin writes, and a
		// view taken *before* the write reads the new number.
		three::RunResult tracked = runtime.run("globalThis.__view = probe.share(); return 1;");
		defer tracked.free();
		owned[0] = 42;
		three::RunResult again = runtime.run("return globalThis.__view[0];");
		defer again.free();
		test::@check(again.value == "42",
			"and it is a view rather than a snapshot, got %s", again.value);
		owned[0] = 1.5;

		// The bulk methods throw; element writes are dropped in the fast path.
		// Both leave the memory alone, which is the guarantee — only one of them
		// says so out loud, and that difference is quickjs's, not the ABI's.
		three::RunResult refused = runtime.run("probe.share().fill(0); return 1;");
		defer refused.free();
		test::@check(!refused.ok, "a bulk write into the plugin's memory is refused");
		test::@check(owned[0] == 1.5, "and the plugin's memory is unchanged, got %s", owned[0]);
	};
}

<*
 Dropping detaches every view over the address, at the moment the memory changes
 rather than at the moment somebody reads it.

 This is the promise a share costs, and the reason it is not the default. The
 alternative to detaching is not an error later — it is a plausible wrong answer
 later, out of pages that belong to something else by then.
*>
fn void dropping_a_share_detaches_every_view_of_it() @test
{
	@with_runtime(; three::JsRuntime* runtime)
	{
		three::engine_api.js_define("probe", "share", 0, &js_share, null);

		three::RunResult held = runtime.run(
			"globalThis.__a = probe.share(); globalThis.__b = probe.share(); return __a[0];"
		);
		defer held.free();
		test::@check(held.value == "1.5", "two views over one address both read (%s)", held.value);

		three::engine_api.js_drop_buffer((char*)&owned[0]);

		// **How a detached view reads is worth stating exactly**, because it is
		// not "everything throws". An element read answers `undefined` and
		// `length` answers 0 — the array is empty, not broken. The methods are
		// what throw, which is the loud half.
		three::RunResult first = runtime.run("return [globalThis.__a.length, globalThis.__a[0] === undefined];");
		defer first.free();
		test::@check(first.value == "[0,true]",
			"the first view reads as empty (%s / %s)", first.value, first.error);

		three::RunResult second = runtime.run("return globalThis.__b.length;");
		defer second.free();
		test::@check(second.ok && second.value == "0",
			"and so does the second, which shared the same address (%s)", second.value);

		three::RunResult loud = runtime.run("return Array.from(globalThis.__a.subarray(0));");
		defer loud.free();
		test::@check(!loud.ok && loud.error.contains("detached"),
			"and a method says what happened out loud (%s / %s)", loud.value, loud.error);

		// Idempotent, and silent for an address that was never shared: a plugin
		// that drops defensively should not have to remember whether it shared.
		three::engine_api.js_drop_buffer((char*)&owned[0]);
		three::engine_api.js_drop_buffer((char*)&scratch[0]);
		three::engine_api.js_drop_buffer(null);
	};
}

<*
 The element kind is the ABI's, not quickjs's.

 `BUFFER_*` is a contract two separately compiled images share and `ARRAY_*` is
 a third library's enum that neither of them links. They are different numbers
 on purpose — `host_js.c3`'s `array_kind` is the only place they meet, and this
 is what would fail if that switch were deleted in favour of equal constants.
*>
fn void the_buffer_kinds_are_the_abis_own() @test
{
	@with_runtime(; three::JsRuntime* runtime)
	{
		three::engine_api.js_define("probe", "u8", 0, &js_u8, null);
		three::engine_api.js_define("probe", "i32", 0, &js_i32, null);
		three::engine_api.js_define("probe", "f64", 0, &js_f64, null);

		three::RunResult bytes = runtime.run("const a = probe.u8(); return [a.constructor.name, a.length];");
		defer bytes.free();
		test::@check(bytes.value == "[\"Uint8Array\",16]",
			"BUFFER_U8 is sixteen bytes as sixteen elements, got %s", bytes.value);

		three::RunResult ints = runtime.run("const a = probe.i32(); return [a.constructor.name, a[0]];");
		defer ints.free();
		test::@check(ints.value == "[\"Int32Array\",7]",
			"BUFFER_I32 reads as signed 32-bit, got %s", ints.value);

		three::RunResult doubles = runtime.run("const a = probe.f64(); return [a.constructor.name, a.length, a[0]];");
		defer doubles.free();
		test::@check(doubles.value == "[\"Float64Array\",2,0.5]",
			"BUFFER_F64 is eight bytes an element, got %s", doubles.value);
	};
}

fn void js_u8(void* user, three_abi::JsCall call, int argc) @local
{
	scratch = { 1, 2, 3, 4 };
	three::engine_api.js_return_buffer(
		call, (char*)&scratch[0], @sizeof(scratch), three_abi::BUFFER_U8, false
	);
}

fn void js_i32(void* user, three_abi::JsCall call, int argc) @local
{
	int[2] values = { 7, -7 };
	three::engine_api.js_return_buffer(
		call, (char*)&values[0], @sizeof(values), three_abi::BUFFER_I32, false
	);
}

fn void js_f64(void* user, three_abi::JsCall call, int argc) @local
{
	double[2] values = { 0.5, 1.5 };
	three::engine_api.js_return_buffer(
		call, (char*)&values[0], @sizeof(values), three_abi::BUFFER_F64, false
	);
}

<*
 An empty answer is `undefined`, not an empty array.

 A verb that computed nothing has not answered, and a zero-length `Float32Array`
 would be a claim that it had. The same rule `js_return_text` follows for a null
 pointer.
*>
fn void an_empty_answer_is_no_answer() @test
{
	@with_runtime(; three::JsRuntime* runtime)
	{
		three::engine_api.js_define("probe", "nothing", 0, &js_nothing, null);

		three::RunResult ran = runtime.run("return probe.nothing() === undefined;");
		defer ran.free();
		test::@check(ran.value == "true", "an empty buffer answers undefined, got %s", ran.value);
	};
}

fn void js_nothing(void* user, three_abi::JsCall call, int argc) @local
{
	three::engine_api.js_return_buffer(call, (char*)&scratch[0], 0, three_abi::BUFFER_F32, false);
	three::engine_api.js_return_buffer(call, null, 16, three_abi::BUFFER_F32, false);
}
