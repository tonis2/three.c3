<*
 `game.md` G1/S2: what an `import` in a game's JavaScript is allowed to mean.

 Every check here is `resolve_module`, which is two strings in and one out with
 no filesystem anywhere near it. That is the whole reason the containment is
 testable at all — a suite that had to build an assets directory to prove a
 specifier could not escape one would test the directory instead.
*>
module three_tests::modules;

import three;
import qjs;

<*
 Resolve, or say what it faulted with. Both are one line at the call site, which
 is what keeps the table below readable as a table.
*>
macro String @resolved(#base, #name)
{
	String? answer = qjs::resolve_module(#base, #name, tmem);
	if (catch err = answer) return string::tformat("<%s>", err);
	return answer;
}

fn void a_sibling_resolves_beside_its_importer() @test
{
	test::@check(@resolved("main.js", "./player.js") == "player.js",
		"./player.js from main.js (%s)", @resolved("main.js", "./player.js"));
	test::@check(@resolved("main.js", "player.js") == "player.js",
		"a bare name is relative too, as it is in a browser (%s)",
		@resolved("main.js", "player.js"));
	test::@check(@resolved("enemies/orc.js", "goblin.js") == "enemies/goblin.js",
		"and relative means relative to the importer's directory (%s)",
		@resolved("enemies/orc.js", "goblin.js"));
}

fn void dot_dot_climbs_and_stops_at_the_root() @test
{
	test::@check(@resolved("enemies/orc.js", "../shared/hp.js") == "shared/hp.js",
		"one level up (%s)", @resolved("enemies/orc.js", "../shared/hp.js"));
	test::@check(@resolved("a/b/c/deep.js", "../../top.js") == "a/top.js",
		"two levels up (%s)", @resolved("a/b/c/deep.js", "../../top.js"));
	test::@check(@resolved("main.js", "../secrets.js") == "<qjs::MODULE_ESCAPES_ROOT>",
		"and climbing past the root is refused (%s)",
		@resolved("main.js", "../secrets.js"));
}

<*
 The refusal is a refusal, not a clamp.

 A resolver that clamped would turn `../../../../etc/passwd` into `etc/passwd`,
 which is then *not found* — and "could not load module 'etc/passwd'" tells a
 script author their file is missing when what actually happened is that they
 were not allowed to ask. The distinction only matters in the message, and the
 message is the whole product here.
*>
fn void an_escape_is_refused_rather_than_clamped() @test
{
	test::@check(@resolved("main.js", "../../../../etc/passwd") == "<qjs::MODULE_ESCAPES_ROOT>",
		"a long climb is refused (%s)", @resolved("main.js", "../../../../etc/passwd"));
	test::@check(@resolved("a/b.js", "../../..") == "<qjs::MODULE_ESCAPES_ROOT>",
		"and so is one that only just overshoots (%s)",
		@resolved("a/b.js", "../../.."));
	// The one that would slip past a check written as "does it start with ..".
	test::@check(@resolved("main.js", "a/../../out.js") == "<qjs::MODULE_ESCAPES_ROOT>",
		"including one that climbs out only halfway through (%s)",
		@resolved("main.js", "a/../../out.js"));
}

<*
 A leading slash is the assets root, not the disk — which is what makes the
 obvious attack boring rather than dangerous.
*>
fn void a_leading_slash_is_the_assets_root() @test
{
	test::@check(@resolved("enemies/orc.js", "/lib/math.js") == "lib/math.js",
		"rooted, ignoring the importer's directory (%s)",
		@resolved("enemies/orc.js", "/lib/math.js"));
	test::@check(@resolved("main.js", "/etc/passwd") == "etc/passwd",
		"and an absolute host path is just a name under the root (%s)",
		@resolved("main.js", "/etc/passwd"));
}

fn void the_noise_in_a_path_is_dropped() @test
{
	test::@check(@resolved("main.js", "./a/./b.js") == "a/b.js",
		"a bare dot (%s)", @resolved("main.js", "./a/./b.js"));
	test::@check(@resolved("main.js", "a//b.js") == "a/b.js",
		"a doubled slash (%s)", @resolved("main.js", "a//b.js"));
	test::@check(@resolved("main.js", "") == "<qjs::MODULE_SPECIFIER_IS_EMPTY>",
		"and an empty import is not a path at all (%s)", @resolved("main.js", ""));
}

<*
 No extension guessing, for the reason every other ESM runtime gives: a
 specifier whose meaning depends on what happens to be on disk is a specifier
 that resolves differently on two machines.
*>
fn void no_extension_is_invented() @test
{
	test::@check(@resolved("main.js", "./player") == "player",
		"the specifier is taken as written (%s)", @resolved("main.js", "./player"));
}

<*
 A path deeper than the walker's stack is refused rather than overrunning it.

 The bound exists because `resolve_module` runs inside the engine's normalize
 callback, where an allocation is the thing worth not doing; the check is here
 because a bound with no test is a buffer overrun waiting for a long path.
*>
fn void a_path_deeper_than_the_walker_is_refused() @test
{
	DString deep;
	deep.init(tmem, 512);
	for (usz i = 0; i < 70; i++) deep.append_string("d/");
	deep.append_string("x.js");

	test::@check(@resolved("main.js", deep.str_view()) == "<qjs::MODULE_PATH_TOO_DEEP>",
		"seventy-one components is too many (%s)", @resolved("main.js", deep.str_view()));
}

// ============================================================================
// Where three.load reads from
// ============================================================================

<*
 A `.glb` path follows the same rule an `import` does, and for the same reason.

 `three.inventory()` answers with paths relative to the assets directory and
 `three.load` used to resolve against the working directory, so the two did not
 compose and the first two lines of any real game found that out —
 `could not load level_a.glb: gltf::FILE_NOT_FOUND`. One rule for both is what
 makes a game directory movable.

 Driven through a `JsRuntime` rather than a free function because the assets
 root is the runtime's, and "no root at all" — the plain `--mcp` case, where a
 path means what the shell means by it — is half of what is under test.
*>
macro String @asset_path(#root, #path)
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	if (#root.len > 0) runtime.set_assets_root(#root);

	String? answer = runtime.resolve_asset(#path, tmem);
	if (catch err = answer) return string::tformat("<%s>", err);
	return answer;
}

fn void an_asset_path_is_relative_to_the_assets_directory() @test
{
	test::@check(@asset_path("game", "level_a.glb") == "game/level_a.glb",
		"a bare name (%s)", @asset_path("game", "level_a.glb"));
	test::@check(@asset_path("game", "kits/rocks.glb") == "game/kits/rocks.glb",
		"a subdirectory (%s)", @asset_path("game", "kits/rocks.glb"));
	test::@check(@asset_path("game", "./kits/../level_a.glb") == "game/level_a.glb",
		"and the noise comes out (%s)", @asset_path("game", "./kits/../level_a.glb"));
	test::@check(@asset_path("game", "/level_a.glb") == "game/level_a.glb",
		"a leading slash is the assets root, not the filesystem's (%s)",
		@asset_path("game", "/level_a.glb"));
}

fn void an_asset_path_cannot_climb_out_of_the_game() @test
{
	test::@check(@asset_path("game", "../secrets.glb") == "<qjs::MODULE_ESCAPES_ROOT>",
		"one level up is refused (%s)", @asset_path("game", "../secrets.glb"));
	test::@check(@asset_path("game", "../../../../etc/passwd") == "<qjs::MODULE_ESCAPES_ROOT>",
		"and so is a long climb, rather than being clamped to etc/passwd (%s)",
		@asset_path("game", "../../../../etc/passwd"));
}

// ============================================================================
// A game of many files, end to end
// ============================================================================

<*
 The whole point of the loader, driven for real: a `main.js` whose imports
 reach a sibling directory relatively and the root absolutely, both landing on
 the same module. No device — the fixture computes rather than draws, because
 what is under test is the resolution, not the renderer.
*>
fn void a_game_boots_from_many_files() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_assets_root("test/fixtures/game");

	three::RunResult booted = runtime.run_module("main.js");
	defer booted.free();
	test::@check(booted.ok, "main.js and its imports evaluate (%s)", booted.error);
	test::@check(booted.log.contains("grid: 9"), "the imported parts computed (%s)", booted.log);

	// A module's globals are the same globals a later run reads — `game.md`'s
	// claim that an agent can attach to a booted game and look around.
	three::RunResult read = runtime.run("return globalThis.__game.size * globalThis.__game.grid;");
	defer read.free();
	test::@check(read.value == "27", "state the modules set survives into a run (%s)", read.value);
}

<*
 `--no-boot` is the assets root without the game.

 The two-stage pipeline's first half: a bake has to run under the game's own root
 — that is what makes its imports and its paths mean what the game means by them
 — and *before* the game, which on a clean checkout is waiting on the file the
 bake has not written yet. Booting first throws on a missing file before the
 script that would have made it ever runs.

 The root is still set, which is the whole point of the flag: what is skipped is
 the entry module and nothing else.
*>
fn void no_boot_is_the_root_without_the_game() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();

	three::boot_world(&runtime, "test/fixtures/game", "", boot: false)!!;

	three::RunResult read = runtime.run("return String(globalThis.__game);");
	defer read.free();
	test::@check(read.value.contains("undefined"), "main.js did not run (%s)", read.value);

	// And the root did arrive: a module resolves against it, which is what the
	// bake that runs next needs.
	three::RunResult booted = runtime.run_module("main.js");
	defer booted.free();
	test::@check(booted.ok, "the root is there for whatever runs next (%s)", booted.error);
}

<*
 `--module` is an entry point that may import, which `--script` cannot be.

 A script is wrapped in an async function so top-level `await` and `return` work,
 and an `import` declaration inside a function body is a syntax error before the
 engine has looked at anything else. So `import` worked in `main.js` and was a
 `SyntaxError` in the file beside it.

 Twice, because the root is the whole of what a module needs: once inside an
 assets directory that is already set, and once with none — where the file's own
 directory becomes it, since a module with a root of nowhere could not import at
 all.
*>
fn void a_module_entry_point_imports_the_way_main_js_does() @test
{
	three::JsRuntime rooted;
	rooted.open(null)!!;
	defer rooted.close();
	rooted.set_assets_root("test/fixtures/game");

	three::boot_module(&rooted, "test/fixtures/game/main.js")!!;
	three::RunResult read = rooted.run("return String(globalThis.__game.grid);");
	defer read.free();
	test::@check(read.value.contains("9"), "the module and its imports evaluated (%s)", read.value);

	three::JsRuntime alone;
	alone.open(null)!!;
	defer alone.close();

	three::boot_module(&alone, "test/fixtures/game/main.js")!!;
	three::RunResult again = alone.run("return String(globalThis.__game.grid);");
	defer again.free();
	test::@check(again.value.contains("9"), "and its own directory is a root (%s)", again.value);
}

<*
 A `--module` outside the assets root is refused rather than silently rooted
 somewhere else.

 The root is what its imports resolve against, so a module outside it would
 resolve them against a directory it is not in — which finds nothing, or finds the
 wrong file, and says neither.
*>
fn void a_module_outside_the_root_is_refused() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_assets_root("test/fixtures/game/parts");

	test::@check(
		@catch(three::boot_module(&runtime, "test/fixtures/game/main.js")),
		"a module outside the assets root was accepted"
	);
}

<*
 The `three:` space is closed from the outside. The refusal has to name the
 import, because "could not load" would send an author looking for a missing
 file rather than at a door that is shut.
*>
fn void a_game_may_not_import_the_preludes_internals() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_assets_root("test/fixtures/game");

	three::RunResult refused = runtime.run_module("forbidden.js");
	defer refused.free();
	test::@check(!refused.ok, "the import is refused");
	test::@check(refused.error.contains("cannot import 'three:math.js'"),
		"and the refusal names it (%s)", refused.error);
}

