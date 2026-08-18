<*
 `import` from a game's own JavaScript, confined to the assets directory.

 `game.md` G1/S2. A `--assets` boot evaluates `main.js` as an ES module, so the
 program a person writes is many files rather than one, and `quickjs.c3l`'s
 module loader calls back into this file to answer two questions: what does this
 specifier mean, and what are its bytes.

 ## Specifiers are root-relative, and that is the containment

 What crosses to the engine is never a filesystem path — it is a path *within
 the assets root*: `main.js`, `enemies/orc.js`. `resolve_module` is what produces
 them, and it is a pure function over two strings with no filesystem in it at
 all, which is the only reason the containment is under test in a suite that
 has no game directory to point at.

 Two consequences worth stating:

 - **`..` past the root is refused rather than clamped.** Clamping would make
   `../../etc/passwd` resolve to `etc/passwd` and then fail as *"could not load"*,
   which reads as a missing file and teaches a script author the wrong thing.
   Refusing says what happened.
 - **A leading `/` is rooted at the assets directory, not at the disk.** A game
   that writes `import '/lib/math.js'` means its own `lib/`, and that is the
   only root a script has. This is also what makes the obvious attack boring:
   `/etc/passwd` resolves to `etc/passwd` under the assets root and simply is
   not there.

 **Containment is lexical, not `realpath`.** A symlink inside the assets
 directory pointing outside it is followed. That is deliberate: the assets
 directory is the game author's own, a symlink in it is something they put
 there, and resolving links would make a specifier's meaning depend on the
 filesystem in a way no error message could explain. The boundary this enforces
 is against a *script* reaching out, which is the one that can be written by
 accident.

 ## The prelude stays a global

 `three` is not a module and there is no `import three from 'three'`. The
 prelude is evaluated as global source before any of this runs, modules see
 globals, and `import` is for the game's own code. `plan.md` §4's rule about
 half-matching an API somebody has memorised applies to a second way of reaching
 the same object as much as it does to a renamed method.
*>
module three;

import std::io;
import std::io::file;
import qjs;

faultdef
	MODULE_SPECIFIER_IS_EMPTY,
	MODULE_ESCAPES_ASSETS_ROOT,
	MODULE_PATH_TOO_DEEP,
	MODULE_IS_NOT_A_FILE,
	MODULE_IS_TOO_LARGE;

<*
 Directory components a specifier may have.

 Sixty-four is far past anything a person nests and keeps `resolve_module` free
 of an allocation, which is what lets it run inside the engine's normalize
 callback without a pool open.
*>
const usz MAX_MODULE_PARTS = 64;

<*
 The most a single module may be.

 A `.js` file is text somebody typed; four megabytes of it is a mistake — a
 bundled library, or a `.glb` renamed — and reading it into the engine's heap
 would spend a sixteenth of `JS_MEMORY_LIMIT` before the parse starts.
*>
const usz MAX_MODULE_BYTES = 4 * 1024 * 1024;

<*
 Resolve `name`, as written in an import, against `base`, the module writing it.

 Both are root-relative and so is the answer: `resolve_module("enemies/orc.js",
 "../shared/hp.js")` is `shared/hp.js`.

 **No extension is guessed.** `import './player'` does not find `player.js`,
 exactly as it does not in a browser or in Node's ESM mode. Guessing would make
 a specifier's meaning depend on what happens to be on disk, and the habit does
 not survive contact with any other runtime.

 @param base : `The importer's own root-relative specifier. Its last component is a filename and is dropped.`
 @param name : `The specifier as written. A leading '/' roots it at the assets directory.`
 @return `Root-relative, '/'-separated, allocated in the caller's allocator.`
 @return? MODULE_SPECIFIER_IS_EMPTY : `An import of "".`
 @return? MODULE_ESCAPES_ASSETS_ROOT : `More '..' than there was path to climb.`
 @return? MODULE_PATH_TOO_DEEP : `More than MAX_MODULE_PARTS components.`
*>
fn String? resolve_module(String base, String name, Allocator allocator)
{
	if (name.len == 0) return MODULE_SPECIFIER_IS_EMPTY~;

	String[MAX_MODULE_PARTS] parts;
	usz count = 0;

	// The importer's directory, unless the specifier is rooted. `base`'s last
	// component is the importing file and is never part of what it resolves
	// against — "enemies/orc.js" imports relative to "enemies/".
	if (name[0] != '/')
	{
		usz cut = 0;
		bool has_dir = false;
		foreach (i, c : base)
		{
			if (c == '/') { cut = (usz)i; has_dir = true; }
		}
		if (has_dir) push_parts(base[:cut], &parts, &count)!;
	}

	push_parts(name, &parts, &count)!;
	if (count == 0) return MODULE_SPECIFIER_IS_EMPTY~;

	usz length = count - 1; // the separators
	for (usz i = 0; i < count; i++) length += parts[i].len;

	DString joined;
	joined.init(allocator, (sz)(length + 1));
	for (usz i = 0; i < count; i++)
	{
		if (i > 0) joined.append_char('/');
		joined.append_string(parts[i]);
	}
	return joined.copy_str(allocator);
}

<*
 Split `text` on '/' onto the stack, applying `.` and `..` as they arrive.

 Applied *during* the walk rather than after it, which is what makes an escape
 detectable: `a/../../b` has as many components as `a/b` by the time anyone
 counts, and only the order says one of them left the root.
