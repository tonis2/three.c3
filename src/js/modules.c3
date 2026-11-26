<*
 `import`, and what a file path a script names means.

 Scripts are ES modules, so a game can be many files. The mechanics — resolving a
 specifier against the module that wrote it, applying `..`, the reusable read
 buffer, `import.meta` — live in fastjs's `ModuleLoader`. This file is only the
 three.c3 part: the loader's root, the namespace the prelude lives in, and where
 `three.load` reads from.

 **Nothing is fenced in.** The loader's root is the whole disk, so a module's
 specifier is its absolute path: an import resolves against the importing file,
 and `..` and absolute paths work, as they do in Node or a browser. Each file is
 one module however it was spelled, so a tool importing the game's modules shares
 their instances with the game.

 **Relative file paths start from the first `--script`'s folder** — `base`, the
 game's folder when the first script is its `main.js`. A path a script names for
 `three.load`, `readJSON`, `writeText` or `screenshot` is joined onto it; an
 absolute path is used as it is. Reads and writes go anywhere. A module that
 wants paths beside itself rather than beside the game writes them from
 `import.meta.dirname`.

 `three` is not a module: there is no `import three from 'three'`. The prelude
 installs globals, modules see globals, and `import` is for the game's own code.

 The prelude is itself split into ES modules, and those live in the loader's
 embedded namespace — `three:math.js`, `three:api.js` — answered from bytes
 embedded in the binary rather than from disk. Only a module already inside that
 space may import from it; a game writing `import 'three:math.js'` is refused,
 because the prelude's internals are not API.
*>
module three;

import std::io::path;
import fastjs::js;

<*
 The specifier space the prelude's own modules live in.

 A prefix rather than a directory so it cannot collide with anything on disk: a
 disk specifier always starts with '/', and the resolver never produces a ':' it
 was not given.
*>
const String PRELUDE_SCHEME = "three:";

<*
 Installs the loader, before the prelude evaluates.

 The hooks are always in place because the prelude's own imports need them from
 the first evaluation; what waits for `set_base` is the *disk*. Until then the
 loader refuses every specifier outside the `three:` space, which is what an
 `--mcp`-only run wants: `run_script` is not a module and has no file to be
 relative to.

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
 Opens the disk to `import` and makes `folder` where relative paths start.

 @param folder : `The first script's folder. A relative one is taken from the working directory.`
 @return? js::MODULE_ESCAPES_ROOT, path::cwd!
*>
fn void? JsRuntime.set_base(&self, String folder)
{
	String absolute = from_working_directory(folder, mem)!;
	self.modules.set_root("/");
	if (self.base.len > 0) self.base.free(mem);
	self.base = absolute;
}

<*
 Where a path a script names points on disk, for reading or writing.

 Joined onto `base` when it is relative, normalized either way. Without a base —
 a run with no script — the path is used as written, relative to where the
 process was started, as it is for an agent's `run_script`.

 @param path : `As the script wrote it.`
 @return `The path to open, allocated in the caller's allocator.`
 @return? js::MODULE_ESCAPES_ROOT : `More '..' than there is path above it.`
*>
fn String? JsRuntime.resolve_asset(&self, String path, Allocator allocator)
{
	if (self.base.len == 0) return path.copy(allocator);
	return absolute_path(path, self.base, allocator);
}

<*
 The path a failed load, read or decode should be blamed on: what the script
 wrote, quoted, and, when it was relative, where that pointed and why.

 Every caller has the same things in hand — the path as written and what
 `resolve_asset` made of it — and naming only the first is how "could not load
 models/a.glb" ends up pointing at a file that is right there in the working
 directory, when the one actually missing is beside the game.

 @param path : `As the script wrote it.`
 @param opening : `What resolve_asset returned for it: the path actually opened.`
 @return `A quoted, self-contained phrase — drop it wherever the bare path used to go.`
*>
fn String JsRuntime.blame(&self, String path, String opening)
{
	if (self.base.len == 0 || path.starts_with("/")) return string::tformat("\"%s\"", path);
	return string::tformat(
		"\"%s\" (relative paths start from the first script's folder %s, so this looked for \"%s\")",
		path,
		self.base,
		opening
	);
}

<*
 `path` made absolute against `from` and normalized: `.`, `..` and doubled
 slashes applied lexically, as the loader applies them to an import.

 Lexical, so a symlink is not resolved and two spellings of one file through a
 link are two paths — the loader's rule, kept so that a path and an import of the
 same file agree.

 @param path : `Absolute, or relative to from.`
 @param from : `An absolute folder.`
 @return `Absolute, with no trailing separator; "/" for the top of the disk.`
 @return? js::MODULE_ESCAPES_ROOT : `More '..' than there is path above it.`
*>
fn String? absolute_path(String path, String from, Allocator allocator)
{
	@pool()
	{
		String joined = path.starts_with("/") ? path : string::tformat("%s/%s", from, path);
		String? inside = js::resolve_module("", joined, tmem);
		if (catch err = inside)
		{
			// Nothing left once `.` and `..` are applied is the top of the disk.
			if (err == js::MODULE_SPECIFIER_IS_EMPTY) return "/".copy(allocator);
			return err~;
		}
		return string::format(allocator, "/%s", inside);
	};
}

<*
 A path from the command line made absolute against the working directory.

 @param path : `As typed.`
 @return `Absolute and normalized, allocated in the caller's allocator.`
 @return? js::MODULE_ESCAPES_ROOT, path::cwd!
*>
fn String? from_working_directory(String path, Allocator allocator)
{
	if (path.starts_with("/")) return absolute_path(path, "/", allocator);
	@pool()
	{
		return absolute_path(path, (String)path::tcwd()!, allocator);
	};
}

<*
 The folder a file is in: "/" for a file at the top of the disk.

 @param file : `Absolute and normalized.`
*>
fn String folder_of(String file)
{
	sz cut = last_separator(file);
	return cut > 0 ? file[:(usz)cut] : "/";
}