<*
 Without an assets root a path is used exactly as written.

 The `--mcp` and CLI case. There is no directory for it to be relative to, an
 agent naming a file names it from wherever the process was started, and
 confining it to nothing would refuse every path there is — including the
 `test/fixtures/textured.glb` half this suite is built on.
*>
fn void without_an_assets_root_a_path_is_left_alone() @test
{
	test::@check(@asset_path("", "test/fixtures/textured.glb") == "test/fixtures/textured.glb",
		"a relative path (%s)", @asset_path("", "test/fixtures/textured.glb"));
	test::@check(@asset_path("", "../up/one.glb") == "../up/one.glb",
		"and one that climbs, which is the caller's business here (%s)",
		@asset_path("", "../up/one.glb"));
}

<*
 Reading and writing are two doors, and the narrow one is the writer.

 `resolve_write` confines a script to the directory it was given, which is the
 rule that outlived the `plugin:` scheme it was first written for: a game's
 script may put a file in its own directory and may not climb out of it.
*>
fn void a_script_writes_only_inside_its_own_directory() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_assets_root("game");

	String? ordinary = runtime.resolve_write("out.glb", tmem);
	test::@check(!@catch(ordinary) && ordinary!! == "game/out.glb",
		"a game writes inside its own directory");

	String? rooted = runtime.resolve_write("/levels/lumbridge.json", tmem);
	test::@check(!@catch(rooted) && rooted!! == "game/levels/lumbridge.json",
		"a leading '/' is the assets directory, not the filesystem's");

	fault escaping = @catch(runtime.resolve_write("../secrets.glb", tmem));
	test::@check(escaping == qjs::MODULE_ESCAPES_ROOT,
		"climbing out is refused, the same as a read (%s)", escaping);
}