*>
fn void? push_parts(String text, String[MAX_MODULE_PARTS]* parts, usz* count) @local
{
	usz start = 0;
	for (usz i = 0; i <= text.len; i++)
	{
		if (i < text.len && text[i] != '/') continue;

		String part = text[start:i - start];
		start = i + 1;

		// An empty component is a doubled or trailing slash. Harmless, and
		// dropping it silently is what every other resolver does.
		if (part.len == 0 || part == ".") continue;

		if (part == "..")
		{
			if (*count == 0) return MODULE_ESCAPES_ASSETS_ROOT~;
			(*count)--;
			continue;
		}

		if (*count >= MAX_MODULE_PARTS) return MODULE_PATH_TOO_DEEP~;
		(*parts)[*count] = part;
		(*count)++;
	}
}

<*
 The file a root-relative specifier names.

 Joined rather than resolved: `resolve_module` has already removed every `.`
 and `..`, so this is a concatenation and not a second chance to escape.
*>
fn String module_path(String root, String specifier, Allocator allocator)
{
	return string::format(allocator, "%s/%s", root, specifier);
}

<*
 Where `three.load("kit.glb")` reads from.

 In a `--assets` boot a path is relative to the assets directory and confined to
 it, by exactly the rule an `import` follows — `resolve_module` with no importer
 — so the paths `three.inventory()` hands back are paths `three.load` accepts,
 and a game directory can be moved or renamed without editing a line inside it.
 Before this they were two different conventions and the first line of every game
 was the one that found that out.

 Without an assets root the path is used as written. That is the `--mcp` and CLI
 case: there is no directory for it to be relative to, an agent naming a file
 names it from wherever the process was started, and confining it to nothing
 would refuse every path there is.

 @param path : `As the script wrote it. A leading '/' means the assets directory, not the filesystem's.`
 @return `The path to open, allocated in the caller's allocator.`
 @return? MODULE_SPECIFIER_IS_EMPTY : `An empty path.`
 @return? MODULE_ESCAPES_ASSETS_ROOT : `More '..' than there was path to climb.`
 @return? MODULE_PATH_TOO_DEEP : `More than MAX_MODULE_PARTS components.`
*>
fn String? JsRuntime.resolve_asset(&self, String path, Allocator allocator)
{
	if (self.assets_root.len == 0) return path.copy(allocator);
	String specifier = resolve_module("", path, allocator)!;
	return module_path(self.assets_root, specifier, allocator);
}

<*
 Read a module's bytes into the runtime's reusable buffer.

 One buffer, overwritten by every load, which `quickjs.c3l`'s loader documents
 as correct because the shim copies before compiling — and it copies because
 module loads nest, so a buffer that were merely borrowed would be overwritten
 by the imports of the module being compiled out of it.

 @return? MODULE_IS_NOT_A_FILE : `Nothing there, or a directory.`
 @return? MODULE_IS_TOO_LARGE : `Over MAX_MODULE_BYTES.`
*>
fn String? JsRuntime.read_module(&self, String specifier)
{
	@pool()
	{
		String path = module_path(self.assets_root, specifier, tmem);
		if (!file::is_file(path)) return MODULE_IS_NOT_A_FILE~;

		char[]? bytes = file::load(mem, path);
		if (catch bytes) return MODULE_IS_NOT_A_FILE~;
		if (bytes.len > MAX_MODULE_BYTES)
		{
			free(bytes);
			return MODULE_IS_TOO_LARGE~;
		}

		if (self.module_source.len > 0) free(self.module_source);
		self.module_source = bytes;
		return (String)self.module_source;
	};
}

<*
 The engine asking what a specifier means. `quickjs::ModuleNormalizeFn`.

 Writes into the engine's buffer and answers zero, or refuses — and a refusal
 arrives in JavaScript as a `ReferenceError` naming both the specifier and the
 module that wrote it, which is everything an author needs to fix it.
*>
fn int js_module_normalize(ZString base, ZString name, char* out, usz out_size, void* opaque) @local
{
	JsRuntime* self = (JsRuntime*)opaque;
	if (self.assets_root.len == 0) return -1;

	@pool()
	{
		String? resolved = resolve_module(base.str_view(), name.str_view(), tmem);
		if (catch resolved) return -1;
		if (resolved.len + 1 > out_size) return -1;

		for (usz i = 0; i < resolved.len; i++) out[i] = resolved[i];
		out[resolved.len] = 0;
		return 0;
	};
}

<*
 The engine asking for a module's bytes. `quickjs::ModuleLoadFn`.
*>
fn char* js_module_load(ZString name, usz* len_out, void* opaque) @local
{
	JsRuntime* self = (JsRuntime*)opaque;

	String? source = self.read_module(name.str_view());
	if (catch source) return null;

	*len_out = source.len;
	return (char*)source.ptr;
}

<*
 Point `import` at a directory, and let modules resolve.

 Until this is called there is no root and every import is refused, which is
 what an `--mcp`-only run wants: `run_script` is not a module and has no
 directory to be relative to.

 **`module_hooks` lives on the runtime and is addressed by the engine**, so it
 must not move for as long as the context is open. That is the same requirement
 `main.c3` already meets for the `Renderer` the server holds.

 @param root : `The assets directory. Copied.`
*>
fn void JsRuntime.set_assets_root(&self, String root)
{
	if (self.assets_root.len > 0) self.assets_root.free(mem);
	self.assets_root = root.copy(mem);

	// A directory that boots is a game, and a game's frames are warned about
	// rather than killed. `js/frame_loop.c3` carries the argument.
	self.game_frames = true;

	self.module_hooks = {
		.normalize = &js_module_normalize,
		.load = &js_module_load,
		.opaque = self,
	};
	self.js.on_modules(&self.module_hooks);
}
