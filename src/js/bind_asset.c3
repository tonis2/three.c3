<*
 `three.load()`, `three.BoxGeometry()` and what an asset can be asked about.

 Five verbs, and the smallest set that lets `prelude.js` build an `Asset` whose
 `mesh(name)` lookup happens in JavaScript: the load itself, the path back, the
 mesh names in order, one shape builder for all five parametric kinds, and the
 hull of a point cloud.
 Resolving a name to an index on this side would be a crossing per lookup and a
 second implementation of a search the host already has; handing the names over
 once means `asset.meshes` is also something a script can print when it has
 guessed a name wrong, which is the case that actually happens.

 **Loading the same path twice returns the same asset**, because `Assets.load`
 does — that is the coarse half of "linked, not duplicated" (`plan.md` §2), and
 it means a script that loads a kit in a loop pays once. `primitive` obeys the
 same rule against a key made of its parameters, which is what makes a thousand
 `new three.BoxGeometry(1, 1, 1)` one upload and one draw call; see
 `scene/primitive.c3`.
*>
module three;

import std::io;
import std::math;
import std::math::vector;
import qjs;
import image;
import std::collections::list;

<*
 `load(path)` — the asset's index, for `add`.

 The device is required, and the message says so rather than throwing something
 about a null pointer: a runtime built for the scene-math tests has no GPU, and
 a script that reaches for a file in one should be told which of the two it is
 missing.
*>
fn void js_load(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("three.load needs a GPU device and this context has none");
		return;
	}

	@pool()
	{
		String path = arg_text(&js, argc, args, 0, tmem);
		if (path.len == 0)
		{
			*out = js.raise("three.load(path) wants a path to a .glb or .gltf");
			return;
		}

		// Relative to the assets directory in a `--assets` boot, and to the
		// working directory otherwise — see `JsRuntime.resolve_asset`. Resolved
		// before the load so that a path reaching out of the game is refused by
		// name rather than opening whatever it found.
		String? opening = self.resolve_asset(path, tmem);
		if (catch err = opening)
		{
			if (err == MODULE_ESCAPES_ASSETS_ROOT)
			{
				*out = js.raise(string::tformat(
					"cannot load '%s': it climbs out of the assets directory, and a game may only read "
					"what is inside its own", path
				));
				return;
			}
			*out = js.raise(string::tformat("cannot load '%s': %s", path, err));
			return;
		}

		AssetId? asset = self.pass.assets.load(&self.renderer.gpu, opening);
		if (catch err = asset)
		{
			// The fault name verbatim: ASSET_HAS_NO_MESHES and the io faults are
			// each a different thing to do about it, and flattening them into
			// "could not load" would cost the agent the one word that says which.
			*out = js.raise(string::tformat("could not load %s: %s", path, err));
			return;
		}

		*out = asset_value(&js, asset);
	};
}

<*
 `texture(path)` — decode a PNG or JPEG and upload it, as `[index, width, height]`.

 Three numbers rather than a bare index because the prelude's `Texture` wants the
 extents and there is no second verb to ask for them: an agent sizing a plane to
 an image's aspect ratio would otherwise have to guess, and a texture that loaded
 at half the resolution it expected is exactly the thing worth being able to see.

 **The path goes through `resolve_asset`, the same door `three.load` uses**, so
 under `--assets` a texture may only come from inside the game — a script cannot
 reach `../../etc/passwd` and hand its bytes to a decoder.

 The index is not a generational handle, unlike an asset or a node. It does not
 need to be: the only way a script gets one is the `Texture` the prelude wraps it
 in, that object marks itself dead on `dispose()`, and a second
 `three.texture()` of the same file returns a second object holding a reference
 of its own. So a stale index cannot be presented — there is no live JS value
 carrying one.
