<*
 `game.md` G1/S2: what an `import` in a game's JavaScript is allowed to mean.

 Every check here is `resolve_module`, which is two strings in and one out with
 no filesystem anywhere near it. That is the whole reason the containment is
 testable at all — a suite that had to build an assets directory to prove a
 specifier could not escape one would test the directory instead.
*>
module three_tests::modules;

import three;
import fastjs::js;
import std::io::file;
import std::io::path;

<*
 Resolve, or say what it faulted with. Both are one line at the call site, which
 is what keeps the table below readable as a table.
*>
macro String @resolved(#base, #name)
{
	String? answer = js::resolve_module(#base, #name, tmem);
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
	test::@check(@resolved("main.js", "../secrets.js") == "<js::MODULE_ESCAPES_ROOT>",
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
	test::@check(@resolved("main.js", "../../../../etc/passwd") == "<js::MODULE_ESCAPES_ROOT>",
		"a long climb is refused (%s)", @resolved("main.js", "../../../../etc/passwd"));
	test::@check(@resolved("a/b.js", "../../..") == "<js::MODULE_ESCAPES_ROOT>",
		"and so is one that only just overshoots (%s)",
		@resolved("a/b.js", "../../.."));
	// The one that would slip past a check written as "does it start with ..".
	test::@check(@resolved("main.js", "a/../../out.js") == "<js::MODULE_ESCAPES_ROOT>",
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
	test::@check(@resolved("main.js", "") == "<js::MODULE_SPECIFIER_IS_EMPTY>",
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

	test::@check(@resolved("main.js", deep.str_view()) == "<js::MODULE_PATH_TOO_DEEP>",
		"seventy-one components is too many (%s)", @resolved("main.js", deep.str_view()));
}

// ============================================================================
// Where three.load reads from
// ============================================================================

<*
 A path a script names starts from the first script's folder — `base` — and
 goes anywhere from there.

 `three.inventory()` answers with paths relative to that folder and `three.load`
 takes them, so the two compose and a game folder can be moved. An absolute path
 is used as it is, and `..` climbs out of the folder, for reading and writing
 alike: nothing is fenced in.

 Driven through a `JsRuntime` rather than a free function because the base is
 the runtime's, and "no base at all" — the plain `--mcp` case, where a path means
 what the shell means by it — is half of what is under test.
*>
macro String @asset_path(#base, #path)
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	if (#base.len > 0) runtime.set_base(#base)!!;

	String? answer = runtime.resolve_asset(#path, tmem);
	if (catch err = answer) return string::tformat("<%s>", err);
	return answer;
}

fn void a_relative_path_starts_from_the_base() @test
{
	test::@check(@asset_path("/srv/game", "level_a.glb") == "/srv/game/level_a.glb",
		"a bare name (%s)", @asset_path("/srv/game", "level_a.glb"));
	test::@check(@asset_path("/srv/game", "kits/rocks.glb") == "/srv/game/kits/rocks.glb",
		"a subdirectory (%s)", @asset_path("/srv/game", "kits/rocks.glb"));
	test::@check(@asset_path("/srv/game", "./kits/../level_a.glb") == "/srv/game/level_a.glb",
		"and the noise comes out (%s)", @asset_path("/srv/game", "./kits/../level_a.glb"));
}

fn void a_path_goes_anywhere_on_disk() @test
{
	test::@check(@asset_path("/srv/game", "../shared/rocks.glb") == "/srv/shared/rocks.glb",
		"`..` climbs out of the base (%s)", @asset_path("/srv/game", "../shared/rocks.glb"));
	test::@check(@asset_path("/srv/game", "/home/me/kit.glb") == "/home/me/kit.glb",
		"an absolute path is the disk's (%s)", @asset_path("/srv/game", "/home/me/kit.glb"));
	test::@check(@asset_path("/srv/game", "../..") == "/",
		"up to the top of the disk (%s)", @asset_path("/srv/game", "../.."));
	test::@check(@asset_path("/srv/game", "../../../etc") == "<js::MODULE_ESCAPES_ROOT>",
		"and no further (%s)", @asset_path("/srv/game", "../../../etc"));
}

// A relative base is the working directory's folder of that name, made
// absolute once, so a later `chdir` cannot move where the game's paths point.
fn void a_relative_base_is_made_absolute() @test
{
	String cwd = (String)path::tcwd()!!;
	String expected = string::tformat("%s/game/level_a.glb", cwd);
	test::@check(@asset_path("game", "level_a.glb") == expected,
		"%s, not %s", @asset_path("game", "level_a.glb"), expected);
	test::@check(@asset_path("./game/", "level_a.glb") == expected,
		"however the folder was typed (%s)", @asset_path("./game/", "level_a.glb"));
}

<*
 Without a base a path is used exactly as written.

 The `--mcp` case. There is no script for it to be relative to, an agent naming
 a file names it from wherever the process was started — including the
 `test/fixtures/textured.glb` half this suite is built on.
*>
fn void without_a_base_a_path_is_left_alone() @test
{
	test::@check(@asset_path("", "test/fixtures/textured.glb") == "test/fixtures/textured.glb",
		"a relative path (%s)", @asset_path("", "test/fixtures/textured.glb"));
	test::@check(@asset_path("", "../up/one.glb") == "../up/one.glb",
		"and one that climbs (%s)", @asset_path("", "../up/one.glb"));
}

// ============================================================================
// A game of many files, end to end
// ============================================================================

<*
 The whole point of the loader, driven for real: a `main.js` whose imports
 reach a sibling directory, directly and by climbing out and back in, both
 landing on the same module. No device — the fixture computes rather than draws, because
 what is under test is the resolution, not the renderer.
*>
fn void a_game_boots_from_many_files() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_base("test/fixtures/game")!!;

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

// Under `build/`, which is gitignored: a test may not write into the repo.
const String TEST_SCRIPT_IMPORTS = "build/test-script-imports";

<*
 Two `--script`s: a game, and a probe kept somewhere else that runs against it.

 Everything the one-flag command line promises, in one boot:
 - the scripts run in order, so the probe sees the world `main.js` built;
 - the probe imports the game's module with `..`, from outside the game's
   folder, and gets the same instance rather than a second copy of its state;
 - a relative path in the probe starts from the *first* script's folder, so it
   reads the game's files the way the game does;
 - `import.meta.dirname` is each module's own folder, absolute, so a module
   that wants a path beside itself can build one whoever ran it.
*>
fn void a_probe_runs_against_the_game_it_follows() @test
{
	(void)path::rmtree((Path)TEST_SCRIPT_IMPORTS);
	defer (void)path::rmtree((Path)TEST_SCRIPT_IMPORTS);
	@pool()
	{
		path::mkdir((Path)string::tformat("%s/game/parts", TEST_SCRIPT_IMPORTS), recursive: true)!!;
		path::mkdir((Path)string::tformat("%s/tools/probe", TEST_SCRIPT_IMPORTS), recursive: true)!!;
		String[2][*] files = {
			{ "game/parts/count.js", "export const seen = { n: 0 }; export const here = import.meta.dirname;" },
			{ "game/main.js", "import { seen } from './parts/count.js'; seen.n++;" },
			{ "game/level.txt", "the game's own file" },
			{ "tools/probe/probe.js",
				"import { seen, here } from '../../game/parts/count.js';\n"
				"seen.n++;\n"
				"globalThis.__probe = { n: seen.n, level: three.readText('level.txt'), here, mine: import.meta.dirname };" },
		};
		foreach (f : files) file::save(string::tformat("%s/%s", TEST_SCRIPT_IMPORTS, f[0]), f[1])!!;
	};

	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	String[2] scripts = { "build/test-script-imports/game/main.js", "./build/test-script-imports/tools/probe/probe.js" };
	three::boot_world(&runtime, scripts[..])!!;

	String root = string::tformat("%s/%s", (String)path::tcwd()!!, TEST_SCRIPT_IMPORTS);
	test::@check(runtime.base == string::tformat("%s/game", root), "the base is the first script's folder (%s)", runtime.base);

	three::RunResult probe = runtime.run("return globalThis.__probe;");
	defer probe.free();
	test::@check(probe.value.contains(`"n":2`), "the probe shares the game's module, after it ran (%s)", probe.value);
	test::@check(probe.value.contains("the game's own file"), "and reads a relative path from the game's folder (%s)", probe.value);
	test::@check(probe.value.contains(string::tformat(`"here":"%s/game/parts"`, root)),
		"import.meta.dirname is the module's own folder (%s)", probe.value);
	test::@check(probe.value.contains(string::tformat(`"mine":"%s/tools/probe"`, root)),
		"for the probe too (%s)", probe.value);
}

// A typo on the command line is raised before anything runs, so the game does
// not boot half its scripts and then report the missing one.
fn void a_missing_script_runs_none() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	String[2] scripts = { "test/fixtures/game/main.js", "test/fixtures/game/no-such.js" };
	test::@check(@catch(three::boot_world(&runtime, scripts[..])) == three::SCRIPT_NOT_READABLE, "the typo is raised");

	three::RunResult read = runtime.run("return String(globalThis.__game);");
	defer read.free();
	test::@check(read.value.contains("undefined"), "and main.js did not run (%s)", read.value);
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
	runtime.set_base("test/fixtures/game")!!;

	three::RunResult refused = runtime.run_module("forbidden.js");
	defer refused.free();
	test::@check(!refused.ok, "the import is refused");
	test::@check(refused.error.contains("cannot import 'three:math.js'"),
		"and the refusal names it (%s)", refused.error);
}

// ============================================================================
// A failed load names the path it actually looked for
// ============================================================================

<*
 `JsRuntime.blame` is what `three.load`, `three.readText` and `three.texture`
 build their failure sentences from. A relative path was joined onto the base,
 and the sentence says so: the file someone is looking for in the working
 directory was sought beside the game.
*>
fn void a_failure_names_both_the_written_and_the_looked_for_path() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_base("/srv/game")!!;

	String located = runtime.resolve_asset("kit/buildings.glb", tmem)!!;
	test::@check(located == "/srv/game/kit/buildings.glb", "landing beside the game (%s)", located);

	String blamed = runtime.blame("kit/buildings.glb", located);
	test::@check(blamed.contains("\"kit/buildings.glb\""), "the path as the script wrote it is named (%s)", blamed);
	test::@check(blamed.contains("/srv/game/kit/buildings.glb"), "the path actually opened is named too (%s)", blamed);
	test::@check(blamed.contains("first script's folder"), "and why it was joined (%s)", blamed);

	String plain = runtime.blame("/srv/kit.glb", "/srv/kit.glb");
	test::@check(plain == "\"/srv/kit.glb\"", "an absolute path was not rewritten, so nothing says it was (%s)", plain);
}

<*
 Without a base, `resolve_asset` never rewrites anything, so the sentence must
 not claim it did — a shorter, honest form instead.
*>
fn void without_a_base_the_sentence_does_not_claim_a_rewrite() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();

	String located = runtime.resolve_asset("does-not-exist.glb", tmem)!!;
	test::@check(located == "does-not-exist.glb", "a plain relative path is left alone (%s)", located);

	String blamed = runtime.blame("does-not-exist.glb", located);
	test::@check(blamed == "\"does-not-exist.glb\"", "the path is named and nothing else (%s)", blamed);
}
