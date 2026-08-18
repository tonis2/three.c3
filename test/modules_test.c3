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

<*
 Resolve, or say what it faulted with. Both are one line at the call site, which
 is what keeps the table below readable as a table.
*>
macro String @resolved(#base, #name)
{
	String? answer = three::resolve_module(#base, #name, tmem);
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
	test::@check(@resolved("main.js", "../secrets.js") == "<three::MODULE_ESCAPES_ASSETS_ROOT>",
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
	test::@check(@resolved("main.js", "../../../../etc/passwd") == "<three::MODULE_ESCAPES_ASSETS_ROOT>",
		"a long climb is refused (%s)", @resolved("main.js", "../../../../etc/passwd"));
	test::@check(@resolved("a/b.js", "../../..") == "<three::MODULE_ESCAPES_ASSETS_ROOT>",
		"and so is one that only just overshoots (%s)",
		@resolved("a/b.js", "../../.."));
	// The one that would slip past a check written as "does it start with ..".
	test::@check(@resolved("main.js", "a/../../out.js") == "<three::MODULE_ESCAPES_ASSETS_ROOT>",
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
	test::@check(@resolved("main.js", "") == "<three::MODULE_SPECIFIER_IS_EMPTY>",
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

	test::@check(@resolved("main.js", deep.str_view()) == "<three::MODULE_PATH_TOO_DEEP>",
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
	test::@check(@asset_path("game", "../secrets.glb") == "<three::MODULE_ESCAPES_ASSETS_ROOT>",
		"one level up is refused (%s)", @asset_path("game", "../secrets.glb"));
	test::@check(@asset_path("game", "../../../../etc/passwd") == "<three::MODULE_ESCAPES_ASSETS_ROOT>",
		"and so is a long climb, rather than being clamped to etc/passwd (%s)",
		@asset_path("game", "../../../../etc/passwd"));
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
