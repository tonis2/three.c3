<*
 `three.load()`, `three.BoxGeometry()` and what an asset can be asked about.

 The smallest set of verbs that lets `prelude.js` build an `Asset` whose
 `mesh(name)` lookup happens in JavaScript: the load itself, the path back, the
 mesh names in order, one shape builder for all five parametric kinds, and the
 hull of a point cloud. Resolving a name to an index on this side would be a
 second implementation of a search the host already has; handing the names over
 once also means `asset.meshes` is something a script can print when it has
 guessed a name wrong.

 Loading the same path twice returns the same asset, because `Assets.load` does —
 the coarse half of "linked, not duplicated" — so a script that loads a kit in a
 loop pays once. `primitive` obeys the same rule against a key made of its
 parameters, which is what makes a thousand `new three.BoxGeometry(1, 1, 1)` one
 upload and one draw call.

 Every verb that makes an asset answers with its `AssetId`, which reaches a script
 as the one `Asset` handle object for that id, and every verb that reads one takes
 that handle back.
*>
module three;

import std::math;
import std::math::vector;
import fastjs::js;
import fastjs::js::opt;
import image;
import image::png;
import std::collections::list;
import std::io::file;
import std::io::path;

fn void? JsRuntime.bind_asset_verbs(&self, js::Value host)
{
	self.js.@bind(host, "load", &js_load, self)!;
	self.js.@bind(host, "texture", &js_texture, self)!;
	self.js.@bind(host, "dataTexture", &js_data_texture, self)!;
	self.js.@bind(host, "textureDispose", &js_texture_dispose, self)!;
	self.js.@bind(host, "textureRead", &js_texture_read, self)!;
	self.js.@bind(host, "textureSave", &js_texture_save, self)!;
	self.js.@bind(host, "primitive", &js_primitive, self)!;
	self.js.@bind(host, "convex", &js_convex, self)!;
	self.js.@bind(host, "extrude", &js_extrude, self)!;
	self.js.@bind(host, "ribbon", &js_ribbon, self)!;
	self.js.@bind(host, "terrain", &js_terrain, self)!;
	self.js.@bind(host, "terrainAt", &js_terrain_at, self)!;
	self.js.@bind(host, "lines", &js_lines, self)!;
	self.js.@bind(host, "wireframe", &js_wireframe, self)!;
	self.js.@bind(host, "checkAsset", &js_check_asset, self)!;
	self.js.@bind(host, "assetPath", &js_asset_path, self)!;
	self.js.@bind(host, "meshNames", &js_mesh_names, self)!;
	self.js.@bind(host, "meshBounds", &js_mesh_bounds, self)!;
	self.js.@bind(host, "assetImages", &js_asset_images, self)!;
	self.js.@bind(host, "assetImage", &js_asset_image, self)!;
	self.js.@bind(host, "uploadMesh", &js_upload_mesh, self)!;
	self.js.@bind(host, "meshLayers", &js_mesh_layers, self)!;
	self.js.@bind(host, "meshMaterial", &js_mesh_material, self)!;
	self.js.@bind(host, "splitMesh", &js_split_mesh, self)!;
	self.js.@bind(host, "merge", &js_merge, self)!;
	self.js.@bind(host, "assetNodes", &js_asset_nodes, self)!;
	self.js.@bind(host, "assetLights", &js_asset_lights, self)!;
	self.js.@bind(host, "assetCameras", &js_asset_cameras, self)!;
	self.js.@bind(host, "assetBodies", &js_asset_bodies, self)!;
	self.js.@bind(host, "assetJoints", &js_asset_joints, self)!;
	self.js.@bind(host, "assetClips", &js_asset_clips, self)!;
	self.js.@bind(host, "assetBones", &js_asset_bones, self)!;
	self.js.@bind(host, "inventory", &js_inventory, self)!;
	self.js.@bind(host, "assetText", &js_asset_text, self)!;
	self.js.@bind(host, "assetWriteText", &js_asset_write_text, self)!;
	self.js.@bind(host, "exportScene", &js_export, self)!;
}

<*
 Throws `what needs a GPU device` when the context has none.

 @return? js::THREW
*>
fn void? need_device(JsRuntime* self, String what) @local
{
	if (self.renderer == null) return self.js.fail("%s needs a GPU device and this context has none", what)~;
}

// A number out of a flat argument, with a finite backstop: the prelude refuses a
// non-finite component by name, and this is what a forged call gets instead of a
// NaN spreading into its neighbours.
fn float finite(float number, float fallback = 0) @local @inline => math::is_finite(number) ? number : fallback;

<*
 `load(path)` — the asset, for `add`.

 The device is required, and the message says so rather than throwing something
 about a null pointer: a runtime built for the scene-math tests has no GPU, and a
 script that reaches for a file in one should be told which of the two it is
 missing.

 @return? js::THREW
*>
fn AssetId? js_load(JsRuntime* self, String path)
{
	need_device(self, "three.load")!;
	if (path.len == 0) return self.js.fail("three.load(path) wants a path to a .glb or .gltf")~;

	// Relative to the assets directory in a `--assets` boot, and to the working
	// directory otherwise. Resolved before the load so a path reaching out of
	// the game is refused by name rather than opening whatever it found.
	String? opening = self.resolve_asset(path, tmem);
	if (catch err = opening)
	{
		if (err == js::MODULE_ESCAPES_ROOT)
		{
			return self.js.fail("cannot load '%s': it climbs out of the assets directory, and a game may only read "
				"what is inside its own",
				path)~;
		}
		return self.js.fail("cannot load '%s': %s", path, err)~;
	}

	AssetId? asset = self.pass.assets.load(&self.renderer.gpu, opening);
	if (catch err = asset)
	{
		// The fault name verbatim: ASSET_HAS_NO_MESHES and the io faults are
		// each a different thing to do about it, and flattening them into
		// "could not load" would cost the agent the one word that says which.
		return self.js.fail("could not load %s: %s", self.blame(path, opening), err)~;
	}
	return asset;
}

<*
 Whether these bytes are text at all.

 Walked with the decoder rather than sniffed, because the cheap tests are the
 wrong ones: a `.glb` is mostly bytes that are individually printable, and a
 file with no NUL in it can still be a Latin-1 export that JavaScript would
 receive as mojibake. What a `String` crossing to JavaScript has to be is valid
 UTF-8, so that is what is asked.

 Overlong forms, surrogates and truncated tails are all refused by
 `utf8_to_char32` itself — this is only the loop over it.
*>
fn bool is_utf8_text(char[] bytes) @local
{
	usz at = 0;
	while (at < bytes.len)
	{
		sz size = (sz)(bytes.len - at);
		Char32? decoded = conv::utf8_to_char32(&bytes[at], &size);
		if (catch decoded) return false;
		if (size <= 0) return false;
		at += (usz)size;
	}
	return true;
}

<*
 `assetText(path)` — a text file from the assets directory, as a string.

 `js_load`'s door with nothing loaded through it. A kit is a `.glb` and the
 level that places it is a list of names and transforms somebody wrote, and
 until this existed the second one had nowhere to live: `three.save` writes
 into `<application data>/three.c3/<slug>`, which is not where the kit is, not
 what a person edits in a repo and not what ships beside the game.

 **The sandbox is `resolve_asset`'s and not a second one.** The same call
 `three.load` and `three.texture` make, so `../../etc/passwd` is refused with
 the same sentence, a leading `/` means the assets directory rather than the
 disk's, and the paths `three.inventory()` hands back are paths this accepts.
 Without an assets root the path is used as written — the `--script`/`--mcp`
 case, where `three.load` reads from wherever the process was started and
 confining to nothing would refuse every path there is.

 **The write door is `js_asset_write_text`, right below.** It goes through
 `resolve_write` rather than `resolve_asset` — the same narrower rule
 `scene.export` writes a `.glb` through — so a script can put a level list back
 where this reads it from without the sandbox growing a second shape.

 Null for a file that is not there, which is `saveReadText`'s answer and not
 `js_load`'s. An editor asking "is there a level here yet" is the ordinary case
 rather than the failure, and a throw would put a `try` around every cold start.
 A file that exists and will not read *does* throw — that is a disk saying
 something.

 Two refusals beyond the path. Anything over `MAX_MODULE_BYTES` is turned away
 by its size before it is read, reusing the loader's own number because this is
 the loader's own directory and a second limit would be a second thing to keep
 in step. And bytes that are not UTF-8 are refused rather than handed over: a
 `String` crossing into JavaScript has to be text, and a `.glb` read by mistake
 should say what it is instead of arriving as a page of replacement characters.

 @return? js::THREW
*>
fn js::Value? js_asset_text(JsRuntime* self, String asked)
{
	if (asked.len == 0) return self.js.fail("three.readText(path) wants a path to a file in the assets directory")~;

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

	if (!file::is_file(opening)) return js::NULL;

	// Asked before the read, so a file nobody meant to open costs a stat and
	// not its own size in the host's heap.
	long? size = path::file_size((Path)opening);
	if (try size && (usz)size > js::MAX_MODULE_BYTES)
	{
		return self.js.fail("'%s' is %d bytes, and three.readText stops at %d — that is a level list or a table, "
			"and a file this big is a mistake or a binary",
			asked, size, js::MAX_MODULE_BYTES)~;
	}

	char[]? bytes = file::load(tmem, opening);
	if (catch err = bytes) return self.js.fail("could not read %s: %s", self.blame(asked, opening), err)~;

	if (!is_utf8_text(bytes))
	{
		return self.js.fail("'%s' is not UTF-8 text — three.readText reads text, and a .glb goes through three.load "
			"and an image through three.texture",
			asked)~;
	}

	return self.js.string((String)bytes);
}

<*
 Makes the folder a path is about to be written into, if it is not there yet.

 The one thing `three.writeText`, `scene.export`, `three.screenshot` and
 `texture.save` do before opening the file, and shared so that the four doors
 cannot drift: `path_tdirname` is the folder, an empty one is the assets root
 itself and needs nothing, and `mkdir` with `recursive` answers false rather
 than failing when the folder already exists.

 `@private` rather than `@local` because `bind_scene.c3` writes a PNG through
 the same door — the same reason `bind_shader.c3`'s `split_commas` is.

 @param writing : `The resolved path, already inside the sandbox.`
*>
fn void? make_way_for(String writing) @private
{
	if (try dir = writing.path_tdirname())
	{
		if (dir.len == 0) return;
		path::mkdir((Path)dir, recursive: true)!;
	}
}

<*
 The whole write door as one call: resolve, refuse an escape by name, make the
 folder that is not there yet.

 `make_way_for`'s argument for existing, one step earlier. `three.screenshot`
 and `texture.save` are two more verbs that write a file the script named, and
 the sentence a refused path gets is the part that must not drift between them:
 it is what tells an author that a sandbox exists, rather than that their path
 was a typo. `three.writeText` and `scene.export` predate this and keep their
 own wording, which names the file kind each of them writes.

 The exception is thrown here, so a caller has only to pass the fault on.

 A method, and so module-visible rather than `@private`: `resolve_write` next
 door is one for the same reason, and `bind_scene.c3` is the other caller.

 @param asked : `The path as the script wrote it, for the sentence.`
 @param verb : `How the script spelled the call — "three.screenshot".`
 @return `The path to open, allocated in the caller's allocator.`
 @return? js::THREW