*>
fn void js_texture(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("three.texture needs a GPU device and this context has none");
		return;
	}

	@pool()
	{
		String path = arg_text(&js, argc, args, 0, tmem);
		if (path.len == 0)
		{
			*out = js.raise("three.texture(path) wants a path to a .png or .jpg");
			return;
		}

		String? opening = self.resolve_asset(path, tmem);
		if (catch err = opening)
		{
			if (err == MODULE_ESCAPES_ASSETS_ROOT)
			{
				*out = js.raise(string::tformat(
					"cannot load '%s': it climbs out of the assets directory, and a game may only read "
					"what is inside its own", path
				));
				return;
			}
			*out = js.raise(string::tformat("cannot load '%s': %s", path, err));
			return;
		}

		int? index = self.pass.assets.load_texture_file(&self.renderer.gpu, opening);
		if (catch err = index)
		{
			*out = js.raise(texture_failure(err, path));
			return;
		}

		Texture* uploaded = self.pass.assets.texture_at(index);
		qjs::Value triple = js.array();
		js.set_index(triple, 0, qjs::int_value(index));
		js.set_index(triple, 1, qjs::int_value((int)uploaded.width));
		js.set_index(triple, 2, qjs::int_value((int)uploaded.height));
		*out = triple;
	};
}

<*
 `dataTexture(bytes, width, height)` — pixels a script built, as `[index, w, h]`.

 **The bytes are borrowed and are copied before this returns.** `js.bytes` points
 into the engine's own storage for the `Uint8Array` the script is holding, which
 moves if the array is resized and is gone when it is collected — so the only
 safe thing to do with it is exactly what happens here: read it inside the call.
 `claim_texture` hashes it, copies it into a staging buffer and uploads, all
 before control goes back to JavaScript. Nothing keeps the pointer.

 **Deduplicated against every other texture, which is the interesting part.**
 Pixels generated in a script and the identical image loaded from a `.png` are
 one upload, because the hash is over RGBA bytes and has no idea where they came
 from. A script that regenerates the same texture on every frame pays for one.

 The size is stated rather than inferred, and checked against the array's length.
 The alternative — deriving one from the other — cannot tell a 64x64 from a
 128x32, so a script that had its dimensions the wrong way round would get a
 skewed picture and no complaint.
*>
fn void js_data_texture(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("three.DataTexture needs a GPU device and this context has none");
		return;
	}

	int width = arg_int(&js, argc, args, 1);
	int height = arg_int(&js, argc, args, 2);
	if (width <= 0 || height <= 0)
	{
		*out = js.raise(string::tformat(
			"new three.DataTexture(data, width, height) wants positive dimensions, got %dx%d", width, height
		));
		return;
	}
	if (width > MAX_TEXTURE_SIDE || height > MAX_TEXTURE_SIDE)
	{
		*out = js.raise(string::tformat(
			"%dx%d is past the %d-pixel limit three.DataTexture accepts on a side", width, height, MAX_TEXTURE_SIDE
		));
		return;
	}

	char[] pixels = argc > 0 ? js.bytes(args[0]) : (char[]){};
	if (pixels.len == 0)
	{
		// An empty slice means "not a Uint8Array" *and* "an empty one", and the
		// message covers both because the fix is the same either way: the prelude
		// has already widened a plain Array into a Uint8Array before this, so
		// anything arriving here without bytes had none to give.
		*out = js.raise("new three.DataTexture(data, ...) wants a Uint8Array of RGBA bytes, and this one is empty");
		return;
	}

	usz wanted = (usz)width * (usz)height * 4;
	if (pixels.len != wanted)
	{
		*out = js.raise(string::tformat(
			"%dx%d is %d RGBA bytes and %d were given — four per pixel, in r, g, b, a order",
			width, height, wanted, pixels.len
		));
		return;
	}

	// An `Image` over the borrowed bytes rather than a copy of them. `to_rgba`
	// inside `claim_texture` makes the one copy this path needs; a second one
	// here would be 1 MB memcpy'd for nothing on a 512x512.
	//
	// **The null allocator is what makes borrowing safe.** `Image.free` frees
	// nothing without one, so this struct owning bytes it did not allocate can
	// never free the engine's storage — and it is never freed here anyway,
	// because it is not ours to free.
	image::Image borrowed = {
		.width = (uint)width,
		.height = (uint)height,
		.bit_depth = 8,
		.format = image::PixelFormat.RGBA,
		.pixels = pixels,
		.allocator = (Allocator)null,
	};

	int? index = self.pass.assets.claim_texture(&self.renderer.gpu, borrowed);
	if (catch err = index)
	{
		*out = js.raise(string::tformat("could not upload the texture: %s", err));
		return;
	}

	// **Read back off the upload, not echoed from the arguments.** The two agree
	// when everything is right, which is exactly why echoing is tempting and
	// wrong: it makes `tex.width` a restatement of what the caller already said
	// rather than a report of what happened, so a dimension lost or transposed
	// anywhere between here and the device is invisible from JavaScript. Written
	// as an echo first, and a `.width`/`.height` swap injected into the `Image`
	// above passed the whole suite.
	Texture* uploaded = self.pass.assets.texture_at(index);
	qjs::Value triple = js.array();
	js.set_index(triple, 0, qjs::int_value(index));
	js.set_index(triple, 1, qjs::int_value((int)uploaded.width));
	js.set_index(triple, 2, qjs::int_value((int)uploaded.height));
	*out = triple;
}

