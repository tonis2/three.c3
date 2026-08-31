<*
 `game.md` G1/S2: what an `import` in a game's JavaScript is allowed to mean.

 Every check here is `resolve_module`, which is two strings in and one out with
 no filesystem anywhere near it. That is the whole reason the containment is
 testable at all — a suite that had to build an assets directory to prove a
 specifier could not escape one would test the directory instead.
*>
module three_tests::modules;

import std::io;
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
 `plugin_abi.md` §8: a plugin ships a `.dylib` and a directory of `.js`, and its
 modules live under `plugin:` rather than under the root `--assets` owns.

 Without an assets root at all, which is the case that matters — crig runs with
 no `--assets` and a plugin's panels still have to resolve.
*>
fn void a_plugin_scheme_resolves_without_an_assets_root() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_plugin_scripts("test/fixtures/plugin");

	three::RunResult booted = runtime.run_module("plugin:main.js");
	defer booted.free();
	test::@check(booted.ok, "plugin:main.js evaluates with no game directory (%s)", booted.error);
	test::@check(booted.log.contains("plugin: readout"),
		"and its own sibling import resolved (%s)", booted.log);
}

<*
 Both roots at once, which is the arrangement `set_plugin_root` exists for: a
 prefix cannot collide with a directory, so a game and a plugin can each have
 their own `shared.js` and neither shadows the other.
*>
fn void the_two_roots_are_addressed_apart() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_assets_root("test/fixtures/game");
	runtime.set_plugin_scripts("test/fixtures/plugin");

	three::RunResult borrowed = runtime.run_module("borrows.js");
	defer borrowed.free();
	test::@check(borrowed.ok, "a game module resolves against both (%s)", borrowed.error);

	three::RunResult read = runtime.run("return globalThis.__borrowed.whose;");
	defer read.free();
	test::@check(read.value == "\"game\"",
		"a bare './shared.js' is the game's, not the plugin's (%s)", read.value);
}

<*
 The one place this space differs from `three:`, and the difference is
 deliberate — see `qjs::ModuleLoader.set_scheme`. An embedded module is the
 engine's internals; a plugin's panel is a file somebody shipped and can open,
 and importing one to extend an editor is a thing to allow.
*>
fn void a_game_may_import_a_plugins_panel() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_assets_root("test/fixtures/game");
	runtime.set_plugin_scripts("test/fixtures/plugin");

	three::RunResult borrowed = runtime.run_module("borrows.js");
	defer borrowed.free();
	test::@check(borrowed.ok, "the import is allowed (%s)", borrowed.error);

	three::RunResult read = runtime.run("return globalThis.__borrowed.title;");
	defer read.free();
	test::@check(read.value == "\"readout\"", "and it is the plugin's module (%s)", read.value);
}

<*
 `..` past the scheme's own root is refused rather than escaping into whatever
 directory sits beside it — the containment `resolve_module` gives the assets
 root, applied to this one.
*>
fn void a_plugin_module_cannot_climb_out_of_its_directory() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_plugin_scripts("test/fixtures/plugin");

	three::RunResult refused = runtime.run_module("plugin:../game/main.js");
	defer refused.free();
	test::@check(!refused.ok, "the climb is refused");
}

<*
 A plugin's *data*, not only its modules — `plugin_plan.md` item 3.

 Item 1 gave a plugin's scripts a home and stopped there, so a plugin could ship
 a panel but not the icon on it: `locate` read `root` alone and knew nothing
 about the scheme, which made `--assets` the only directory `three.load` could
 see. A bundle whose code travels and whose files do not is not a bundle.

 Resolution rather than loading, for the reason the whole file is: what is under
 test is which directory a name means, and a check that had to open a `.glb` to
 prove it would be testing the loader.
*>
macro String @plugin_path(#assets, #scripts, #path)
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	if (#assets.len > 0) runtime.set_assets_root(#assets);
	if (#scripts.len > 0) runtime.set_plugin_scripts(#scripts);

	String? answer = runtime.resolve_asset(#path, tmem);
	if (catch err = answer) return string::tformat("<%s>", err);
	return answer;
}

fn void a_plugins_assets_resolve_under_its_own_scheme() @test
{
	test::@check(@plugin_path("", "plugins/hello", "plugin:icons/bone.png") == "plugins/hello/icons/bone.png",
		"with no game directory at all (%s)",
		@plugin_path("", "plugins/hello", "plugin:icons/bone.png"));

	// Both roots at once, which is the arrangement that would have been wrong
	// before: a prefixed path is the plugin's and a bare one is still the game's.
	test::@check(@plugin_path("game", "plugins/hello", "plugin:kit.glb") == "plugins/hello/kit.glb",
		"the prefix names the plugin's directory (%s)",
		@plugin_path("game", "plugins/hello", "plugin:kit.glb"));
	test::@check(@plugin_path("game", "plugins/hello", "kit.glb") == "game/kit.glb",
		"and a bare name is still the game's (%s)",
		@plugin_path("game", "plugins/hello", "kit.glb"));
}

<*
 The scheme's root confines the scheme's paths, exactly as the assets root
 confines a game's.

 And a prefix with no directory behind it is refused rather than quietly
 stripped: answering the bare tail would resolve `plugin:shared.js` to the
 *game's* `shared.js`, which is the one collision the prefix exists to prevent.
*>
fn void a_plugin_path_is_confined_to_the_plugins_directory() @test
{
	test::@check(@plugin_path("", "plugins/hello", "plugin:../secrets") == "<qjs::MODULE_ESCAPES_ROOT>",
		"climbing out is refused (%s)", @plugin_path("", "plugins/hello", "plugin:../secrets"));
	test::@check(@plugin_path("game", "", "plugin:kit.glb") == "<qjs::MODULE_IS_NOT_A_FILE>",
		"and so is a prefix with no plugin loaded (%s)", @plugin_path("game", "", "plugin:kit.glb"));
}

<*
 Readable by name, and deliberately not writable by one.

 `three.load` and `scene.export` used to go through one door, and opening that
 door onto a plugin's directory would have let a game's script overwrite the
 application's own panels. They are two doors now — `resolve_asset` and
 `resolve_write` — and this is the difference between them.
*>
fn void a_plugins_directory_is_read_only_to_a_script() @test
{
	three::JsRuntime runtime;
	runtime.open(null)!!;
	defer runtime.close();
	runtime.set_assets_root("game");
	runtime.set_plugin_scripts("plugins/hello");

	String? reading = runtime.resolve_asset("plugin:kit.glb", tmem);
	test::@check(!@catch(reading) && reading!! == "plugins/hello/kit.glb", "a read resolves");

	String? writing = runtime.resolve_write("plugin:kit.glb", tmem);
	test::@check(@catch(writing) == qjs::MODULE_ESCAPES_ROOT,
		"a write into the plugin's directory is refused");

	// And the narrower door is still the ordinary one for everything else.
	String? ordinary = runtime.resolve_write("out.glb", tmem);
	test::@check(!@catch(ordinary) && ordinary!! == "game/out.glb",
		"a game still writes inside its own directory");
}