*>
fn String? JsRuntime.writable_path(&self, String asked, String verb, Allocator allocator)
{
	String? writing = self.resolve_write(asked, allocator);
	if (catch err = writing)
	{
		if (err == js::MODULE_ESCAPES_ROOT)
		{
			return self.js.fail("%s cannot write to '%s': it climbs out of the assets directory, and a game may "
				"only write inside its own",
				verb, asked)~;
		}
		return self.js.fail("%s cannot write to '%s': %s", verb, asked, err)~;
	}

	if (catch err = make_way_for(writing))
	{
		return self.js.fail("%s cannot write to '%s': could not make its folder: %s", verb, asked, err)~;
	}

	return writing;
}

<*
 What a verb that wrote a file answers with: where it landed, how big the image
 is, and how many bytes are on disk.

 One shape for `three.screenshot` and `texture.save` both, because they answer
 the same three questions and an agent that has to remember which one spells it
 `size` has been given a second thing to get wrong. `bytes` is the file rather
 than the pixels — a PNG of a flat colour is a few hundred bytes and one of a
 noise field is megabytes, which is the number that says an encode happened.
*>
struct WrittenImage
{
	String path;
	uint width;
	uint height;
	double bytes;
}

<*
 The answer for a file just written. A file that cannot be stat'd reads 0 bytes
 rather than throwing: the write itself already succeeded, and failing the call
 over the size afterwards would report a file that is on disk as one that is not.
*>
fn WrittenImage written_image(String path, uint width, uint height) @private
{
	WrittenImage described = { .path = path, .width = width, .height = height };
	if (try size = path::file_size((Path)path)) described.bytes = (double)size;
	return described;
}

<*
 `assetWriteText(path, text)` — a text file into the assets directory, and the
 path it landed at.

 `js_asset_text`'s write twin and `js_export`'s text-shaped sibling: the level
 list `three.readText` reads has to come from somewhere, and until this existed
 the only place a script could put it was `<application data>/three.c3/<slug>`
 — precisely the split `js_asset_text`'s doc comment opened this door to close.

 **The sandbox is `resolve_write`'s and not a second one.** The same call
 `scene.export` makes, so `../../etc/passwd` is refused with the same sentence
 (adapted to say write rather than read), a leading `/` means the assets
 directory rather than the disk's, and nothing outside it is ever written.
 Without an assets root the path is used as written, exactly as `scene.export`'s
 is — the `--script`/`--mcp` case, where there is no directory to be relative
 to.

 A missing folder on the way is made, as `three.save` makes its own: the
 first save of a level into a fresh `levels/` is the ordinary case and not a
 mistake, and the sandbox has already said the path is inside the assets
 directory before anything is created. `scene.export` does the same, so the two
 doors agree about who owns that.

 The same `MAX_MODULE_BYTES` `three.readText` stops at bounds the string here,
 checked before the write rather than after: a file this writes is a file
 `three.readText` can read back, and a second, larger limit would make that
 false.

 @return? js::THREW
*>
fn String? js_asset_write_text(JsRuntime* self, String asked, String text)
{
	if (asked.len == 0)
	{
		return self.js.fail("three.writeText(path, text) wants a path to a file in the assets directory")~;
	}

	if (text.len > js::MAX_MODULE_BYTES)
	{
		return self.js.fail("'%s' is %d bytes, and three.writeText stops at %d — that is a level list or a table, "
			"and a file this big is a mistake or a binary",
			asked, text.len, js::MAX_MODULE_BYTES)~;
	}

	String? writing = self.resolve_write(asked, tmem);
	if (catch err = writing)
	{
		if (err == js::MODULE_ESCAPES_ROOT)
		{
			return self.js.fail("cannot write to '%s': it climbs out of the assets directory, and a game may only "
				"write inside its own",
				asked)~;
		}
		return self.js.fail("cannot write to '%s': %s", asked, err)~;
	}

	if (catch err = make_way_for(writing))
	{
		return self.js.fail("could not make the folder for %s: %s", self.blame(asked, writing), err)~;
	}

	if (catch err = file::save(writing, (char[])text))
	{
		return self.js.fail("could not write %s: %s", self.blame(asked, writing), err)~;
	}

	return writing;
}

<*
 Which `ColorSpace` a wire code names.

 The code is the enum's own ordinal and the prelude derives it from Three.js's
 colourspace strings, so this is the one place the two spellings meet. Anything
 unrecognised is `SRGB`: the prelude has already refused a string it does not
 know, so a code arriving here that is neither 0 nor 1 is a host bug.
*>
fn ColorSpace color_space_of(int code) @local
{
	return code == 1 ? ColorSpace.LINEAR : ColorSpace.SRGB;
}

<*
 A texture as JavaScript sees it: `[index, width, height, levels]`.

 The extents are here because the prelude's `Texture` wants them and there is no
 second verb to ask for them: an agent sizing a plane to an image's aspect ratio
 would otherwise have to guess.

 `levels` is what the image really got, not what was asked for. A device that
 cannot blit the format gives one level whatever `generateMipmaps` said, and a
 handle reporting the request rather than the result would make `tex.levels` a
 restatement of the caller's own argument.

 @return? js::THREW
*>
fn js::Value? JsRuntime.texture_handle(&self, int index, Texture* uploaded)
{
	// Counted here because this is the only door. Every verb that hands a texture
	// to a script takes a reference on the way through, and they all come here to
	// build the array — so another one cannot be written that forgets, which is
	// the property a tally kept at the call sites would not have.
	self.hold_texture(index);
	return self.js.numbers({ (double)index, (double)uploaded.width, (double)uploaded.height, (double)uploaded.levels });
}

<*
 One more reference handed to a script, counted against its slot.

 Called by `texture_handle` and nowhere else. The slot index is an ordinary
 position in `Assets.textures`, so the tally is a parallel array that grows to
 whatever the largest live slot is — a table of at most one `uint` per resident
 image, which is smaller than the image's own name.
*>
fn void JsRuntime.hold_texture(&self, int index)
{
	if (index < 0) return;
	while (self.texture_handles.len() <= (sz)index) self.texture_handles.push(0);
	self.texture_handles[index]++;
}

<*
 One given back — `three.texture.dispose()`.

 Clamped at zero rather than trusted. The prelude's `Texture` marks itself dead
 on the first `dispose()` so a second never reaches the host, but the tally is
 what decides how many images get freed when a context ends, and a count that
 could go negative through some path nobody has thought of yet would free an
 image a material is still drawing with. Refusing to go below zero makes the
 worst case a texture that outstays its welcome, which is where this started.
*>
fn void JsRuntime.drop_texture(&self, int index)
{
	if (index < 0 || (sz)index >= self.texture_handles.len()) return;
	if (self.texture_handles[index] == 0) return;
	self.texture_handles[index]--;
}

<*
 Gives back every texture reference the context still holds, on its way out.

 The texture half of `MeshPass.release_script_materials`, and it exists for the
 same reason: a `Texture` is freed by its *handle* being disposed, and a context
 that closes takes every handle with it without disposing one. A reload is where
 that shows — ten of them over an editing session is ten copies of the same
 image resident, none of them named by anything — and process teardown is where
 it does not, because `Assets.free` was going to destroy them anyway.

 It is a *release* and not a free, so a texture a material or a mesh is still
 using stays exactly where it is; what goes is only the reference the script's
 own handle was holding. That is what makes this safe to do unconditionally
 rather than only when nothing else could be pointing at the image.

 The counts are cleared rather than the list freed: `close` frees it a few lines
 later, and a `reset` here would make this unusable from anywhere else.
*>
fn void JsRuntime.release_script_textures(&self)
{
	if (self.pass == null)
	{
		self.texture_handles.clear();
		return;
	}

	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	foreach (i, count : self.texture_handles)
	{
		for (uint held = 0; held < count; held++)
		{
			self.pass.assets.release_texture(gpu, (int)i);
		}
	}
	self.texture_handles.clear();
}

<*
 `texture(path, space, mips, nearest)` — decode a PNG or JPEG and upload it.

 The path goes through `resolve_asset`, the same door `three.load` uses, so under
 `--assets` a texture may only come from inside the game.

 The index is not a generational handle, unlike an asset or a node, and does not
 need to be: the only way a script gets one is the `Texture` the prelude wraps it
 in, that object marks itself dead on `dispose()`, and a second `three.texture()`
 of the same file returns a second object holding a reference of its own. So a
 stale index cannot be presented.

 @return? js::THREW
*>
fn js::Value? js_texture(JsRuntime* self, String path, int space, Opt {bool} mips, Opt {bool} nearest)
{
	need_device(self, "three.texture")!;
	if (path.len == 0) return self.js.fail("three.texture(path) wants a path to a .png or .jpg")~;

	String? opening = self.resolve_asset(path, tmem);
	if (catch err = opening)
	{
		if (err == js::MODULE_ESCAPES_ROOT)
		{
			return self.js.fail("cannot load '%s': it climbs out of the assets directory, and a game may only read "
				"what is inside its own",
				path)~;
		}
		return self.js.fail("cannot load '%s': %s", path, err)~;
	}

	int? index = self.pass.assets.load_texture_file(
		&self.renderer.gpu,
		opening,
		color_space_of(space),
		mips.or(true),
		nearest.or(false)
	);
	if (catch err = index) return self.js.fail("%s", self.texture_failure(err, path, opening))~;

	return self.texture_handle(index, self.pass.assets.texture_at(index));
}

<*
 `dataTexture(bytes, width, height, space, mips, nearest)` — pixels a script
 built.

 The bytes are the script's own array, valid for this call and copied before it
 returns: `claim_texture` hashes them, copies them into a staging buffer and
 uploads, all before control goes back to JavaScript.

 Deduplicated against every other texture, which is the interesting part: pixels
 generated in a script and the identical image loaded from a `.png` are one
 upload, because the hash is over RGBA bytes and has no idea where they came
 from. A script that regenerates the same texture every frame pays for one.

 The size is stated rather than inferred, and checked against the array's length.
 Deriving one from the other cannot tell a 64x64 from a 128x32, so a script that
 had its dimensions the wrong way round would get a skewed picture and no
 complaint.

 @return? js::THREW