<*
 The largest side `three.DataTexture` will take.

 Not a device limit — `maxImageDimension2D` is 16384 on everything this targets —
 but a limit on the mistake. The dimensions and the byte count are checked against
 each other, so a wrong pair is refused rather than uploaded; this is the guard
 for a *right* pair that is absurd, where the array was built by a loop with a
 bad bound and the allocation is what fails, several seconds later, somewhere
 else. 8192x8192 RGBA is 256 MB, which is already past what anyone means.
*>
const int MAX_TEXTURE_SIDE = 8192;

<*
 Turn a texture fault into a sentence that says what to do about it.

 Each of the three is a different next move — check the path, convert the file,
 re-export it at 8 bits — and "could not load" would cost the agent all of that.
*>
fn String texture_failure(fault err, String path) @local
{
	switch (err)
	{
		case TEXTURE_UNREADABLE:
			return string::tformat("there is no readable file at '%s'", path);
		case TEXTURE_FORMAT_UNKNOWN:
			return string::tformat(
				"'%s' is not a PNG or a JPEG — those are the two three.texture reads, and the check is on the "
				"file's own first bytes rather than its name", path
			);
		case TEXTURE_BIT_DEPTH:
			return string::tformat("'%s' is a 16-bit PNG; save it as 8-bit and it will load", path);
		default:
			return string::tformat("could not load '%s': %s", path, err);
	}
}

<*
 `textureDispose(index)` — give back the reference the script's handle holds.

 Not a free. The slot goes only when nothing names it at all, so disposing a
 handle whose image is still on a material leaves the material drawing correctly
 — which is the behaviour that makes `dispose()` safe to call the moment a script
 is done *referring* to a texture, rather than something to be timed against the
 materials that use it.

 Waits for the device when this release is the last one, for
 `MeshPass.set_material_map`'s reason: the image is destroyed inside
 `release_texture` and a frame in flight may still be sampling it.
*>
fn void js_texture_dispose(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	int index = arg_int(&js, argc, args, 0);
	if (!self.pass.assets.texture_alive(index)) return;

	Gpu* gpu = self.renderer == null ? null : &self.renderer.gpu;
	if (gpu != null && self.pass.assets.texture_refs(index) == 1) gpu.wait_idle();
	self.pass.assets.release_texture(gpu, index);
}

<*
 `textureRead(index, into)` — copy a texture's pixels into a caller's
 `Uint8Array`.

 ## The destination is an argument, and that is the design

 Every other way of getting bytes back to a script is worse here. Building a
 plain `Array` costs one host crossing per element, which is 65,536 of them for
 a 128x128 texture. Handing out an `ArrayBuffer` over host memory — what
 `qjs::Context.buffer` does — means the host now owns an allocation whose
 lifetime is decided by the script, and the only safe end to that is a detach the
 script has to be trusted to trigger.

 So the script supplies the memory and the host writes into it. `js.bytes` gives
 a mutable slice of the engine's own storage for the array, no copy, no
 ownership question, and the same function `dataTexture` already reads *from*.
 It also puts the allocation at the call site, where a caller reading a texture
 every frame can see what it costs.

 **The bytes are the uploaded ones, not the sampled ones.** The copy performs no
 format conversion, so an sRGB texture reads back as the sRGB bytes it was made
 from — which is what makes `new three.DataTexture(px, w, h).read()` return `px`,
 and what `png::save_file` wants.

 @return `The number of bytes written, so a caller can assert on it rather than trusting the length it passed.`
