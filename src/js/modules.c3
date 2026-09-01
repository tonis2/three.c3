<*
 `import` from a game's own JavaScript, confined to the assets directory.

 A `--assets` boot evaluates `main.js` as an ES module, so a game can be many
 files rather than one. The mechanics — root-relative specifiers, refusing `..`
 past the root, the reusable read buffer — live in `quickjs.c3l`'s
 `ModuleLoader`. This file is only the three.c3 part: which directory is the
 root, which namespace the prelude lives in, and where `three.load` reads from.

 `three` is not a module: there is no `import three from 'three'`. The prelude
 installs globals, modules see globals, and `import` is for the game's own code.

 The prelude is itself split into ES modules, and those live in the loader's
 embedded namespace — `three:math.js`, `three:docs.js` — answered from bytes
 embedded in the binary rather than from disk. Only a module already inside that
 space may import from it; a game writing `import 'three:math.js'` is refused
 like `../` past the root, because the prelude's internals are not API.
*>
module three;

import std::io;
import qjs;

<*
 The specifier space the prelude's own modules live in.

 A prefix rather than a directory so it cannot collide with anything a game can
 write: the resolver never produces a ':' it was not given, and a file literally
 named `three:math.js` on disk is refused rather than becoming a second way in.
*>
const String PRELUDE_SCHEME = "three:";

<*
 Installs the loader, before the prelude evaluates.

 The hooks are always in place because the prelude's own imports need them from
 the first evaluation; what stays gated on `set_assets_root` is the *disk*.
 Until a root exists the loader refuses every specifier outside the `three:`
 space, which is what an `--mcp`-only run wants: `run_script` is not a module
 and has no directory to be relative to.

 `modules` lives on the runtime and is addressed by the engine, so it must not
 move for as long as the context is open — the same requirement `main.c3`
 already meets for the `Renderer` the server holds.
*>
fn void JsRuntime.install_module_hooks(&self)
{
	self.modules.set_embedded(PRELUDE_SCHEME, prelude_parts());
	self.modules.install(self.js);
}

<*
 Points `import` at a directory, letting a game's own modules resolve.

 @param root : `The assets directory. Copied.`
*>
fn void JsRuntime.set_assets_root(&self, String root)
{
	self.modules.set_root(root);

	// A directory that boots is a game, and a game's frames are warned about
	// rather than killed. See `JsRuntime.play_frames`.
	self.play_frames();
}

<*
 Where `three.load("kit.glb")` reads from.

 In an `--assets` boot the path is relative to the assets directory and confined
 to it by the same rule `import` follows, so the paths `three.inventory()` hands
 back are paths `three.load` accepts and a game directory can be moved or
 renamed without editing a line inside it.

 Without an assets root the path is used as written — the `--mcp` and CLI case,
 where there is no directory to be relative to and confining would refuse every
 path there is.

 @param path : `As the script wrote it. A leading '/' means the assets directory, not the filesystem's.`
 @return `The path to open, allocated in the caller's allocator.`
*>
fn String? JsRuntime.resolve_asset(&self, String path, Allocator allocator)
{
	return self.modules.locate(path, allocator);
}

<*
 Where a script may *write*, which is a shorter list than where it may read.

 The assets directory and nowhere else.

 @param path : `As the script wrote it.`
 @return `The path to write, allocated in the caller's allocator.`
*>
fn String? JsRuntime.resolve_write(&self, String path, Allocator allocator)
{
	return self.modules.locate(path, allocator, schemes: false);
}