*>
fn js::Value? js_data_texture(
	JsRuntime* self,
	char[] pixels,
	int width,
	int height,
	int space,
	Opt {bool} mips,
	Opt {bool} nearest
)
{
	need_device(self, "three.DataTexture")!;

	if (width <= 0 || height <= 0)
	{
		return self.js.fail("new three.DataTexture(data, width, height) wants positive dimensions, got %dx%d",
			width, height)~;
	}
	if (width > MAX_TEXTURE_SIDE || height > MAX_TEXTURE_SIDE)
	{
		return self.js.fail("%dx%d is past the %d-pixel limit three.DataTexture accepts on a side",
			width, height, MAX_TEXTURE_SIDE)~;
	}

	if (pixels.len == 0)
	{
		// The prelude has already widened a plain Array into a Uint8Array before
		// this, so an empty one is the only way to get here.
		return self.js.fail("new three.DataTexture(data, ...) wants a Uint8Array of RGBA bytes, and this one is empty")~;
	}

	usz wanted = (usz)width * (usz)height * 4;
	if (pixels.len != wanted)
	{
		return self.js.fail("%dx%d is %d RGBA bytes and %d were given — four per pixel, in r, g, b, a order",
			width, height, wanted, pixels.len)~;
	}

	// An `Image` over the script's bytes rather than a copy. `to_rgba` inside
	// `claim_texture` makes the one copy this path needs; a second one here would
	// be 1 MB memcpy'd for nothing on a 512x512.
	//
	// The null allocator is what makes borrowing safe: `Image.free` frees nothing
	// without one, so this struct owning bytes it did not allocate can never free
	// the engine's storage.
	image::Image borrowed = {
		.width = (uint)width,
		.height = (uint)height,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels,
		.allocator = (Allocator)null,
	};

	int? index = self.pass.assets.claim_texture(
		&self.renderer.gpu,
		borrowed,
		color_space_of(space),
		// `generateMipmaps` is worth reaching for here more than on a file. Pixels a
		// script generated are as often a table as a picture — a palette, a ramp, a
		// noise field indexed exactly — and a blurred level of a table is not a
		// cheaper approximation of anything.
		mips.or(true),
		// The other half of "a table rather than a picture": a table wants its
		// texels read as squares, and one bright texel under linear magnification
		// is a soft square the size of everything beside it.
		nearest.or(false)
	);
	if (catch err = index) return self.js.fail("could not upload the texture: %s", err)~;

	// Read back off the upload, not echoed from the arguments. The two agree when
	// everything is right, which is why echoing is tempting and wrong: it makes
	// `tex.width` a restatement of what the caller already said rather than a
	// report of what happened, so a dimension lost or transposed anywhere between
	// here and the device is invisible from JavaScript. Written as an echo first,
	// and a `.width`/`.height` swap injected into the `Image` above passed the
	// whole suite.
	return self.texture_handle(index, self.pass.assets.texture_at(index));
}

<*
 The largest side `three.DataTexture` will take.

 Not a device limit — `maxImageDimension2D` is 16384 on everything this targets —
 but a limit on the mistake. The dimensions and the byte count are checked against
 each other, so a wrong pair is refused rather than uploaded; this is the guard
 for a *right* pair that is absurd, where the array was built by a loop with a bad
 bound. 8192x8192 RGBA is 256 MB, which is already past what anyone means.
*>
const int MAX_TEXTURE_SIDE = 8192;

<*
 Turns a texture fault into a sentence that says what to do about it.

 Each of the three is a different next move — check the path, convert the file,
 re-export it at 8 bits — and "could not load" would cost the agent all of that.

 @param path : `As the script wrote it.`
 @param opening : `What resolve_asset returned for it: the file load_texture_file actually opened.`
*>
fn String JsRuntime.texture_failure(&self, fault err, String path, String opening)
{
	switch (err)
	{
		case TEXTURE_UNREADABLE:
			return string::tformat("there is no readable file at %s", self.blame(path, opening));
		case TEXTURE_FORMAT_UNKNOWN:
			return string::tformat(
				"%s is not a PNG or a JPEG — those are the two three.texture reads, and the check is on the "
					"file's own first bytes rather than its name",
				self.blame(path, opening)
			);
		case TEXTURE_BIT_DEPTH:
			return string::tformat("%s is a 16-bit PNG; save it as 8-bit and it will load", self.blame(path, opening));
		default:
			return string::tformat("could not load %s: %s", self.blame(path, opening), err);
	}
}

<*
 `textureDispose(index)` — give back the reference the script's handle holds.

 Not a free. The slot goes only when nothing names it at all, so disposing a
 handle whose image is still on a material leaves the material drawing correctly
 — which makes `dispose()` safe to call the moment a script is done *referring*
 to a texture, rather than something to be timed against the materials that use
 it.

 Waits for the device when this release is the last one, for
 `MeshPass.set_material_map`'s reason: the image is destroyed inside
 `release_texture` and a frame in flight may still be sampling it.
*>
fn void js_texture_dispose(JsRuntime* self, int index)
{
	if (!self.pass.assets.texture_alive(index)) return;

	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	self.pass.assets.release_texture(gpu, index);
	// After the release and only when one happened, so the tally and the table
	// agree: a dispose the guard above turned away gave nothing back.
	self.drop_texture(index);
}

<*
 `textureRead(index, into)` — copy a texture's pixels into a caller's
 `Uint8Array`.

 The destination is an argument, and that is the design. Handing out an
 `ArrayBuffer` over host memory means the host owns an allocation whose lifetime
 is decided by the script, and the only safe end to that is a detach the script
 has to be trusted to trigger. So the script supplies the memory and the host
 writes into it — no copy, no ownership question. It also puts the allocation at
 the call site, where a caller reading a texture every frame can see what it
 costs.

 The bytes are the uploaded ones, not the sampled ones. The copy performs no
 format conversion, so an sRGB texture reads back as the sRGB bytes it was made
 from — which is what makes `new three.DataTexture(px, w, h).read()` return `px`,
 and what `png::save_file` wants.

 @return `The number of bytes written, so a caller can assert on it rather than trusting the length it passed.`
 @return? js::THREW
*>
fn int? js_texture_read(JsRuntime* self, int index, char[] dst)
{
	need_device(self, "texture.read()")!;
	if (!self.pass.assets.texture_alive(index))
	{
		return self.js.fail("texture.read() was given a texture that has been disposed")~;
	}

	Texture* texture = self.pass.assets.texture_at(index);

	// Named before the size check, because the size is not what is wrong. A
	// block-compressed texture holds blocks and there are no pixels to hand
	// back without decoding them, so the message says which format was found
	// rather than leaving a script to infer it from a wrong-looking image.
	if (texture.format.is_block())
	{
		return self.js.fail("texture.read() cannot read a %s texture: it holds compressed blocks, not pixels. "
			"Load it from a .png or .jpg if the pixels are what you need",
			block_family_name(texture.format.family))~;
	}

	sz need = (sz)texture.width * (sz)texture.height * 4;
	if (dst.len < need)
	{
		return self.js.fail("texture.read() wants a Uint8Array of at least %d bytes for a %dx%d image, and was given %d",
			need, texture.width, texture.height, dst.len)~;
	}

	if (catch err = texture.read_pixels(&self.renderer.gpu, dst))
	{
		return self.js.fail("texture.read() could not copy the image back: %s", err)~;
	}
	return (int)need;
}

<*
 `textureSave(index, path)` — write a texture's pixels to a `.png`.

 `js_texture_read`'s other end, and the reason it is a verb rather than three
 lines of prelude over `read()`: the pixels never enter JavaScript. A 2048²
 sheet is 16MB, and a script that only wants the file on disk should not pay for
 that array, the copy into it and the copy back out.

 **The bytes written are the bytes uploaded.** `read_pixels` converts nothing, so
 a `DataTexture` saved here holds exactly the array it was built from and a
 texture loaded from a `.png` writes that `.png`'s own pixels back. What
 `colorSpace` was chosen at load has no effect: it is the sampler's decode, and
 this is upstream of any sampling. So a normal map or an ORM sheet round trips
 through a file unchanged, which is the case a generated sheet actually needs.

 Level 0. The mip levels are approximations this engine made up, and there is no
 verb to ask for one here for the same reason `read()` has none.

 Compressed textures are refused by name, as `read()` refuses them and for its
 reason: there are no pixels behind a block without a decoder, and one written
 into a PNG header would produce a file that opens and is wrong.

 The path is `resolve_write`'s, so under `--assets` this writes inside the game
 directory and nowhere else — the same door `scene.export` and `three.screenshot`
 go through.

 @return? js::THREW
*>
fn WrittenImage? js_texture_save(JsRuntime* self, int index, String asked)
{
	need_device(self, "texture.save()")!;
	if (!self.pass.assets.texture_alive(index))
	{
		return self.js.fail("texture.save() was given a texture that has been disposed")~;
	}

	Texture* texture = self.pass.assets.texture_at(index);
	if (texture.format.is_block())
	{
		return self.js.fail("texture.save() cannot write a %s texture: it holds compressed blocks, not pixels. "
			"Load it from a .png or .jpg if the pixels are what you need",
			block_family_name(texture.format.family))~;
	}

	if (asked.len == 0) return self.js.fail("texture.save(path) wants a path to write a .png to")~;

	String writing = self.writable_path(asked, "texture.save()", tmem)!;

	char[] pixels = alloc::new_array(tmem, char, (sz)texture.width * (sz)texture.height * 4);
	if (catch err = texture.read_pixels(&self.renderer.gpu, pixels))
	{
		return self.js.fail("texture.save() could not copy the image back: %s", err)~;
	}

	image::Image shot = {
		.width = texture.width,
		.height = texture.height,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels,
	};
	if (catch err = png::save_file(&shot, writing, tmem))
	{
		return self.js.fail("texture.save() could not write %s: %s", asked, err)~;
	}

	return written_image(writing, texture.width, texture.height);
}

<*
 `primitive(kind, a, b, c, u, v, w, capped, uv)` — build a parametric shape, or
 hand back the asset already built for exactly these numbers.

 One verb for all five kinds rather than one each, because the layer below is
 already a switch on the kind and a per-shape verb here would be five copies of
 this function differing only in which arguments they ignore. What the numbers
 mean is `Primitive`'s business; `prelude.js`'s `BoxGeometry` and friends are
 where they get their Three.js names, defaults and range checks.

 `uv` is the ordinal of a `UvMode` — 0 for `FACE`, 1 for `LOCAL` — the same
 pattern `ui.js`'s `KIND` numbers use for `UiNodeKind`. It is meaningful only for
 `box` and `plane`; the other three kinds have their own uv layout and ignore
 it. Omitted, it reads as 0 (`FACE`), which is why every caller written before
 this argument existed still builds Three.js's own layout.

 The device is required and says so: a shape has to be uploaded to be drawn.

 @return? js::THREW
*>
fn AssetId? js_primitive(
	JsRuntime* self,
	String name,
	float a,
	float b,
	float c,
	int u,
	int v,
	int w,
	bool capped,
	int uv
)
{
	need_device(self, "building a shape")!;

	PrimitiveKind? kind = primitive_kind(name);
	if (catch kind)
	{
		return self.js.fail("there is no shape called '%s' — three.c3 builds: box, sphere, plane, cylinder, torus",
			name)~;
	}

	// Clamped rather than trusted: the prelude has already refused anything out
	// of range with a better sentence, and this is what a script that called
	// `__three.primitive` itself gets instead of an allocation the size of the
	// device.
	//
	// `uv` likewise: the prelude has already refused any string but 'face' and
	// 'local' before it ever became an ordinal, so anything but exactly 1 here
	// reads as `FACE` — a script driving `__three.primitive` directly gets
	// Three.js's own layout rather than a fault over a stray number.
	Primitive shape = {
		.kind = kind,
		.a = a,
		.b = b,
		.c = c,
		.u = primitive_segments((uint)math::max(u, 0), 1),
		.v = primitive_segments((uint)math::max(v, 0), 1),
		.w = primitive_segments((uint)math::max(w, 0), 1),
		.capped = capped,
		.uv = uv == UvMode.LOCAL.ordinal ? UvMode.LOCAL : UvMode.FACE,
	};

	AssetId? asset = self.pass.assets.primitive(&self.renderer.gpu, shape);
	if (catch err = asset) return self.js.fail("could not build a %s: %s", name, err)~;
	return asset;
}