*>
fn void js_texture_read(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("texture.read() needs a GPU device and this context has none");
		return;
	}

	int index = arg_int(&js, argc, args, 0);
	if (!self.pass.assets.texture_alive(index))
	{
		*out = js.raise("texture.read() was given a texture that has been disposed");
		return;
	}

	Texture* texture = self.pass.assets.texture_at(index);
	sz need = (sz)texture.width * (sz)texture.height * 4;

	char[] dst = argc > 1 ? js.bytes(args[1]) : (char[]){};
	if (dst.len < need)
	{
		*out = js.raise(string::tformat(
			"texture.read() wants a Uint8Array of at least %d bytes for a %dx%d image, and was given %d",
			need, texture.width, texture.height, dst.len
		));
		return;
	}

	if (catch err = texture.read_pixels(&self.renderer.gpu, dst))
	{
		*out = js.raise(string::tformat("texture.read() could not copy the image back: %s", err));
		return;
	}

	*out = qjs::int_value((int)need);
}

<*
 `primitive(kind, a, b, c, u, v, w, capped)` — build a parametric shape, or hand
 back the asset already built for exactly these numbers.

 One verb for all five kinds rather than one each, because the layer below is
 already a switch on the kind and a per-shape verb here would be five copies of
 this function differing only in which arguments they ignore. What the numbers
 mean is `Primitive`'s business; `prelude.js`'s `BoxGeometry` and friends are
 where they get their Three.js names, their defaults and their range checks.

 The device is required and says so: a shape has to be uploaded to be drawn, and
 a runtime built for the scene-math tests has nowhere to put it.
*>
fn void js_primitive(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("building a shape needs a GPU device and this context has none");
		return;
	}

	@pool()
	{
		String name = arg_text(&js, argc, args, 0, tmem);
		PrimitiveKind? kind = primitive_kind(name);
		if (catch kind)
		{
			*out = js.raise(string::tformat(
				"there is no shape called '%s' — three.c3 builds: box, sphere, plane, cylinder, torus",
				name
			));
			return;
		}

		// Clamped rather than trusted: the prelude has already refused anything
		// out of range with a better sentence, and this is what a script that
		// called `__three.primitive` itself gets instead of an allocation the
		// size of the device.
		Primitive shape = {
			.kind = kind,
			.a = arg_float(&js, argc, args, 1),
			.b = arg_float(&js, argc, args, 2),
			.c = arg_float(&js, argc, args, 3),
			.u = primitive_segments((uint)math::max(arg_int(&js, argc, args, 4), 0), 1),
			.v = primitive_segments((uint)math::max(arg_int(&js, argc, args, 5), 0), 1),
			.w = primitive_segments((uint)math::max(arg_int(&js, argc, args, 6), 0), 1),
			.capped = arg_truth(&js, argc, args, 7),
		};

		AssetId? asset = self.pass.assets.primitive(&self.renderer.gpu, shape);
		if (catch err = asset)
		{
			*out = js.raise(string::tformat("could not build a %s: %s", name, err));
			return;
		}

		*out = asset_value(&js, asset);
	};
}

<*
 `convex(points)` — the convex hull of a point cloud, as an asset.

 `points` is a flat JavaScript array of numbers, `x, y, z` per point, because
 that is the one shape the crossing can read in a single pass: an array of
 `Vector3`s would be three property lookups and a released value per point,
 and `prelude.js` has to walk the caller's input anyway to validate it. It
 flattens while it validates and hands the result over already checked.

 Refused rather than clamped at both ends, unlike `primitive`'s segment counts:
 there is no nearest sensible cloud to substitute for a bad one, and a hull
 quietly built from the first 65536 of a script's points would be a shape nobody
 asked for. See `scene/convex.c3` for why a cloud crossing this boundary leaves
 the thesis where it was.
