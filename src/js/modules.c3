<*
 `import` from a game's own JavaScript, confined to the assets directory.

 `game.md` G1/S2. A `--assets` boot evaluates `main.js` as an ES module, so the
 program a person writes is many files rather than one. The mechanics — the
 root-relative specifiers, the refusal of `..` past the root, the one reusable
 read buffer — are `quickjs.c3l`'s `ModuleLoader`, written once there and wired
 up here; this file is only what is *three.c3's* about it: which directory is
 the root, which namespace the prelude lives in, and where `three.load` reads
 from.

 ## The prelude stays a global — and owns the `three:` specifier space

 `three` is not a module and there is no `import three from 'three'`. The
 prelude installs globals, modules see globals, and `import` is for the game's
 own code. `plan.md` §4's rule about half-matching an API somebody has memorised
 applies to a second way of reaching the same object as much as it does to a
 renamed method.

 The prelude is itself split into ES modules, though, and those live in the
 loader's embedded namespace: `three:math.js`, `three:docs.js`, answered from
 bytes embedded in the binary rather than from any disk. Only a module already
 inside that space may import from it — a game writing `import 'three:math.js'`
 is refused exactly as `../` past the root is, because the prelude's internals
 are not API and a game that reached them would be a game that breaks on the
 next refactor of a file it cannot see.
*>
module three;

import std::io;
import qjs;

<*
 The specifier space the prelude's own modules live in.

 A prefix rather than a directory so it cannot collide with anything a game can
 write: the resolver never produces a ':' it was not given, and a game file
 literally named `three:math.js` on disk is a name the loader refuses rather
 than a second way in.
*>
const String PRELUDE_SCHEME = "three:";

<*
 Install the loader itself, before the prelude evaluates.

 The hooks are always in place because the prelude's own imports need them from
 the first evaluation; what stays gated on `set_assets_root` is the *disk*.
 Until a root exists the loader refuses every specifier outside the `three:`
 space, which is what an `--mcp`-only run wants: `run_script` is not a module
 and has no directory to be relative to.

 **`modules` lives on the runtime and is addressed by the engine**, so it must
 not move for as long as the context is open. That is the same requirement
 `main.c3` already meets for the `Renderer` the server holds.
*>
fn void JsRuntime.install_module_hooks(&self)
{
	self.modules.set_embedded(PRELUDE_SCHEME, prelude_parts());
	self.modules.install(self.js);
}

<*
 Point `import` at a directory, and let a game's own modules resolve.

 @param root : `The assets directory. Copied.`
*>
fn void JsRuntime.set_assets_root(&self, String root)
{
	self.modules.set_root(root);

	// A directory that boots is a game, and a game's frames are warned about
	// rather than killed. `JsRuntime.play_frames` carries the argument.
	self.play_frames();
}

<*
 Where `three.load("kit.glb")` reads from.

 In a `--assets` boot a path is relative to the assets directory and confined to
 it, by exactly the rule an `import` follows, so the paths `three.inventory()`
 hands back are paths `three.load` accepts, and a game directory can be moved or
 renamed without editing a line inside it. Before this they were two different
 conventions and the first line of every game was the one that found that out.

 Without an assets root the path is used as written. That is the `--mcp` and CLI
 case: there is no directory for it to be relative to, an agent naming a file
 names it from wherever the process was started, and confining it to nothing
 would refuse every path there is.

 @param path : `As the script wrote it. A leading '/' means the assets directory, not the filesystem's.`
 @return `The path to open, allocated in the caller's allocator.`
*>
fn String? JsRuntime.resolve_asset(&self, String path, Allocator allocator)
{
	return self.modules.locate(path, allocator);
}
