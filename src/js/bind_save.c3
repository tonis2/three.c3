<*
 `three.save` — the one place a script may write outside its own directory.

 Everything else a game touches is confined to the assets root, in or out:
 `js/modules.c3` resolves `import`, `three.load` and `three.writeText` inside it
 and refuses to leave, which is what makes a game directory relocatable and
 what keeps an agent's `run_script` from being an arbitrary file writer. A
 save game cannot live there. An install directory is not writable on every
 platform, a Steam depot is replaced wholesale by an update, and a player
 expects their progress to survive both.

 So the sandbox widens, once, and as narrowly as it can:

 - **One directory**, `<platform state dir>/three.c3/<slug>`, named by
 `three.configure({ saveDir })` or derived from the assets directory's own name.
 See `paths.c3` for which directory that is per platform, and why saves go to
 the state root rather than the cache one.
 - **A flat namespace.** A save is named, not pathed. `slot1` is a file in that
 directory; `../../etc/passwd`, `a/b` and `.` are refused by `valid_slot` before
 anything opens. There is no way to express a subdirectory and so no way to
 express an escape.
 - **Nothing implicit.** With no `saveDir` configured and no assets root to fall
 back on, every verb here fails and says to call `three.configure`. Inventing a
 folder would put a player's saves somewhere nobody could find twice.

 ## The verbs are bytes and text; the JSON is the prelude's

 `saveWriteText`/`saveReadText` move a string, and `three.save.write`/`read`
 stringify and parse around them in `prelude/api.js`. Keeping `JSON` on that
 side means a game that wants its own format — a binary blob, a line-oriented
 log — is using the same two verbs rather than working around a third.

 Reading bytes is two calls, `saveSize` then `saveReadInto`, and that is not an
 economy. `Engine.buffer` hands the engine memory the *host* owns and does not
 copy, so a `Uint8Array` made over a file this function loaded would be a view
 into a temp allocation that is gone by the time the script reads it. Filling an
 array the script already owns has no such window, and the prelude hides the
 pair behind `three.save.readBytes`.
*>
module three;

import std::io::file;
import std::io::path;
import fastjs::js;

fn void? JsRuntime.bind_save_verbs(&self, js::Value host)
{
	self.js.@bind(host, "saveDirSet", &js_save_dir_set, self)!;
	self.js.@bind(host, "saveDirGet", &js_save_dir_get, self)!;
	self.js.@bind(host, "saveWriteText", &js_save_write_text, self)!;
	self.js.@bind(host, "saveReadText", &js_save_read_text, self)!;
	self.js.@bind(host, "saveWriteBytes", &js_save_write_bytes, self)!;
	self.js.@bind(host, "saveSize", &js_save_size, self)!;
	self.js.@bind(host, "saveReadInto", &js_save_read_into, self)!;
	self.js.@bind(host, "saveList", &js_save_list, self)!;
	self.js.@bind(host, "saveRemove", &js_save_remove, self)!;
}

// Long enough for a descriptive slot name and short enough that the whole path
// stays inside what every filesystem takes.
const usz SAVE_NAME_MAX = 64;

<*
 Whether a name may become a file in the save directory.

 An allowlist rather than a search for `..`: letters, digits, dash, underscore
 and dot, with a first character that is not a dot. That refuses `..` and `.`
 without naming them, refuses every separator on every platform, refuses the
 Windows device names' colon, and refuses a leading dot — which is not an escape
 but is a file `three.save.list()` would show and a file manager would not.
*>
fn bool valid_slot(String name)
{
	if (name.len == 0 || name.len > SAVE_NAME_MAX) return false;
	if (name[0] == '.') return false;
	foreach (c : name)
	{
		bool ok = (c >= 'a' && c <= 'z')
			|| (c >= 'A' && c <= 'Z')
			|| (c >= '0' && c <= '9')
			|| c == '-' || c == '_' || c == '.';
		if (!ok) return false;
	}
	return true;
}

<*
 The directory saves go in, made if it is not there yet.

 Answered in this order, and cached in `save_dir` once it is:

 1. What `three.configure({ saveDir })` named.
 2. The assets directory's own last component, for a game that never configured
 one. `--assets ./wumpa-run` then saves under `wumpa-run`, which is the answer a
 person would have guessed.

 A `--script` or `--mcp` run reaches neither and gets the fault. That is the
 case where there is nothing to name a folder after, and a folder named after
 nothing is one a player never finds again.

 @return ? SAVE_DIR_UNSET : `Nothing has named a save directory and there is no assets root to name one after.`
 @return ? SAVE_DIR_UNAVAILABLE : `There is a name and no writable place to put it — no home directory, or a state root that cannot be created.`