*>
fn void js_convex(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("building a shape needs a GPU device and this context has none");
		return;
	}

	long length = argc > 0 ? js.length(args[0]) : -1;
	if (length < 0 || length % 3 != 0)
	{
		*out = js.raise(
			"three.ConvexGeometry wants a flat array of x, y, z numbers — its length must be a multiple of three"
		);
		return;
	}

	usz count = (usz)(length / 3);
	if (count < MIN_CONVEX_POINTS)
	{
		*out = js.raise(string::tformat(
			"a convex hull needs at least %d points, got %d", MIN_CONVEX_POINTS, count
		));
		return;
	}
	if (count > MAX_CONVEX_POINTS)
	{
		*out = js.raise(string::tformat(
			"a convex hull is capped at %d points, got %d", MAX_CONVEX_POINTS, count
		));
		return;
	}

	@pool()
	{
		Vec3[] points = alloc::new_array(tmem, Vec3, (sz)count);
		for (usz i = 0; i < count; i++)
		{
			for (usz axis = 0; axis < 3; axis++)
			{
				qjs::Value component = js.index(args[0], (uint)(i * 3 + axis));
				double value = js.number(component);
				js.release(component);
				// The prelude has already refused a non-finite component with a
				// sentence naming the point it was in. This is the backstop for a
				// forged call, and zero is the only substitution that cannot turn
				// the hull inside out or send quickhull off to infinity.
				points[i][axis] = math::is_finite(value) ? (float)value : 0.0f;
			}
		}

		AssetId? asset = self.pass.assets.convex(&self.renderer.gpu, points);
		if (catch err = asset)
		{
			// Said rather than named, unlike `js_load`'s faults: there is exactly
			// one thing that can go wrong here that is about the caller's input,
			// and "CONVEX_HULL_IS_DEGENERATE" does not tell an agent staring at a
			// generated cloud which of the three ways it collapsed.
			if (err == CONVEX_HULL_IS_DEGENERATE)
			{
				*out = js.raise(string::tformat(
					"those %d points enclose no volume — they are all equal, all on one line or all on one "
					"plane, and a convex hull needs four that are none of those",
					count
				));
				return;
			}
			*out = js.raise(string::tformat("could not build a convex hull from %d points: %s", count, err));
			return;
		}

		*out = asset_value(&js, asset);
	};
}

<*
 `lines(kind, divisions)` — a debug line shape, or the one already built for
 exactly this shape.

 `primitive`'s twin down to the clamping, and deliberately so: a helper is an
 ordinary asset over an ordinary mesh, and the only thing that makes it a helper
 is the material `prelude.js` puts on it. `scene/lines.c3` carries the argument
 for why debug draw is geometry here rather than an immediate-mode side channel.

 `divisions` is the grid's and is ignored by the other two — `LineShape.key`
 leaves it out of their keys, so a box asked for with a stray division count is
 still the one box asset.
*>
fn void js_lines(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("building a helper needs a GPU device and this context has none");
		return;
	}

	@pool()
	{
		String name = arg_text(&js, argc, args, 0, tmem);
		LineKind? kind = line_kind(name);
		if (catch kind)
		{
			*out = js.raise(string::tformat(
				"there is no line shape called '%s' — three.c3 builds: box, segment, grid", name
			));
			return;
		}

		// Clamped rather than trusted, for `primitive`'s reason: the prelude has
		// already refused anything out of range with a better sentence, and this
		// is the backstop for a script that reached past it into `__three`.
		int asked = arg_int(&js, argc, args, 1);
		LineShape shape = {
			.kind = kind,
			.divisions = (uint)math::clamp(asked, 1, (int)MAX_GRID_DIVISIONS),
		};

		AssetId? asset = self.pass.assets.lines(&self.renderer.gpu, shape);
		if (catch err = asset)
		{
			*out = js.raise(string::tformat("could not build a %s helper: %s", name, err));
			return;
		}

		*out = asset_value(&js, asset);
	};
}

<*
 `wireframe(index, generation, mesh)` — one mesh's triangles as the edges
 between them.

 **The mesh has to be resident, and that is a sentence rather than an empty
 asset.** The edges are read off `hull_positions`/`hull_triangles`, which are
 filled at upload — and a mesh reaches the device only when something drawing it
 is added to a scene. An empty wireframe would draw nothing and read as a helper
 that does not work, so the two faults each get the thing to do about them.
