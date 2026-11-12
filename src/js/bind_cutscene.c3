<*
 What `three.cutscene` needs from the host to play a `.cutscene.glb`.

 Three verbs, because the prelude does the rest: `gltfJson` hands over the
 file's JSON, whose `CUSTOM_cutscene` extension the prelude turns into the spec
 `Cutscene` already plays, and `cutsceneClip` / `cutsceneDropClip` put a one-off
 clip on an actor's asset and take it off again — `scene/cutscene.c3`.
*>
module three;

import std::io;
import std::io::file;
import std::io::path;
import fastjs::js;
import gltf;

// More JSON than any cutscene or level writes, and less than a mistake would cost.
const usz GLTF_JSON_LIMIT = 64 * 1024 * 1024;

excuse NOT_GLTF, GLTF_JSON_TOO_BIG;

fn void? JsRuntime.bind_cutscene_verbs(&self, js::Value host)
{
	self.js.@bind(host, "gltfJson", &js_gltf_json, self)!;
	self.js.@bind(host, "cutsceneClip", &js_cutscene_clip, self)!;
	self.js.@bind(host, "cutsceneDropClip", &js_cutscene_drop_clip, self)!;
}

<*
 A path the script wrote, resolved the way `three.load` resolves it.

 @return? js::THREW
*>
fn String? readable_path(JsRuntime* self, String asked) @local
{
	String? opening = self.resolve_asset(asked, tmem);
	if (catch err = opening)
	{
		if (err == js::MODULE_ESCAPES_ROOT)
		{
			return self.js.fail("cannot read '%s': it climbs out of the assets directory, and a game may only read "
				"what is inside its own",
				asked)~;
		}
		return self.js.fail("cannot read '%s': %s", asked, err)~;
	}
	return opening;
}

<*
 The JSON of a `.glb` (its first chunk) or of a `.gltf` (the whole file), told
 apart by the magic rather than the extension.

 @param [&inout] f : "Open at its start"
 @return? NOT_GLTF, GLTF_JSON_TOO_BIG
*>
fn char[]? read_gltf_json(File* f, usz size, Allocator allocator) @local
{
	char[20] head;
	usz got = size < 20 ? size : 20;
	if (got > 0 && (usz)f.read(head[:got])! != got) return NOT_GLTF~;
	if (got < 4 || head[0..3] != "glTF")
	{
		if (size > GLTF_JSON_LIMIT) return GLTF_JSON_TOO_BIG~;
		f.seek(0)!;
		char[] text = alloc::new_array(allocator, char, (sz)size);
		if (size > 0 && (usz)f.read(text)! != size) return NOT_GLTF~;
		return text;
	}

	if (got < 20) return NOT_GLTF~;
	uint version = bitcast(*(char[4]*)head[4..7], uint);
	uint length = bitcast(*(char[4]*)head[12..15], uint);
	if (version != 2 || head[16..19] != "JSON") return NOT_GLTF~;
	if ((usz)length > GLTF_JSON_LIMIT) return GLTF_JSON_TOO_BIG~;
	if ((usz)length > size - 20) return NOT_GLTF~;
	char[] chunk = alloc::new_array(allocator, char, length);
	if (length > 0 && (usz)f.read(chunk)! != (usz)length) return NOT_GLTF~;
	return chunk;
}

<*
 `gltfJson(path)` — the JSON document of a `.glb` or `.gltf`, as text, or null for
 a file that is not there.

 Text rather than an object so the prelude's `JSON.parse` says what is wrong with a
 broken one. Only the JSON is read: the binary chunk of a `.glb` stays on disk.

 @return? js::THREW
*>
fn js::Value? js_gltf_json(JsRuntime* self, String asked)
{
	if (asked.len == 0) return self.js.fail("three.cutscene.load(path) wants a path to a .glb or a .gltf")~;
	String opening = readable_path(self, asked)!;
	if (!file::is_file(opening)) return js::NULL;

	long? size = path::file_size((Path)opening);
	if (catch err = size) return self.js.fail("could not read %s: %s", self.blame(asked, opening), err)~;
	File? opened = file::open(opening, "rb");
	if (catch err = opened) return self.js.fail("could not read %s: %s", self.blame(asked, opening), err)~;
	File f = opened;
	defer (void)f.close();

	char[]? json = read_gltf_json(&f, (usz)size, tmem);
	if (catch err = json)
	{
		if (err == GLTF_JSON_TOO_BIG)
		{
			return self.js.fail("%s holds more than %d bytes of JSON, which is no cutscene", self.blame(asked, opening),
				GLTF_JSON_LIMIT)~;
		}
		return self.js.fail("%s is not a glTF file — a cutscene is a .glb or a .gltf written by the Blender exporter",
			self.blame(asked, opening))~;
	}
	// glTF pads its JSON chunk with spaces; some writers use zeros.
	usz end = json.len;
	while (end > 0 && (json[end - 1] == 0 || json[end - 1] == ' ')) end--;
	if (!is_utf8_text(json[:end])) return self.js.fail("%s is not a glTF file: its JSON is not UTF-8", self.blame(asked, opening))~;
	return self.js.string((String)json[:end]);
}