<*
 `convex(points)` — the convex hull of a point cloud, as an asset.

 `points` is a `Float32Array`, `x, y, z` per point: `prelude.js` has to walk the
 caller's input anyway to validate it, and builds this as it goes.

 Refused rather than clamped at both ends, unlike `primitive`'s segment counts:
 there is no nearest sensible cloud to substitute for a bad one, and a hull
 quietly built from the first 65536 of a script's points would be a shape nobody
 asked for.

 @return? js::THREW
*>
fn AssetId? js_convex(JsRuntime* self, float[] flat)
{
	need_device(self, "building a shape")!;

	if (flat.len % 3 != 0)
	{
		return self.js.fail(
			"three.ConvexGeometry wants a flat array of x, y, z numbers — its length must be a multiple of three"
		)~;
	}

	usz count = flat.len / 3;
	if (count < MIN_CONVEX_POINTS)
	{
		return self.js.fail("a convex hull needs at least %d points, got %d", MIN_CONVEX_POINTS, count)~;
	}
	if (count > MAX_CONVEX_POINTS)
	{
		return self.js.fail("a convex hull is capped at %d points, got %d", MAX_CONVEX_POINTS, count)~;
	}

	@pool()
	{
		Vec3[] points = alloc::new_array(tmem, Vec3, (sz)count);
		foreach (i, &point : points)
		{
			// Zero for a forged non-finite component is the only substitution
			// that cannot turn the hull inside out or send quickhull off to infinity.
			*point = { finite(flat[i * 3]), finite(flat[i * 3 + 1]), finite(flat[i * 3 + 2]) };
		}

		AssetId? asset = self.pass.assets.convex(&self.renderer.gpu, points);
		if (catch err = asset)
		{
			// Said rather than named, unlike `js_load`'s faults: there is exactly
			// one thing that can go wrong here that is about the caller's input, and
			// "CONVEX_HULL_IS_DEGENERATE" does not tell an agent staring at a
			// generated cloud which of the three ways it collapsed.
			if (err == CONVEX_HULL_IS_DEGENERATE)
			{
				return self.js.fail("those %d points enclose no volume — they are all equal, all on one line or all on "
					"one plane, and a convex hull needs four that are none of those",
					count)~;
			}
			return self.js.fail("could not build a convex hull from %d points: %s", count, err)~;
		}
		return asset;
	};
}

<*
 `extrude(outline, holes, holeCounts, depth)` — a 2D outline, with holes cut out
 of it, swept along +z, as an asset. Three.js's `ExtrudeGeometry` over a `Shape`.

 `outline` and `holes` are `Float32Array`s, `x, y` per point — the 2D analogue of
 `convex`'s `x, y, z`. `holes` concatenates every hole's points end to end; the
 `Uint32Array` `holeCounts` says how many of them belong to each hole, in order,
 so the host can re-slice the one array back into however many rings
 `prelude.js` was handed. `scene/extrude.c3` carries the triangulation; this is
 only the boundary and the same finite-component backstop `convex` uses.

 @return? js::THREW
*>
fn AssetId? js_extrude(JsRuntime* self, float[] outline_flat, float[] holes_flat, uint[] hole_counts, Opt {double} depth_arg)
{
	need_device(self, "building a shape")!;

	if (outline_flat.len % 2 != 0)
	{
		return self.js.fail(
			"three.ExtrudeGeometry wants its outline as a flat array of x, y numbers — its length must be a multiple of two"
		)~;
	}
	if (holes_flat.len % 2 != 0)
	{
		return self.js.fail(
			"three.ExtrudeGeometry wants its holes as a flat array of x, y numbers — its length must be a multiple of two"
		)~;
	}

	usz hole_points = holes_flat.len / 2;
	usz counted = 0;
	foreach (n : hole_counts) counted += n;
	if (counted != hole_points)
	{
		return self.js.fail("three.ExtrudeGeometry: holeCounts adds up to %d points but holes has %d",
			counted, hole_points)~;
	}

	double depth_asked = depth_arg.or(1.0);
	float depth        = math::is_finite(depth_asked) && depth_asked > 0 ? (float)depth_asked : 0.001f;

	@pool()
	{
		Vec2[] outline = alloc::new_array(tmem, Vec2, (sz)(outline_flat.len / 2));
		foreach (i, &point : outline) *point = { finite(outline_flat[i * 2]), finite(outline_flat[i * 2 + 1]) };

		Vec2[] holes = alloc::new_array(tmem, Vec2, (sz)hole_points);
		foreach (i, &point : holes) *point = { finite(holes_flat[i * 2]), finite(holes_flat[i * 2 + 1]) };

		AssetId? asset = self.pass.assets.extrude(&self.renderer.gpu, outline, holes, hole_counts, depth);
		if (catch err = asset)
		{
			// Said rather than named, `convex`'s reason: the fault name does not
			// carry which of the three ways an outline collapses, and there is
			// exactly one thing here that is about the caller's shape.
			if (err == EXTRUDE_SHAPE_IS_DEGENERATE)
			{
				return self.js.fail(
					"that outline has no area to extrude — it needs at least 3 points that are not all on one "
						"line, and every hole needs at least 3 points of its own"
				)~;
			}
			return self.js.fail("could not extrude that shape: %s", err)~;
		}
		return asset;
	};
}

<*
 `ribbon(positions, normals, uvs, columns, rows)` — a strip geometry as an asset,
 built from a grid of vertices rather than from a parametric shape.

 `Float32Array`s `positions`, `normals` and `uvs`, row-major over `columns` x
 `rows`: one cross-section of `columns` vertices, one per row, in the order `row`
 walked down the path then `column` walked across the width. The host does the
 only thing it can know — emit the triangles between adjacent cells of the grid —
 and nothing about the shape of the curve, which is the prelude's domain.

 The index pattern is a grid like `Heightfield.build`'s, but wound the other way.
 A ribbon's across axis is 90 degrees counter-clockwise from its tangent (in the
 xz plane), so `across x along = +y`; the ground's axes run the other hand and
 its winding is mirrored. The triangles here are emitted so their front face
 points +y, matching the normals the prelude computed.

 Uploaded through `upload_built`, so it is an asset like any other — one draw
 call per unique ribbon, deduplicated by a hash of the vertices, filling the
 bounds and BVH through the same tail a built primitive uses. None of the data is
 retained on the slot: unlike a terrain, a ribbon answers no questions.

 @return? js::THREW
*>
fn AssetId? js_ribbon(JsRuntime* self, float[] positions, float[] normals, float[] uvs, int columns, int rows)
{
	need_device(self, "building a shape")!;

	if (positions.len < 3 || positions.len % 3 != 0)
	{
		return self.js.fail(
			"three.RibbonGeometry wants the vertex positions as a flat x, y, z array — its length must be a multiple of three"
		)~;
	}
	usz count = positions.len / 3;
	if (normals.len != positions.len)
	{
		return self.js.fail("ribbon normals must be the same length as positions — one x, y, z per vertex")~;
	}
	if (uvs.len != count * 2)
	{
		return self.js.fail("ribbon uvs must be u, v per vertex — twice as many numbers as vertices")~;
	}
	columns = math::max(columns, 0);
	rows    = math::max(rows, 0);
	if (columns < 2 || rows < 2) return self.js.fail("a ribbon needs at least 2 columns across and 2 rows along")~;
	if ((usz)columns * (usz)rows != count)
	{
		return self.js.fail("columns x rows (%d x %d) must equal the number of vertices (%d)", columns, rows, count)~;
	}

	@pool()
	{
		GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();

		ulong hash = KEY_SEED;
		for (usz i = 0; i < count; i++)
		{
			Vec3 position = { 0, 0, 0 };
			Vec3 normal   = { 0, 1, 0 };
			for (usz axis = 0; axis < 3; axis++)
			{
				position[axis] = finite(positions[i * 3 + axis]);
				normal[axis] = finite(normals[i * 3 + axis]);
				hash = @hash_value(hash, position[axis]);
				hash = @hash_value(hash, normal[axis]);
			}
			float ux = finite(uvs[i * 2]);
			float uy = finite(uvs[i * 2 + 1]);
			hash = @hash_value(hash, ux);
			hash = @hash_value(hash, uy);
			geometry.vertex(position, normal, { ux, uy });
		}

		for (int r = 0; r + 1 < rows; r++)
		{
			for (int c = 0; c + 1 < columns; c++)
			{
				uint a  = (uint)(r * columns + c);
				uint b  = a + 1;
				uint cc = a + (uint)columns;
				uint d  = cc + 1;
				geometry.triangle(a, b, cc);
				geometry.triangle(b, d, cc);
			}
		}

		if (geometry.indices.len() < 3 || geometry.positions.len() == 0)
		{
			return self.js.fail("the ribbon produced no triangles — check the path and the width")~;
		}

		String key = string::tformat("ribbon:%d:%d:%x", columns, rows, hash);
		if (try hit = self.pass.assets.built(key)) return hit;

		AssetId? asset = self.pass.assets.upload_built(&self.renderer.gpu, key, "ribbon", &geometry);
		if (catch err = asset) return self.js.fail("could not build a ribbon: %s", err)~;
		return asset;
	};
}

<*
 `lines(kind, divisions)` — a debug line shape, or the one already built for
 exactly this shape.

 `primitive`'s twin down to the clamping, and deliberately so: a helper is an
 ordinary asset over an ordinary mesh, and the only thing that makes it a helper
 is the material `prelude.js` puts on it.

 `divisions` is the grid's and is ignored by the other two — `LineShape.key`
 leaves it out of their keys, so a box asked for with a stray division count is
 still the one box asset.

 @return? js::THREW
*>
fn AssetId? js_lines(JsRuntime* self, String name, int divisions)
{
	need_device(self, "building a helper")!;

	LineKind? kind = line_kind(name);
	if (catch kind)
	{
		return self.js.fail("there is no line shape called '%s' — three.c3 builds: box, segment, grid", name)~;
	}

	// Clamped rather than trusted, for `primitive`'s reason: the prelude has
	// already refused anything out of range with a better sentence.
	LineShape shape = {
		.kind = kind,
		.divisions = (uint)math::clamp(divisions, 1, (int)MAX_GRID_DIVISIONS),
	};

	AssetId? asset = self.pass.assets.lines(&self.renderer.gpu, shape);
	if (catch err = asset) return self.js.fail("could not build a %s helper: %s", name, err)~;
	return asset;
}