*>
fn void js_wireframe(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("building a helper needs a GPU device and this context has none");
		return;
	}

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	uint mesh = (uint)math::max(arg_int(&js, argc, args, 2), 0);
	AssetId? asset = self.pass.assets.wireframe(&self.renderer.gpu, id, mesh);
	if (catch err = asset)
	{
		if (err == LINE_MESH_NOT_RESIDENT)
		{
			*out = js.raise(
				"a wireframe is built from the mesh's own triangles, and those reach this side when the "
				"mesh is uploaded — which happens when something drawing it is added to a scene. "
				"scene.add(mesh) first, then make the helper"
			);
			return;
		}
		if (err == NO_SUCH_LINE_MESH)
		{
			*out = js.raise(string::tformat(
				"that asset has no mesh %d — asset.meshes lists the ones it has", mesh
			));
			return;
		}
		*out = js.raise(string::tformat("could not build a wireframe of mesh %d: %s", mesh, err));
		return;
	}

	*out = asset_value(&js, asset);
}

<*
 `exportScene(path)` — write the scene to a `.glb`, and say what went into it.

 `js_load`'s other half, and it goes through the same door: the path is resolved
 by `resolve_asset`, so under `--assets` a script may write inside the game
 directory and nowhere else. A game that could write anywhere on the disk would
 be a worse thing than one that cannot export at all.

 No device is needed and none is used. `scene/export.c3` reads a mesh out of the
 file it came from or tessellates it again from its description, so an export is
 the one heavy verb here that works on a runtime with no GPU — and would, except
 that a scene with nothing uploaded into it has nothing to export either.

 The report is an object rather than a count because every number in it answers a
 different question about whether the file is the scene: `meshes` against
 `stats().uniqueMeshes`, `instances` against `stats().instances`, and `skipped`
 and `shaded` for the two things that deliberately did not survive the crossing.

 `batches` is how many of `nodes` were written as instanced nodes, which is the
 one number that has no counterpart in `stats()` — it says how much of the scene
 the file managed to keep as repetition rather than as a thousand named copies.

 The second argument is `flatten`, which gives up the hierarchy to batch copies
 that are not siblings — the ones `asset.instantiate()` produces, each in a group
 of its own. `scene/export.c3` argues when that is the trade to make.
*>
fn void js_export(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.pass == null)
	{
		*out = js.raise("there is no scene to export in this context");
		return;
	}

	@pool()
	{
		String path = arg_text(&js, argc, args, 0, tmem);
		if (path.len == 0)
		{
			*out = js.raise("scene.export(path) wants a path to write a .glb to");
			return;
		}

		String? writing = self.resolve_asset(path, tmem);
		if (catch err = writing)
		{
			if (err == MODULE_ESCAPES_ASSETS_ROOT)
			{
				*out = js.raise(string::tformat(
					"cannot export to '%s': it climbs out of the assets directory, and a game may only "
					"write inside its own", path
				));
				return;
			}
			*out = js.raise(string::tformat("cannot export to '%s': %s", path, err));
			return;
		}

		// The prelude has already reduced the options object to this one flag, so
		// nothing here reads a property off a JavaScript value — an argument list
		// this side stays a list of scalars, which is what every other binding here
		// takes and what keeps the two sides from disagreeing about defaults.
		ExportReport? report = self.pass.export_scene(writing, arg_truth(&js, argc, args, 1));
		if (catch err = report)
		{
			if (err == EXPORT_HAS_NOTHING_TO_WRITE)
			{
				*out = js.raise(
					"there is nothing in this scene to draw, so there is nothing to export — it is empty, "
					"or everything in it is a helper or a hidden subtree, neither of which goes into a file"
				);
				return;
			}
			*out = js.raise(string::tformat("could not export to %s: %s", path, err));
			return;
		}

		qjs::Value described = js.object();
		js.set_property(described, "path", js.string(writing));
		js.set_property(described, "meshes", qjs::int_value((int)report.meshes));
		js.set_property(described, "entries", qjs::int_value((int)report.entries));
		js.set_property(described, "materials", qjs::int_value((int)report.materials));
		js.set_property(described, "images", qjs::int_value((int)report.images));
		js.set_property(described, "nodes", qjs::int_value((int)report.nodes));
		js.set_property(described, "instances", qjs::int_value((int)report.instances));
		js.set_property(described, "batches", qjs::int_value((int)report.batches));
		js.set_property(described, "skipped", qjs::int_value((int)report.skipped));
		js.set_property(described, "shaded", qjs::int_value((int)report.shaded));
		js.set_property(described, "bytes", qjs::number_value((double)report.bytes));
		*out = described;
	};
}