*>
fn String? JsRuntime.save_directory(&self)
{
	if (self.save_dir.len() > 0) return self.save_dir.str_view();

	String root = self.modules.root;
	if (root.len == 0) return SAVE_DIR_UNSET~;

	// The last component, with any trailing separator ignored: `--assets ./game/`
	// and `--assets ./game` are the same directory and must be the same folder.
	usz end = root.len;
	while (end > 0 && (root[end - 1] == '/' || root[end - 1] == '\\')) end--;
	usz start = (usz)(last_separator(root[:end]) + 1);
	String slug = root[start:end - start];
	if (!valid_slot(slug)) return SAVE_DIR_UNSET~;

	return self.set_save_directory(slug);
}

<*
 Points saves at `<state>/three.c3/<slug>` and makes the directory.

 Made rather than checked, because the first write would have to make it anyway
 and a game that configures at boot should learn at boot that it cannot save —
 not three hours in, at a checkpoint.

 @param slug : `Already checked by valid_slot.`
 @return ? SAVE_DIR_UNAVAILABLE : `No state directory on this machine, or it could not be created.`
*>
fn String? JsRuntime.set_save_directory(&self, String slug)
{
	@pool()
	{
		String? state = user_state_dir(tmem);
		if (catch state) return SAVE_DIR_UNAVAILABLE~;

		String full = string::tformat("%s/%s", state, slug);
		if (catch path::mkdir((Path)full, recursive: true)) return SAVE_DIR_UNAVAILABLE~;

		self.save_dir.clear();
		self.save_dir.append_string(full);
	};
	return self.save_dir.str_view();
}

<*
 One save's path, or the reason there is none.

 Every verb below starts here, so the four ways of failing — no directory, an
 unwritable one, a bad name, and a name that is fine — are decided in one place
 and read the same in every message.
*>
fn String? JsRuntime.save_path(&self, String name, Allocator allocator)
{
	if (!valid_slot(name)) return SAVE_NAME_REFUSED~;
	String dir = self.save_directory()!;
	return string::format(allocator, "%s/%s", dir, name);
}

excuse SAVE_DIR_UNSET, SAVE_DIR_UNAVAILABLE, SAVE_NAME_REFUSED;

<*
 Throws the sentence a script sees for one of the three faults.

 Written out rather than printed from the fault name because each has a
 different next step, and the one a game author hits most — nothing configured —
 has to name the call that fixes it.
*>
fn fault JsRuntime.save_fault(&self, fault err, String verb)
{
	switch (err)
	{
		case SAVE_NAME_REFUSED:
			return self.js.fail("%s wants a save name of letters, digits, dash, underscore or dot — at most %d of them, "
				"not starting with a dot. A save is a NAME and not a path: there are no subdirectories "
				"under the save folder and no way to leave it.",
				verb, SAVE_NAME_MAX);
		case SAVE_DIR_UNSET:
			return self.js.fail("%s has nowhere to write: no save folder has been named. Call "
				"three.configure({ saveDir: 'my-game' }) at the top of main.js. A game booted with "
				"--assets takes the directory's own name when it says nothing; a --script or --mcp run "
				"has no directory to be named after and has to be told.",
				verb);
		default:
			return self.js.fail("%s could not open the save folder. There is no writable application-data directory on this "
				"machine — no home directory, or one that refused to be written to.",
				verb);
	}
}

<*
 One save's path, or the thrown sentence when there is none.

 @return? js::THREW
*>
fn String? JsRuntime.save_path_for(&self, String name, String verb)
{
	String? where = self.save_path(name, tmem);
	if (catch err = where) return self.save_fault(err, verb)~;
	return where;
}

<*
 `saveDirSet(name)` — name the folder, and answer with where it actually is.

 The path comes back rather than a bool so that a game can print it, put it in a
 support message, or show it in a menu. Nobody should have to know this file's
 rules to find their own saves.

 @return? js::THREW
*>
fn String? js_save_dir_set(JsRuntime* self, String name)
{
	if (!valid_slot(name)) return self.save_fault(SAVE_NAME_REFUSED, "three.configure({ saveDir })")~;

	String? where = self.set_save_directory(name);
	if (catch err = where) return self.save_fault(err, "three.configure({ saveDir })")~;
	return where;
}