<*
 `wireframe(asset, mesh)` — one mesh's triangles as the edges between them.

 The mesh has to be resident, and that is a sentence rather than an empty asset.
 The edges are read off `hull_positions`/`hull_triangles`, which are filled at
 upload, and a mesh reaches the device only when something drawing it is added to
 a scene. An empty wireframe would draw nothing and read as a helper that does
 not work.

 @return? js::THREW
*>
fn AssetId? js_wireframe(JsRuntime* self, AssetId id, int mesh_asked)
{
	need_device(self, "building a helper")!;

	uint mesh      = (uint)math::max(mesh_asked, 0);
	AssetId? asset = self.pass.assets.wireframe(&self.renderer.gpu, id, mesh);
	if (catch err = asset)
	{
		if (err == LINE_MESH_NOT_RESIDENT)
		{
			return self.js.fail(
				"a wireframe is built from the mesh's own triangles, and those reach this side when the "
					"mesh is uploaded — which happens when something drawing it is added to a scene. "
					"scene.add(mesh) first, then make the helper"
			)~;
		}
		if (err == NO_SUCH_LINE_MESH)
		{
			return self.js.fail("that asset has no mesh %d — asset.meshes lists the ones it has", mesh)~;
		}
		return self.js.fail("could not build a wireframe of mesh %d: %s", mesh, err)~;
	}
	return asset;
}

<*
 `scene.export`'s texture format argument, as the enum.

 A number across the boundary rather than the word, which is the rule the rest of
 this file follows: the prelude has already refused anything that is not one of
 the three spellings, by name, so what arrives here is an index. Anything else is
 PNG — the default, and the only answer that cannot make a file worse than it
 was.
*>
fn ExportTextureFormat export_textures(int asked) @local
{
	switch (asked)
	{
		case 1: return ExportTextureFormat.KTX2_BC7;
		case 2: return ExportTextureFormat.KTX2_BASIS;
		default: return ExportTextureFormat.PNG;
	}
}

<*
 What `scene.export` answers with. Every number in it answers a different question
 about whether the file is the scene: `meshes` against `stats().uniqueMeshes`,
 `instances` against `stats().instances`, and `skipped` and `shaded` for the two
 things that deliberately did not survive the crossing.

 `batches` is how many of `nodes` were written as instanced nodes — the one number
 with no counterpart in `stats()`, saying how much of the scene the file managed to
 keep as repetition rather than as a thousand named copies.

 `compressed_images` sits beside `images` and is not folded into it: a script that
 asked for a compressed texture wants to know how many it actually got, because an
 encode that refused falls back to PNG rather than failing the export.

 `layers` is `CUSTOM_materials_layers` records written, from a stack a file brought
 and from one a script built alike. It exists because `shaded` cannot answer for
 them: a layered material reaches the frame as a generated `ShaderMaterial` either
 way, so it is counted as a lost shader whether or not its stack survived.

 `baked_images` and `baked_colors` are what the bake did — both of them copies that
 would have been counted in `shaded` without it.
*>
struct ExportAnswer
{
	String path;
	uint meshes;
	uint entries;
	uint materials;
	uint images;
	uint compressed_images;
	uint nodes;
	uint instances;
	uint batches;
	uint skipped;
	uint shaded;
	uint baked_images;
	uint baked_colors;
	uint layers;
	uint skins;
	uint bones;
	uint clips;
	uint morphed;
	double bytes;
}

<*
 `exportScene(path, flatten, bake, textures)` — write the scene to a `.glb`, and
 say what went into it.

 `js_load`'s other half, through a narrower door: the path is resolved by
 `resolve_write`, so under `--assets` a script may write inside the game
 directory and nowhere else.

 No device is needed and none is used. `scene/export.c3` reads a mesh out of the
 file it came from or tessellates it again from its description, so an export is
 the one heavy verb here that works on a runtime with no GPU.

 `flatten` gives up the hierarchy to batch copies that are not siblings — the
 ones `asset.instantiate()` produces, each in a group of its own.

 `bake` is the bake resolution, or 0 for none. It is the one part of an export
 that needs a device: each `ShaderMaterial` is run over its mesh's uv layout and
 read back, so a body's answer reaches the file as a `baseColorTexture` or a
 `baseColorFactor` instead of being lost. `render/bake.c3` is the whole of it.
 The prelude has turned `bake: true` into a resolution and refused anything
 outside the range by name, so this is a number and nothing else.

 `textures` is what generated textures are encoded as, as the number
 `export_textures` names. A source file's images are copied unchanged whatever it
 says.

 @return? js::THREW
*>
fn ExportAnswer? js_export(JsRuntime* self, String path, bool flatten, int bake, int textures)
{
	if (self.pass == null) return self.js.fail("there is no scene to export in this context")~;
	if (path.len == 0) return self.js.fail("scene.export(path) wants a path to write a .glb to")~;

	String? writing = self.resolve_write(path, tmem);
	if (catch err = writing)
	{
		if (err == js::MODULE_ESCAPES_ROOT)
		{
			return self.js.fail("cannot export to '%s': it climbs out of the assets directory, and a game may only "
				"write inside its own",
				path)~;
		}
		return self.js.fail("cannot export to '%s': %s", path, err)~;
	}

	if (catch err = make_way_for(writing))
	{
		return self.js.fail("cannot export to '%s': could not make its folder: %s", path, err)~;
	}

	ExportReport? report = self.pass.export_scene(
		writing,
		flatten,
		bake > 0 ? (uint)bake : 0,
		export_textures(textures)
	);
	if (catch err = report)
	{
		if (err == EXPORT_HAS_NOTHING_TO_WRITE)
		{
			return self.js.fail(
				"there is nothing in this scene to draw, so there is nothing to export — it is empty, "
					"or everything in it is a helper or a hidden subtree, neither of which goes into a file"
			)~;
		}
		return self.js.fail("could not export to %s: %s", path, err)~;
	}

	return {
		.path = writing,
		.meshes = report.meshes,
		.entries = report.entries,
		.materials = report.materials,
		.images = report.images,
		.compressed_images = report.compressed_images,
		.nodes = report.nodes,
		.instances = report.instances,
		.batches = report.batches,
		.skipped = report.skipped,
		.shaded = report.shaded,
		.baked_images = report.baked_images,
		.baked_colors = report.baked_colors,
		.layers = report.layers,
		.skins = report.skins,
		.bones = report.bones,
		.clips = report.clips,
		.morphed = report.morphed,
		.bytes = (double)report.bytes,
	};
}

<*
 `checkAsset(asset)` — throw if that handle no longer names an asset.

 `AssetId`'s staleness check with nothing else attached to it, so that
 `new three.Mesh(ref)` can make it at the line naming the handle instead of
 leaving it to the `scene.add()` two lines later. It answers with nothing: the
 only thing a caller wants from it is the throw.

 The sentence is the handle's own rather than a second one written beside it.
 One message means one place to keep it right, and an agent that hits it at the
 constructor reads exactly what it would have read at the add — including the
 recovery, which is the half that matters.
*>
fn void js_check_asset(JsRuntime* self, AssetId id)
{
}

fn String js_asset_path(JsRuntime* self, AssetId id) => self.pass.assets.slot(id).path;

<*
 Every mesh in an asset, by name, in load order.

 A glTF mesh with several primitives produced several `GpuMesh` entries sharing
 one name, so this list can repeat — and `Asset.mesh(name)` in the prelude takes
 the first, which is what `Assets.find_mesh` does.

 @return? js::THREW
*>
fn js::Value? js_mesh_names(JsRuntime* self, AssetId id)
{
	js::Value names = self.js.array()!;
	foreach (&mesh : self.pass.assets.slot(id).meshes) self.js.push(names, self.js.string(mesh.name)!);
	return names;
}

<*
 `meshBounds(asset, mesh)` — one mesh's box in its own local space, as
 `[minX, minY, minZ, maxX, maxY, maxZ]`, or `null` if the index names nothing.

 This costs nothing and is available before the mesh is on the device. A
 `GpuMesh` exists from the moment the JSON is parsed, and `bounds` is one of the
 three fields filled in then rather than at upload — it is the POSITION
 accessor's required `min`/`max`. So asking how big a kit piece is does not
 upload the kit.

 Per mesh index, not per name: a glTF mesh with several primitives produced
 several entries sharing a name, and a `Mesh` node draws exactly one of them.

 @return? js::THREW
*>
fn js::Value? js_mesh_bounds(JsRuntime* self, AssetId id, uint index)
{
	GpuMesh* mesh = self.pass.assets.mesh(id, index);
	if (mesh == null) return js::NULL;
	Vec3 min = mesh.bounds.min;
	Vec3 max = mesh.bounds.max;
	return self.js.numbers({ min.x, min.y, min.z, max.x, max.y, max.z });
}

<*
 `uploadMesh(asset, mesh, onDone, onFail)` — queue one mesh's upload and settle a
 promise when it lands.

 **The promise is JavaScript's and the queue is the engine's.** What crosses is
 the two settlement functions of a `new Promise(...)` the prelude built, which
 the runtime holds and calls later — so there is no second definition of what a
 promise is. Settling one queues a microtask, and `drain_frame_jobs` already
 drains those; that is the whole of the machinery.

 One mesh a frame comes out of `step_upload` rather than from anything here, and
 it is what separates this from `scene.add`: adding a kit of ninety pieces
 uploads ninety meshes inside one frame, and asking for them this way spreads
 them over ninety.

 Nothing is uploaded during this call. A script that wants the mesh *now* should
 place it and let `add` do it, which is still the shorter path and always will
 be.

 @return? js::THREW
*>
fn void? js_upload_mesh(JsRuntime* self, AssetId id, uint mesh, js::Value resolve, js::Value reject)
{
	if (!resolve.is_function() || !reject.is_function())
	{
		return self.js.fail("uploadMesh wants the two settlement functions of a promise")~;
	}

	self.uploads.push({
		.asset = id,
		.mesh = mesh,
		.resolve = self.js.hold(resolve),
		.reject = self.js.hold(reject),
	});
}

<*
 `assetImages(asset)` — how many images the file carries.

 Out of the JSON chunk, so it costs nothing and answers before any mesh has been
 placed. `asset.imageAt(i)` range-checks against it, which is what keeps an
 out-of-range index a `RangeError` naming the count rather than a `null` that
 could equally mean "the picture would not decode".
*>
fn uint js_asset_images(JsRuntime* self, AssetId id) => self.pass.assets.asset_image_count(id);

<*
 `assetImage(asset, image, space, mips)` — one of the file's own images as a
 texture handle.

 The verb `texture.read()` had nothing to be called on for a `.glb`. A picture
 inside a file reached the device as an `int` on a `GpuMesh` and stopped there,
 so a script could draw a kit and still have no way to look at what it drew
 with.

 It decodes rather than requiring the mesh to have been placed, which is the
 difference between "the images this file has" and "the images something has
 already drawn". When a mesh *has* been placed, the asset's memo means this is
 the same slot — so what comes back is the image on screen and not a second copy
 of it.

 It retains, like every other handle that crosses: the `Texture` the prelude
 wraps this in owns a reference, and disposing it cannot take the picture out
 from under a mesh still drawing it.

 @return `[index, width, height, levels], or null when the image would not decode.`
 @return? js::THREW