fn void js_asset_path(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;
	*out = js.string(self.pass.assets.slot(id).path);
}

<*
 Every mesh in an asset, by name, in load order.

 A glTF mesh with several primitives produced several `GpuMesh` entries sharing
 one name, so this list can repeat — and `Asset.mesh(name)` in the prelude takes
 the first, which is what `Assets.find_mesh` does and what a caller naming a mesh
 means.
*>
fn void js_mesh_names(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	qjs::Value names = js.array();
	foreach (i, &mesh : self.pass.assets.slot(id).meshes)
	{
		js.set_index(names, (uint)i, js.string(mesh.name));
	}
	*out = names;
}

<*
 `meshBounds(index, generation, mesh)` — one mesh's box in its own local space,
 as `[minX, minY, minZ, maxX, maxY, maxZ]`, or `null` if the index names nothing.

 **This costs nothing and is available before the mesh is on the device.** A
 `GpuMesh` exists from the moment the JSON is parsed, and `bounds` is one of the
 three fields filled in then rather than at upload — it is the POSITION
 accessor's required `min`/`max`, the same numbers `inventory.c3` reads. So
 asking how big a kit piece is does not upload the kit.

 **Per mesh index, not per name.** A glTF mesh with several primitives produced
 several entries sharing a name, and a `Mesh` node draws exactly one of them, so
 the box a script wants is the one belonging to the thing it placed.
*>
fn void js_mesh_bounds(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	GpuMesh* mesh = self.pass.assets.mesh(id, (uint)arg_int(&js, argc, args, 2));
	*out = mesh == null ? qjs::null_value() : aabb_value(&js, mesh.bounds);
}

<*
 `assetNodes(index, generation)` — the asset's node tree, flattened into the
 objects `asset.instantiate()` builds.

 One entry per node that should exist, each naming its parent by position in the
 same array. Parents always come before their children, so `instantiate()` can
 walk it once and never look forward.

 **The tree is not built here and its shape is not decided here.**
 `Assets.flatten` decides — the same walk `Scene.instantiate` uses on the host —
 so a file placed by the CLI and a file placed by a script produce the same
 hierarchy. What crosses the boundary is a description, and JavaScript builds
 ordinary `Object3D`s from it that materialize through the normal `add` path.
 That is deliberate: an object handed back from here is one a script can move,
 hide, recolour and re-parent before it ever reaches a scene, because it is not
 special in any way.

 ## The rotation crosses twice, and both are needed

 Once as Euler angles, because that is what an `Object3D.rotation` is and a
 script that reads it back should see numbers rather than a quaternion nobody
 asked for. Once as the quaternion itself, because the Euler form is not exact:
 at gimbal lock — a rotation of exactly 90° about Y, which is the single most
 common thing anyone types into Blender — `asin` is evaluated where its slope is
 infinite and the recovered angle is off by about 3e-4 radians. That is 0.7mm at
 the end of a two-metre arm, which is a hairline gap between two kit pieces that
 were authored flush.

 So `prelude.js` shows the Euler triple and sends the quaternion, and writing an
 Euler angle drops the quaternion. `scene/node.c3` has the general form of this
 argument; this is the one place it has a number attached.

 @return `An array of [name, parent, mesh, px, py, pz, ex, ey, ez, sx, sy, sz, qx, qy, qz, qw, gltfNode, r, g, b, a].`