<*
 `saveDirGet()` — where saves go, or null when nothing has decided yet.

 Null rather than a throw, because this is the verb a settings screen calls to
 decide whether to show a "saves are here" line at all.

 @return? js::THREW
*>
fn js::Value? js_save_dir_get(JsRuntime* self)
{
	String? dir = self.save_directory();
	if (catch dir) return js::NULL;
	return self.js.string(dir);
}

<*
 @return? js::THREW
*>
fn bool? js_save_write_text(JsRuntime* self, String name, String body)
{
	String where = self.save_path_for(name, "three.save.write")!;
	if (catch err = file::save(where, (char[])body))
	{
		return self.js.fail("three.save.write could not write %s: %s", where, err)~;
	}
	return true;
}

<*
 `saveReadText(name)` — the file as a string, or null when there is none.

 Null and not a throw: "no save yet" is the first-run case of every game there
 has ever been, and a game should not have to guard a `try` around its own cold
 start. A file that exists and cannot be read *does* throw — that is a disk
 saying something, not an absence.

 @return? js::THREW
*>
fn js::Value? js_save_read_text(JsRuntime* self, String name)
{
	String where = self.save_path_for(name, "three.save.read")!;
	if (!file::is_file(where)) return js::NULL;

	char[]? bytes = file::load(tmem, where);
	if (catch err = bytes) return self.js.fail("three.save.read could not read %s: %s", where, err)~;
	return self.js.string((String)bytes);
}

<*
 @return? js::THREW
*>
fn bool? js_save_write_bytes(JsRuntime* self, String name, char[] body)
{
	String where = self.save_path_for(name, "three.save.writeBytes")!;
	if (catch err = file::save(where, body))
	{
		return self.js.fail("three.save.writeBytes could not write %s: %s", where, err)~;
	}
	return true;
}

<*
 `saveSize(name)` — how many bytes the file holds, or -1 when there is none.

 The first half of `three.save.readBytes`. A number rather than a fault for the
 absent case, for `saveReadText`'s reason.

 @return? js::THREW
*>
fn long? js_save_size(JsRuntime* self, String name)
{
	String where = self.save_path_for(name, "three.save.readBytes")!;
	return path::file_size((Path)where) ?? -1;
}

<*
 `saveReadInto(name, target)` — fills a `Uint8Array` the script owns.

 The second half of `three.save.readBytes`, and the reason the pair exists: the
 bytes are copied into memory JavaScript already holds, so nothing in here has
 to outlive the call. A target shorter than the file takes as much as it has
 room for, and the count comes back so the prelude can trim.

 @return? js::THREW
*>
fn usz? js_save_read_into(JsRuntime* self, String name, char[] target)
{
	String where = self.save_path_for(name, "three.save.readBytes")!;
	if (target.len == 0) return 0;

	char[]? bytes = file::load(tmem, where);
	if (catch err = bytes) return self.js.fail("three.save.readBytes could not read %s: %s", where, err)~;

	usz moved = bytes.len < target.len ? bytes.len : target.len;
	if (moved > 0) mem::copy(target.ptr, bytes.ptr, (sz)moved);
	return moved;
}

<*
 `saveList()` — the names in the save folder, in whatever order the disk gives.

 An empty array for a folder with nothing in it *and* for a run that never
 named one: listing is the verb a menu calls before anything has been saved, and
 a throw there would make every game's load screen guard a call that means "no".

 @return? js::THREW
*>
fn js::Value? js_save_list(JsRuntime* self)
{
	js::Value names = self.js.array()!;
	@pool()
	{
		String? dir = self.save_directory();
		if (catch dir) return names;

		PathList? found = path::ls(tmem, (Path)dir, no_dirs: true);
		if (catch found) return names;

		foreach (entry : found)
		{
			String name = entry.basename();
			// The same rule the writers follow, applied on the way out: whatever
			// else is in that directory, this lists what `three.save` could have
			// put there and what it will accept back.
			if (!valid_slot(name)) continue;
			self.js.push(names, self.js.string(name)!);
		}
	};
	return names;
}

<*
 `saveRemove(name)` — delete one, and answer with whether there was one.

 False rather than a throw for a name that was not there, so deleting a slot
 twice is not an error a menu has to handle.

 @return? js::THREW
*>
fn bool? js_save_remove(JsRuntime* self, String name)
{
	String where = self.save_path_for(name, "three.save.remove")!;
	if (!file::is_file(where)) return false;
	if (catch err = path::delete((Path)where))
	{
		return self.js.fail("three.save.remove could not delete %s: %s", where, err)~;
	}
	return true;
}