*>
fn js::Value? js_asset_image(JsRuntime* self, AssetId id, int image, int space, Opt {bool} mips)
{
	need_device(self, "asset.imageAt")!;

	int? index = self.pass.assets.load_asset_image(&self.renderer.gpu, id, image, color_space_of(space), mips.or(true));
	if (catch err = index) return self.js.fail("could not read image %d: %s", image, err)~;
	if (index < 0) return js::NULL;

	return self.texture_handle(index, self.pass.assets.texture_at(index));
}

<*
 One of a material's texture slots, as `[index, width, height, levels, colourspace]`
 — or `null` for a slot it does not use.

 It retains. The `GpuMesh` holds one reference per slot and the `Texture` the
 prelude wraps this in holds another, exactly as `three.texture()` of a file
 already in the table does: two handles naming one image is two references, and
 the alternative is a script disposing its material and taking the image out from
 under the mesh that is still drawing with it.

 `null` rather than an index of -1, because the far side puts these straight into
 a layer description where the absence of an image is spelled `null`.

 The fifth field is the colourspace, and it is not decoration. Everywhere else in
 this file the prelude knows the space because it *asked* for it. Nothing asks
 here: the importer decides, per image, from what the layer uses it for, so the
 only honest source is the slot itself. Having the prelude assume "a mask is
 linear" would make `tex.colorSpace` a restatement of the prelude's own rule
 rather than a fact about the image — so an importer that uploaded a mask as sRGB
 by mistake would still *report* linear, and the one test aimed at that class of
 bug would pass.

 @return? js::THREW
*>
fn js::Value? layer_texture(JsRuntime* self, int index) @local
{
	if (index < 0) return js::NULL;
	Assets* assets    = &self.pass.assets;
	Texture* uploaded = assets.texture_at(index);
	if (uploaded == null) return js::NULL;
	assets.retain_texture(index);
	js::Value fields = self.texture_handle(index, uploaded)!;
	self.js.push(fields, js::integer(uploaded.format.space == ColorSpace.LINEAR ? 1 : 0));
	return fields;
}

<*
 What a primitive's glTF material said, beyond the base colour that is already on
 the mesh — `scene/asset.c3`'s `GpuMaterial` with its texture slots as handles.

 `uv_scale` and `uv_offset` are the material's `KHR_texture_transform`, one for
 every map it has — `texture_transform` in `scene/asset.c3` says why one and not
 five.
*>
struct MeshMaterialRecord
{
	uint alpha_mode;
	float alpha_cutoff;
	bool double_sided;
	float emissive_strength;
	float[<3>] emissive_factor;
	float metallic;
	float roughness;
	js::Value normal_texture;
	js::Value occlusion_texture;
	js::Value metallic_roughness_texture;
	js::Value emissive_texture;
	float[<2>] uv_scale;
	float[<2>] uv_offset;
}

<*
 `meshMaterial(asset, mesh)` — a `MeshMaterialRecord`, or `null` for a primitive
 that names no material, which is a real glTF and means the default one.

 Reading this uploads the mesh, and every read holds new references, exactly as
 `meshLayers` does: the images exist only once the primitive is on the device,
 and each texture handed back is a handle of its own.

 @return? js::THREW
*>
fn js::Value? js_mesh_material(JsRuntime* self, AssetId id, uint index)
{
	self.pass.assets.ensure_uploaded(id, index);

	GpuMesh* mesh = self.pass.assets.mesh(id, index);
	if (mesh == null || !mesh.material.present) return js::NULL;

	GpuMaterial* material = &mesh.material;
	MeshMaterialRecord record = {
		.alpha_mode = material.alpha_mode,
		.alpha_cutoff = material.alpha_cutoff,
		.double_sided = material.double_sided,
		.emissive_strength = material.emissive_strength,
		.emissive_factor = { material.emissive_factor[0], material.emissive_factor[1], material.emissive_factor[2] },
		.metallic = material.metallic,
		.roughness = material.roughness,
		.normal_texture = layer_texture(self, material.normal_texture)!,
		.occlusion_texture = layer_texture(self, material.occlusion_texture)!,
		.metallic_roughness_texture = layer_texture(self, material.metallic_roughness_texture)!,
		.emissive_texture = layer_texture(self, material.emissive_texture)!,
		.uv_scale = { material.uv_scale[0], material.uv_scale[1] },
		.uv_offset = { material.uv_offset[0], material.uv_offset[1] },
	};
	return self.js.@object_of(record);
}

<*
 `splitMesh(asset, mesh)` — one mesh, cut into its connected components, as an
 array of `{ asset, mesh }`.

 `scene/split.c3` has the algorithm and what a piece does and does not inherit.
 What is here is the boundary: the three refusals it can produce become three
 sentences an agent can act on, because "MESH_HAS_LAYERS" says nothing about what
 to do next.

 A piece carries which mesh of its asset it is, because a mesh that is already one
 piece answers with an array of one holding *this* mesh — nothing is uploaded, and
 that mesh need not be zero. That is not an error and is deliberately not reported
 as one: "this kit was already cut" is something a script finds out by looking at
 the length.

 @return? js::THREW
*>
fn js::Value? js_split_mesh(JsRuntime* self, AssetId id, uint index)
{
	if (self.renderer == null)
	{
		return self.js.fail("splitting a mesh uploads its pieces, and this context has no GPU device")~;
	}

	@pool()
	{
		List{MeshPiece} pieces;
		pieces.tinit(8);

		uint? count = self.pass.assets.split_mesh(&self.renderer.gpu, id, index, &pieces);
		if (catch err = count)
		{
			switch (err)
			{
				case MESH_HAS_LAYERS:
					return self.js.fail(
						"that mesh carries a layer stack, and a piece cut out of it cannot inherit one — "
							"read the stack with ref.layers, build a LayeredMaterial from it, and put that on "
							"the pieces yourself"
					)~;
				case MESH_CANNOT_BE_SPLIT:
					return self.js.fail(
						"there are no triangles to cut there — that mesh index does not exist, or it is a "
							"line mesh, whose indices are pairs"
					)~;
				case TOO_MANY_SPLIT_PIECES:
					return self.js.fail("that mesh comes apart into more than %d pieces, which is not a kit — it is "
						"geometry whose triangles do not touch each other",
						MAX_SPLIT_PIECES)~;
				default:
					return self.js.fail("that mesh could not be split: %s", err)~;
			}
		}

		js::Value list = self.js.array((uint)pieces.len())!;
		foreach (piece : pieces) self.js.push(list, self.js.@object_of(piece)!);
		return list;
	};
}

// What `merge` built, and how many triangles it came to — what
// `MergedGeometry.parameters.triangles` reads.
struct MergeAnswer
{
	AssetId asset;
	uint triangles;
}

<*
 `merge(assets, meshes, matrices, colors)` — every named mesh concatenated into
 one asset, each one's vertices baked through its own matrix — `splitMesh` in
 reverse.

 `assets` is an array of Asset handles, one per input mesh, and `meshes` a
 `Uint32Array` of the same length; `matrices` is a `Float32Array` of sixteen per
 mesh, column-major — `Matrix4f.m`'s own layout, translation in `m[12..14]`;
 `colors` is four per mesh, `mesh.color` exactly as JavaScript last wrote it, not
 yet srgb-decoded. `scene/merge.c3` decodes it there, the way the shader decodes
 `mesh.color`, and folds it into the merged mesh's vertex colours rather than its
 own instance colour, because a merge only has one instance afterwards.

 Every length disagreeing with `assets`' is a forged call — `prelude.js` built
 these four together — and is refused as one rather than trusted to mean
 something.

 @return? js::THREW
*>
fn MergeAnswer? js_merge(JsRuntime* self, js::Value assets, uint[] meshes, float[] matrices, float[] colors)
{
	if (self.renderer == null)
	{
		return self.js.fail("merging meshes uploads the result, and this context has no GPU device")~;
	}

	long count = self.js.length(assets)!;
	if (count <= 0) return self.js.fail("three.merge(...) wants at least one mesh")~;
	if (meshes.len != count || matrices.len != count * 16 || colors.len != count * 4)
	{
		return self.js.fail("three.merge(...): the crossing arrays do not agree on how many meshes there are")~;
	}

	@pool()
	{
		MergeInput[] inputs = alloc::new_array(tmem, MergeInput, (sz)count);
		foreach (usz i, &input : inputs)
		{
			void* data = js::data_of(self.js.get(assets, i)!, self.asset_class);
			AssetId asset_id = data ? unpack_id(data, AssetId) : NO_ASSET;
			if (!data || self.pass.assets.slot(asset_id) == null)
			{
				return self.js.fail(
					"three.merge(...): one of the meshes named there is no longer loaded — "
						"three.unloadUnused() or scene.unload() freed it since the subtree was walked"
				)~;
			}

			Matrix4f matrix;
			for (usz k = 0; k < 16; k++) matrix.m[k] = finite(matrices[i * 16 + k]);

			float[4] color;
			for (usz k = 0; k < 4; k++) color[k] = finite(colors[i * 4 + k], 1.0f);

			*input = { .asset = asset_id, .mesh = meshes[i], .matrix = matrix, .color = color };
		}

		uint failed_at = 0;
		AssetId? asset = self.pass.assets.merge(&self.renderer.gpu, inputs, &failed_at);
		if (catch err = asset)
		{
			String named = "that mesh";
			if (failed_at < inputs.len)
			{
				GpuMesh* mesh = self.pass.assets.mesh(inputs[failed_at].asset, inputs[failed_at].mesh);
				named = mesh != null && mesh.name.len > 0
					? string::tformat("'%s'", mesh.name)
					: string::tformat("mesh %d of the subtree", failed_at);
			}
			switch (err)
			{
				case MESH_HAS_LAYERS:
					return self.js.fail("%s carries a layer stack, and a merged mesh cannot inherit one — read it with "
						"ref.layers, build a LayeredMaterial from it, and put that on the merged mesh "
						"yourself",
						named)~;
				case MESH_CANNOT_BE_MERGED:
					return self.js.fail("%s has no triangles to merge — its asset is no longer loaded, or it is a line "
						"mesh, whose indices are pairs",
						named)~;
				case NOTHING_TO_MERGE:
					return self.js.fail("three.merge(...) wants at least one mesh")~;
				case TOO_MANY_MERGE_MESHES:
					return self.js.fail("that merges %d meshes, more than the %d this refuses as a mistake rather than a "
						"kit — a wide scatter of identical instances wants to stay instanced",
						inputs.len, MAX_MERGE_MESHES)~;
				default:
					return self.js.fail("%s could not be merged: %s", named, err)~;
			}
		}

		GpuMesh* built = self.pass.assets.mesh(asset, 0);
		return { .asset = asset, .triangles = built != null ? built.index_count / 3 : 0 };
	};
}