<*
 `cutsceneClip(path, animation, asset, anchor, stub, clip, row)` — animation
 `animation` of the cutscene at `path`, put on `asset` as a clip of its own, and
 the name it plays under.

 `stub` is the actor's stub node in the file and `anchor` the asset node the live
 object came from, or -1 for a whole file instantiated as a group. `clip` is the
 name it should play under, suffixed when the asset already has one by that name;
 `row` is only for the sentences.

 @return? js::THREW
*>
fn String? js_cutscene_clip(JsRuntime* self, String asked, uint animation, AssetId asset, int anchor, uint stub,
	String clip, String row)
{
	String opening = readable_path(self, asked)!;
	gltf::GltfStream? opened = gltf::open(opening);
	if (catch err = opened) return self.js.fail("could not read the cutscene %s: %s", self.blame(asked, opening), err)~;
	gltf::GltfStream file = opened;
	defer file.close();

	if (animation >= file.gltf.animations.len())
	{
		return self.js.fail("the one-off clip '%s' is animation %d of %s, which has %d", clip, animation, asked,
			file.gltf.animations.len())~;
	}
	if (stub >= file.gltf.nodes.len())
	{
		return self.js.fail("actor '%s' has its stub at node %d of %s, which has %d nodes", row, stub, asked,
			file.gltf.nodes.len())~;
	}

	Asset* actor = self.pass.assets.slot(asset);
	uint unbound = stub;
	AnimationClip? read = read_one_off(&file, animation, actor, stub, anchor, &unbound);
	if (catch err = read)
	{
		String moved = unbound < file.gltf.nodes.len() ? file.gltf.nodes[unbound].name : "";
		if (err == STUB_NOT_FOUND)
		{
			return self.js.fail("the one-off clip '%s' in %s moves '%s', and actor '%s' (from %s) has no node by that "
				"name — a bone renamed since the cutscene was exported, or the wrong object for the row",
				clip, asked, moved, row, actor.path)~;
		}
		if (err == STUB_OUTSIDE_ACTOR)
		{
			return self.js.fail("the one-off clip '%s' in %s moves node %d ('%s'), which is not actor '%s''s stub or "
				"under it, so it cannot be bound to the actor",
				clip, asked, unbound, moved, row)~;
		}
		return self.js.fail("could not read the one-off clip '%s' from %s: %s", clip, self.blame(asked, opening), err)~;
	}

	AnimationClip made = read;
	made.name = free_clip_name(actor, clip);
	int at = self.pass.assets.add_clip(asset, made);
	return self.pass.assets.slot(asset).clips[at].name;
}

<*
 `cutsceneDropClip(asset, name)` — takes a clip `cutsceneClip` added off the asset
 again, letting go of it on every character playing it first.

 False rather than a throw for an asset already gone: it took its clips with it,
 and a cutscene disposed after its actors' file was unloaded has nothing to undo.

 @return? js::THREW
*>
fn bool? js_cutscene_drop_clip(JsRuntime* self, js::Value handle, String name)
{
	void* data = js::data_of(handle, self.asset_class);
	if (!data) return self.js.fail("cutsceneDropClip(asset, name) wants an asset")~;
	AssetId id = unpack_id(data, AssetId);
	Asset* owner = self.pass == null ? null : self.pass.assets.slot(id);
	if (owner == null) return false;

	int found = owner.find_clip(name);
	if (found < 0 || !owner.clips[found].added) return false;

	// Every character lets go while the clip still says which nodes it drove,
	// then what is left on their stacks is posed against the shorter list.
	foreach (scene : self.pass.scenes)
	{
		foreach (&player : scene.players)
		{
			if (player.asset == id) player.forget_clip(scene, owner, (uint)found);
		}
	}
	self.pass.assets.remove_clip(id, (uint)found);
	owner = self.pass.assets.slot(id);
	foreach (scene : self.pass.scenes)
	{
		foreach (&player : scene.players)
		{
			if (player.asset == id && player.layer_count > 0) player.pose(scene, owner);
		}
		scene.update_sockets();
	}
	return true;
}