// ============================================================================
// A failed load names the path it actually looked for
// ============================================================================

<*
 `JsRuntime.blame` is what `three.load`, `three.readText` and `three.texture`
 build their failure sentences from, so a script whose leading `/` got rooted
 sees where its file was actually sought and not just the name it typed —
 which is on disk, readable, and nowhere near the path the old message named.
*>
fn void a_failure_names_both_the_written_and_the_looked_for_path() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_assets_root("game");

	// The surprising case: a leading '/' reads as the filesystem's root to
	// anyone who has not read this file, and is rooted at the assets
	// directory instead — this is the rewrite the sentence has to own up to.
	String? opening = runtime.resolve_asset("/kit/buildings.glb", tmem);
	test::@check(!@catch(opening), "the rooted path still resolves");
	String located = opening!!;
	test::@check(located == "game/kit/buildings.glb", "landing inside the game (%s)", located);

	String blamed = runtime.blame("/kit/buildings.glb", located);
	test::@check(blamed.contains("/kit/buildings.glb"),
		"the path as the script wrote it is named (%s)", blamed);
	test::@check(blamed.contains("game/kit/buildings.glb"),
		"the path actually opened is named too (%s)", blamed);
	test::@check(blamed.contains("game"), "and the assets directory that did the rooting (%s)", blamed);
}

<*
 Without an assets root, `resolve_asset` never rewrites anything, so the
 sentence must not claim it did — a shorter, honest form instead.
*>
fn void without_a_root_the_sentence_does_not_claim_a_rewrite() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();

	String? opening = runtime.resolve_asset("does-not-exist.glb", tmem);
	test::@check(!@catch(opening), "a plain relative path resolves as written");
	String located = opening!!;
	test::@check(located == "does-not-exist.glb", "and is left alone (%s)", located);

	String blamed = runtime.blame("does-not-exist.glb", located);
	test::@check(blamed.contains("does-not-exist.glb"), "the path is still named (%s)", blamed);
	test::@check(!blamed.contains("assets directory"),
		"but nothing claims a rewrite that never happened (%s)", blamed);
}