<*
 One layer of an imported stack, with its texture slots as handles.

 The blend mode and the mask channel are the extension's own ordinals and are
 named on the far side, which keeps `gltf.c3l`'s enum the single authority for
 what the ordinals mean.

 The four uv numbers are the layer's `KHR_texture_transform` **relative to the
 base material's**, which is what `LayeredMaterial` means by `uvScale` and
 `uvOffset`: the base's own transform is already on `s.uv` by the time a layer's
 uv is computed. `relative_uv` in `scene/asset.c3` has the arithmetic.
*>
struct LayerRecord
{
	String name;
	bool enabled;
	uint blend_mode;
	uint mask_source;
	uint mask_channel;
	bool invert;
	float opacity;
	float[<4>] base_color;
	float[<3>] emissive_factor;
	js::Value texture;
	js::Value normal_texture;
	js::Value emissive_texture;
	js::Value mask_texture;
	float metallic;
	float roughness;
	js::Value metallic_roughness_texture;
	js::Value height_texture;
	float bump_strength;
	float bump_distance;
	float[<2>] uv_scale;
	float[<2>] uv_offset;
}

<*
 A whole imported stack. `height_texture` and the two bump numbers are the base
 material's own relief, which hangs off the stack rather than off any layer — the
 extension's `base` object, and the only place core glTF leaves for a height map.
*>
struct LayerStackRecord
{
	js::Value mask_texture;
	js::Value layers;
	js::Value height_texture;
	float bump_strength;
	float bump_distance;
}

<*
 `meshLayers(asset, mesh)` — one mesh's `CUSTOM_materials_layers` stack as a
 `LayerStackRecord`, or `null` when its material never carried the extension.

 This uploads the mesh, unlike `meshBounds` beside it. A stack is texture slots,
 and texture slots exist only once the primitive has been through
 `upload_primitive` — so a verb that answered without uploading would answer
 `null` for a mesh that has layers and has simply not been drawn yet, which is a
 wrong answer that looks like a file without the extension. A script asking this
 is about to build a material for the mesh anyway.

 What crosses is a *description* rather than a material: the JS side turns it
 into an ordinary `LayeredMaterial` through the ordinary constructor, so an
 imported stack and a hand-written one are the same object and there is one
 generator rather than two.

 @return? js::THREW
*>
fn js::Value? js_mesh_layers(JsRuntime* self, AssetId id, uint index)
{
	self.pass.assets.ensure_uploaded(id, index);

	GpuMesh* mesh = self.pass.assets.mesh(id, index);
	if (mesh == null || !mesh.layers.present) return js::NULL;

	js::Value layers = self.js.array((uint)mesh.layers.layers.len())!;
	foreach (&layer : mesh.layers.layers)
	{
		LayerRecord record = {
			.name = layer.name,
			.enabled = layer.enabled,
			.blend_mode = layer.blend_mode,
			.mask_source = layer.mask_source,
			.mask_channel = layer.mask_channel,
			.invert = layer.invert,
			.opacity = layer.opacity,
			.base_color = { layer.base_color[0], layer.base_color[1], layer.base_color[2], layer.base_color[3] },
			.emissive_factor = { layer.emissive_factor[0], layer.emissive_factor[1], layer.emissive_factor[2] },
			.texture = layer_texture(self, layer.texture)!,
			.normal_texture = layer_texture(self, layer.normal_texture)!,
			.emissive_texture = layer_texture(self, layer.emissive_texture)!,
			.mask_texture = layer_texture(self, layer.mask_texture)!,
			.metallic = layer.metallic,
			.roughness = layer.roughness,
			.metallic_roughness_texture = layer_texture(self, layer.metallic_roughness_texture)!,
			.height_texture = layer_texture(self, layer.height_texture)!,
			.bump_strength = layer.bump_strength,
			.bump_distance = layer.bump_distance,
			.uv_scale = { layer.uv_scale[0], layer.uv_scale[1] },
			.uv_offset = { layer.uv_offset[0], layer.uv_offset[1] },
		};
		self.js.push(layers, self.js.@object_of(record)!);
	}

	LayerStackRecord stack = {
		.mask_texture = layer_texture(self, mesh.layers.mask_texture)!,
		.layers = layers,
		.height_texture = layer_texture(self, mesh.layers.height_texture)!,
		.bump_strength = mesh.layers.bump_strength,
		.bump_distance = mesh.layers.bump_distance,
	};
	return self.js.@object_of(stack);
}

<*
 One entry of `assetNodes`: a node that should exist, naming its parent by
 position in the same array.

 ## The rotation crosses twice, and both are needed

 Once as Euler angles, because that is what an `Object3D.rotation` is and a
 script that reads it back should see numbers rather than a quaternion nobody
 asked for. Once as the quaternion itself, because the Euler form is not exact:
 at gimbal lock — a rotation of exactly 90° about Y, the single most common thing
 anyone types into Blender — `asin` is evaluated where its slope is infinite and
 the recovered angle is off by about 3e-4 radians. That is 0.7mm at the end of a
 two-metre arm, which is a hairline gap between two kit pieces authored flush.

 So `prelude.js` shows the Euler triple and sends the quaternion, and writing an
 Euler angle drops the quaternion.
*>
struct AssetNodeRecord
{
	String name;
	int parent;
	int mesh;
	Vec3 position;
	Vec3 euler;
	Vec3 scale;
	float[<4>] quaternion;
	int gltf_node;
	// The per-copy tint, which is white for everything but a copy an instanced
	// node placed.
	float[<4>] color;
	// Which skin poses this node, or -1. The JS tree carries it to
	// `_materialize`, which is where a host node learns it — the JavaScript path
	// builds its nodes through the ordinary `add`, not through
	// `Scene.instantiate`, so nothing else would ever set it.
	int skin;
	// What the file said about this entry, or the engine's default when it was
	// not asked. `collides` is false on every mesh of a file whose colliders
	// decide the index and did not name this one; `collision_only` is true on
	// the proxy an implicit shape got.
	bool collides;
	bool collision_only;
}

<*
 `assetNodes(asset, skeleton, physics)` — the asset's node tree, flattened into
 the `AssetNodeRecord`s `asset.instantiate()` builds objects from.

 Parents always come before their children, so `instantiate()` can walk it once
 and never look forward.

 The tree is not built here and its shape is not decided here. `Assets.flatten`
 decides — the same walk `Scene.instantiate` uses on the host — so a file placed
 by the CLI and a file placed by a script produce the same hierarchy. What
 crosses the boundary is a description, and JavaScript builds ordinary
 `Object3D`s from it that materialize through the normal `add` path. That is
 deliberate: an object handed back from here is one a script can move, hide,
 recolour and re-parent before it ever reaches a scene.

 `skeleton` keeps the file's bone nodes as objects. False drops a character's
 skeleton — its pose comes out of the baked table and the nodes would drive
 nothing. `physics` lets the file's own `KHR_physics_rigid_bodies` decide what
 collides; false is every file loaded without the option and the reason no
 existing scene changes. See `Assets.flatten` and `scene/collider.c3`.

 @return? js::THREW
*>
fn js::Value? js_asset_nodes(JsRuntime* self, AssetId id, bool skeleton, bool physics)
{
	List{PlacedNode} placed;
	placed.init(mem, 16);
	defer placed.free();
	self.pass.assets.flatten(id, &placed, skeleton, physics);

	js::Value nodes = self.js.array((uint)placed.len())!;
	foreach (&entry : placed)
	{
		Quaternionf q = entry.rotation;
		AssetNodeRecord record = {
			.name = entry.name,
			.parent = entry.parent,
			.mesh = entry.mesh,
			.position = entry.position,
			.euler = euler_from_quat(q),
			.scale = entry.scale,
			.quaternion = { q.i, q.j, q.k, q.l },
			.gltf_node = entry.gltf_node,
			.color = { entry.color[0], entry.color[1], entry.color[2], entry.color[3] },
			.skin = entry.skin,
			.collides = entry.collides,
			.collision_only = entry.collision_only,
		};
		self.js.push(nodes, self.js.@object_of(record)!);
	}
	return nodes;
}

// One `KHR_lights_punctual` light (or area light), placed in world space.
struct AssetLightRecord
{
	String name;
	uint kind;
	float[<3>] color;
	float intensity;
	float range;
	float inner_cone;
	float outer_cone;
	Vec3 position;
	Vec3 direction;
	int gltf_node;
	uint area_shape;
	float width;
	float height;
	float spread;
	Vec3 right;
	Vec3 up;
}

<*
 `assetLights(asset)` — the file's lights, as `AssetLightRecord`s.

 A description and not a light. The renderer holds four slots and a level may
 author twenty, so which of them get lit is a choice, and this is what the choice
 is made from — `asset.instantiate({ lights: true })` is one policy over it and a
 script is free to write another.

 `kind` is `gltf::LightType`'s ordinal, passed through untranslated for the same
 reason the layer stack's blend modes are: the extension's enum is the authority
 and naming it twice is two tables to keep in step.

 `direction` is the way the light *travels* — the node's -Z — which is the
 negation of the surface-to-light vector `three.light.direction` holds. The
 negation belongs in the importer, once.

 @return? js::THREW
*>
fn js::Value? js_asset_lights(JsRuntime* self, AssetId id)
{
	js::Value list = self.js.array()!;
	foreach (&light : self.pass.assets.slot(id).lights)
	{
		AssetLightRecord record = {
			.name = light.name,
			.kind = light.kind,
			.color = { light.color[0], light.color[1], light.color[2] },
			.intensity = light.intensity,
			.range = light.range,
			.inner_cone = light.inner_cone,
			.outer_cone = light.outer_cone,
			.position = light.position,
			.direction = light.direction,
			.gltf_node = light.gltf_node,
			.area_shape = light.area_shape,
			.width = light.width,
			.height = light.height,
			.spread = light.spread,
			.right = light.right,
			.up = light.up,
		};
		self.js.push(list, self.js.@object_of(record)!);
	}
	return list;
}

<*
 `assetCameras(asset)` — the file's cameras, placed in world space, as
 `AssetCamera`s.

 `distance` is the one number the file does not carry: a glTF camera is an eye and
 a heading and this renderer's is a turntable, so the orbit point has to be chosen.
 `record_lights` chooses it — where the view ray passes the middle of the asset's
 bounds — and says why there.

 `yfov` is radians and vertical, exactly as the file states it and exactly what
 `Camera.projection` wants. An orthographic camera reports zeroes for all four
 lens numbers, because there is no orthographic projection here to describe.

 @return? js::THREW
*>
fn js::Value? js_asset_cameras(JsRuntime* self, AssetId id)
{
	js::Value list = self.js.array()!;
	foreach (&camera : self.pass.assets.slot(id).cameras) self.js.push(list, self.js.@object_of(*camera)!);
	return list;
}

// What the file's `KHR_physics_rigid_bodies` says about one node.
struct AssetBodyRecord
{
	int gltf_node;
	String name;
	uint shape;
	bool has_collider;
	bool trigger;
	bool has_motion;
	bool kinematic;
	float mass;
	float gravity_factor;
	float linear_damping;
	float angular_damping;
	Vec3 linear_velocity;
	Vec3 angular_velocity;
	bool has_material;
	float friction;
	float restitution;
	bool has_proxy;
	bool filtered;
}