*>
fn void js_asset_nodes(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	List{PlacedNode} placed;
	placed.init(mem, 16);
	defer placed.free();
	self.pass.assets.flatten(id, &placed);

	qjs::Value nodes = js.array();
	foreach (i, &entry : placed)
	{
		Vec3 euler = euler_from_quat(entry.rotation);

		qjs::Value row = js.array();
		js.set_index(row, 0, js.string(entry.name));
		js.set_index(row, 1, qjs::int_value(entry.parent));
		js.set_index(row, 2, qjs::int_value(entry.mesh));
		js.set_index(row, 3, qjs::number_value(entry.position.x));
		js.set_index(row, 4, qjs::number_value(entry.position.y));
		js.set_index(row, 5, qjs::number_value(entry.position.z));
		js.set_index(row, 6, qjs::number_value(euler.x));
		js.set_index(row, 7, qjs::number_value(euler.y));
		js.set_index(row, 8, qjs::number_value(euler.z));
		js.set_index(row, 9, qjs::number_value(entry.scale.x));
		js.set_index(row, 10, qjs::number_value(entry.scale.y));
		js.set_index(row, 11, qjs::number_value(entry.scale.z));
		js.set_index(row, 12, qjs::number_value(entry.rotation.i));
		js.set_index(row, 13, qjs::number_value(entry.rotation.j));
		js.set_index(row, 14, qjs::number_value(entry.rotation.k));
		js.set_index(row, 15, qjs::number_value(entry.rotation.l));
		js.set_index(row, 16, qjs::int_value(entry.gltf_node));
		// The per-copy tint, which is white for everything but a copy an
		// instanced node placed. Four numbers rather than an object because the
		// row is already a flat array and `mesh.color` is already a flat array.
		js.set_index(row, 17, qjs::number_value(entry.color[0]));
		js.set_index(row, 18, qjs::number_value(entry.color[1]));
		js.set_index(row, 19, qjs::number_value(entry.color[2]));
		js.set_index(row, 20, qjs::number_value(entry.color[3]));

		js.set_index(nodes, (uint)i, row);
	}
	*out = nodes;
}

<*
 `assetClips(index, generation)` — the names of a file's animations.

 Free: names and durations are read at load out of the JSON chunk, so this
 answers on a file that has uploaded nothing. `mesh.animations` is what a script
 sees, and the reason it is a plain array of strings rather than clip objects is
 that a name is the only handle `play` takes.
*>
fn void js_asset_clips(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	qjs::Value names = js.array();
	foreach (i, &clip : self.pass.assets.slot(id).clips)
	{
		js.set_index(names, (uint)i, js.string(clip.name));
	}
	*out = names;
}

<*
 `three.inventory()` — every glTF in the assets directory, described without
 being loaded.

 `game.md` G1/S5, and `scene/inventory.c3` carries the argument for why it is
 worth a verb of its own. In short: before this, finding out what a file held
 meant uploading it, so "what have I got" — the question an agent asks first —
 was the most expensive one it could ask.

 Answers with an empty array rather than throwing when there is no assets root,
 because "nothing here" is the true answer for a plain `--mcp` run and an
 exception would make a script written for a game boot fail loudly under one.
*>
fn void js_inventory(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	qjs::Value listed = js.array();
	if (self.assets_root.len == 0)
	{
		*out = listed;
		return;
	}

	Inventory? found = take_inventory(self.assets_root);
	if (catch err = found)
	{
		js.release(listed);
		*out = js.raise(string::tformat("could not read %s: %s", self.assets_root, err));
		return;
	}
	defer found.free_entries();

	foreach (i, &entry : found)
	{
		qjs::Value described = js.object();
		js.set_property(described, "path", js.string(entry.path));
		js.set_property(described, "triangles", qjs::int_value((int)entry.triangles));
		js.set_property(described, "nodes", qjs::int_value((int)entry.nodes));
		js.set_property(described, "skins", qjs::int_value((int)entry.skins));

		qjs::Value meshes = js.array();
		foreach (m, &mesh : entry.meshes)
		{
			qjs::Value described_mesh = js.object();
			js.set_property(described_mesh, "name", js.string(mesh.name));
			js.set_property(described_mesh, "triangles", qjs::int_value((int)mesh.triangles));
			js.set_index(meshes, (uint)m, described_mesh);
		}
		js.set_property(described, "meshes", meshes);

		qjs::Value animations = js.array();
		foreach (a, name : entry.animations)
		{
			js.set_index(animations, (uint)a, js.string(name));
		}
		js.set_property(described, "animations", animations);

		// Omitted rather than zeroed when the file had no position accessor to
		// read them from: a box at the origin and "we could not tell" are
		// different answers, and only one of them is safe to place a camera by.
		if (entry.has_bounds)
		{
			qjs::Value bounds = js.object();
			js.set_property(bounds, "min", vec3_value(&js, entry.bounds.min));
			js.set_property(bounds, "max", vec3_value(&js, entry.bounds.max));
			js.set_property(described, "bounds", bounds);
		}

		js.set_index(listed, (uint)i, described);
	}
	*out = listed;
}