<*
 `assetBodies(asset)` — what the file's `KHR_physics_rigid_bodies` says, node by
 node, as `AssetBodyRecord`s.

 A description and not a body, for `assetLights`' reason: the file states what
 collides and what to do about it is a policy over the statement.
 `instantiate({ physics: true })` is one policy and a script is free to write
 another — `asset.colliders` is the list it reads.

 `shape` is `AssetShape`'s ordinal — 0 mesh, 1 convex hull, then box, sphere,
 capsule, cylinder — passed through untranslated, the same bargain
 `assetLights`' `kind` strikes.

 Everything is in the file's own units, which are also this engine's: mass in
 kilograms, friction and restitution 0..1, velocities per second. The implicit
 shape's own numbers are not here — they are already in the proxy mesh the
 loader built, and a script that wants them reads that mesh's bounds.

 @return? js::THREW
*>
fn js::Value? js_asset_bodies(JsRuntime* self, AssetId id)
{
	js::Value list = self.js.array()!;
	foreach (&body : self.pass.assets.slot(id).bodies)
	{
		AssetBodyRecord record = {
			.gltf_node = body.gltf_node,
			.name = body.name,
			.shape = (uint)body.shape.ordinal,
			.has_collider = body.has_collider,
			.trigger = body.trigger,
			.has_motion = body.has_motion,
			.kinematic = body.kinematic,
			.mass = body.mass,
			.gravity_factor = body.gravity_factor,
			.linear_damping = body.linear_damping,
			.angular_damping = body.angular_damping,
			.linear_velocity = body.linear_velocity,
			.angular_velocity = body.angular_velocity,
			.has_material = body.has_material,
			.friction = body.friction,
			.restitution = body.restitution,
			.has_proxy = body.proxy >= 0,
			.filtered = body.filtered,
		};
		self.js.push(list, self.js.@object_of(record)!);
	}
	return list;
}

// One `physicsJoints` entry, without its limits — those are an array beside it.
struct AssetJointRecord
{
	int body_a;
	int body_b;
	Vec3 pivot;
	bool collide;
}

<*
 `assetJoints(asset)` — the file's `physicsJoints`, each resolved to the two nodes
 it holds: an `AssetJointRecord` plus `limits`, an array of `AssetJointLimit`s.

 glTF hangs a joint on a pivot node parented to one body and names a second pivot
 parented to the other, so the bodies are the pivots' parents; `record_joints`
 walks that and this reports the answer. A pivot with no parent reports -1, which
 is a joint the consumer cannot make.

 The limits are already `three.physics.joint`'s: an axis mask, a min and a max, a
 stiffness and a damping, split into a linear row and an angular row (`kind` 0 and
 1) exactly as the JS side packs them. glTF's description of a joint and this one
 are the same object, which is why nothing is translated on the way through.

 @return? js::THREW
*>
fn js::Value? js_asset_joints(JsRuntime* self, AssetId id)
{
	js::Value list = self.js.array()!;
	foreach (&joint : self.pass.assets.slot(id).joints)
	{
		js::Value limits = self.js.array((uint)joint.limits.len())!;
		foreach (limit : joint.limits) self.js.push(limits, self.js.@object_of(limit)!);

		AssetJointRecord record = {
			.body_a = joint.body_a,
			.body_b = joint.body_b,
			.pivot = joint.pivot,
			.collide = joint.collide,
		};
		js::Value entry = self.js.@object_of(record)!;
		self.js.set(entry, "limits", limits)!;
		self.js.push(list, entry);
	}
	return list;
}

<*
 `assetClips(asset)` — the names of a file's animations.

 Free: names and durations are read at load out of the JSON chunk, so this
 answers on a file that has uploaded nothing. `mesh.animations` is what a script
 sees, and it is a plain array of strings rather than clip objects because a name
 is the only handle `play` takes.

 @return? js::THREW
*>
fn js::Value? js_asset_clips(JsRuntime* self, AssetId id)
{
	js::Value names = self.js.array()!;
	foreach (&clip : self.pass.assets.slot(id).clips) self.js.push(names, self.js.string(clip.name)!);
	return names;
}

<*
 `assetBones(asset)` — every joint name of every skin in a file.

 What a socket is named by, and unguessable without it: a rig calls its hand
 `mixamorig:RightHand` or `hand.R` or `Bone.014` depending on who exported it, and
 a baked instantiation drops the bone nodes, so JavaScript has no other way to
 find out. Read straight off the asset's node names, so this costs no upload and
 no buffer.

 In skin order and then joint order, deduplicated: two skins sharing a joint —
 which a file with a body mesh and a head mesh usually does — name it once.

 @return? js::THREW
*>
fn js::Value? js_asset_bones(JsRuntime* self, AssetId id)
{
	Asset* asset     = self.pass.assets.slot(id);
	js::Value names = self.js.array()!;

	// The names already emitted, borrowed from the asset rather than copied — this
	// list outlives nothing and the asset outlives it.
	List{String} seen;
	seen.init(mem, 16);
	defer seen.free();

	foreach (&skin : asset.skins)
	{
		foreach (source : skin.joints)
		{
			if (source >= asset.nodes.len()) continue;
			String name = asset.nodes[source].name;
			if (name.len == 0) continue;

			bool already = false;
			foreach (had : seen)
			{
				if (had == name)
				{
					already = true;
					break;
				}
			}
			if (already) continue;

			seen.push(name);
			self.js.push(names, self.js.string(name)!);
		}
	}
	return names;
}

// One file of `three.inventory()`, before its lists.
struct InventoryRecord
{
	String path;
	uint triangles;
	uint nodes;
	uint skins;
}

<*
 `three.inventory()` — every glTF in the assets directory, described without
 being loaded.

 `scene/inventory.c3` carries the argument. In short: without it, finding out
 what a file held means uploading it, so "what have I got" — the question an
 agent asks first — is the most expensive one it can ask.

 Answers with an empty array rather than throwing when there is no assets root,
 because "nothing here" is the true answer for a plain `--mcp` run and an
 exception would make a script written for a game boot fail loudly under one.

 @return? js::THREW
*>
fn js::Value? js_inventory(JsRuntime* self)
{
	js::Value listed = self.js.array()!;
	if (self.modules.root.len == 0) return listed;

	Inventory? found = take_inventory(self.modules.root);
	if (catch err = found) return self.js.fail("could not read %s: %s", self.modules.root, err)~;
	defer found.free_entries();

	foreach (&entry : found)
	{
		InventoryRecord record = {
			.path = entry.path,
			.triangles = entry.triangles,
			.nodes = entry.nodes,
			.skins = entry.skins,
		};
		js::Value described = self.js.@object_of(record)!;

		js::Value meshes = self.js.array()!;
		foreach (mesh : entry.meshes) self.js.push(meshes, self.js.@object_of(mesh)!);
		self.js.set(described, "meshes", meshes)!;

		js::Value animations = self.js.array()!;
		foreach (name : entry.animations) self.js.push(animations, self.js.string(name)!);
		self.js.set(described, "animations", animations)!;

		js::Value markers = self.js.array()!;
		foreach (marker : entry.markers) self.js.push(markers, self.js.@object_of(marker)!);
		self.js.set(described, "markers", markers)!;

		// Omitted rather than zeroed when the file had no position accessor to read
		// them from: a box at the origin and "we could not tell" are different
		// answers, and only one of them is safe to place a camera by.
		if (entry.has_bounds) self.js.set(described, "bounds", self.js.@object_of(entry.bounds)!)!;

		self.js.push(listed, described);
	}
	return listed;
}

<*
 `terrain(width, depth, segments, skirt, heights)` — a heightfield, as an asset.

 `heights` is a `Float64Array` of `(segments + 1)^2` numbers, row-major in z then
 x: the prelude has to walk the caller's input to validate it anyway. A callback
 is resolved on the JS side into exactly this array, which is why there is no
 callback here.

 The length is checked against the segment count and refused rather than padded:
 a height array off by a row is a surface that reads at the wrong stride, which
 produces a plausible-looking diagonal ripple and nothing that says why.

 @return? js::THREW
*>
fn AssetId? js_terrain(JsRuntime* self, float width, float depth, int segments, float skirt, double[] heights)
{
	need_device(self, "building a shape")!;

	if (segments < (int)MIN_TERRAIN_SEGMENTS || segments > (int)MAX_TERRAIN_SEGMENTS)
	{
		return self.js.fail("a terrain has between %d and %d segments a side, got %d",
			MIN_TERRAIN_SEGMENTS, MAX_TERRAIN_SEGMENTS, segments)~;
	}

	long wanted = ((long)segments + 1) * ((long)segments + 1);
	if (heights.len != wanted)
	{
		return self.js.fail("a %d-segment terrain wants %d heights, got %d — the array is (segments + 1) squared, row-major in z",
			segments, wanted, heights.len)~;
	}

	@pool()
	{
		Heightfield field = {
			.width = width,
			.depth = depth,
			.segments = (uint)segments,
			.skirt = skirt > 0 ? skirt : 0,
		};
		field.heights.tinit((usz)wanted);
		// A NaN here would spread through the normals into every neighbouring
		// vertex and put a black hole in the middle of the ground.
		foreach (height : heights) field.heights.push(finite((float)height));

		AssetId? asset = self.pass.assets.terrain(&self.renderer.gpu, &field);
		if (catch err = asset) return self.js.fail("could not build a terrain: %s", err)~;
		return asset;
	};
}

// An Asset handle argument that may name an asset since unloaded — for a verb whose
// answer to that is null rather than a throw.
struct AnyAsset
{
	AssetId id;
}

<*
 @return? js::THREW
*>
fn void? AnyAsset.from_js(&self, js::Call* c, int at)
{
	JsRuntime* rt = c.js.user;
	void* data = js::data_of(c.get(at), rt.asset_class);
	if (!data) return c.type_error(at, "an asset")~;
	self.id = unpack_id(data, AssetId);
}

// The ground at a point: its height, and the normal to lean with.
struct TerrainSample
{
	float height;
	Vec3 normal;
}

<*
 `terrainAt(asset, x, z)` — the ground and its normal at a point, as a
 `TerrainSample`.

 Both in one answer, because every caller wants both: something placed on a
 hillside needs the height to sit at and the normal to lean with, and two calls
 would sample the grid twice to answer one question.

 `null` when the handle does not name a live terrain — which the prelude turns
 into a sentence. Not a throw here, because the same call answers "is this a
 terrain at all" and a fault would make the ordinary negative answer expensive.

 @return? js::THREW
*>
fn js::Value? js_terrain_at(JsRuntime* self, AnyAsset asset, float x, float z)
{
	Heightfield* field = self.pass.assets.terrain_field(asset.id);
	if (field == null) return js::NULL;
	TerrainSample sample = { .height = field.height_at(x, z), .normal = field.normal_at(x, z) };
	return self.js.@object_of(sample);
}
