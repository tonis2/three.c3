<*
 `three.load()`, `three.BoxGeometry()` and what an asset can be asked about.

 The smallest set of verbs that lets `prelude.js` build an `Asset` whose
 `mesh(name)` lookup happens in JavaScript: the load itself, the path back, the
 mesh names in order, one shape builder for all five parametric kinds, and the
 hull of a point cloud. Resolving a name to an index on this side would be a
 crossing per lookup and a second implementation of a search the host already
 has; handing the names over once also means `asset.meshes` is something a script
 can print when it has guessed a name wrong.

 Loading the same path twice returns the same asset, because `Assets.load` does —
 the coarse half of "linked, not duplicated" — so a script that loads a kit in a
 loop pays once. `primitive` obeys the same rule against a key made of its
 parameters, which is what makes a thousand `new three.BoxGeometry(1, 1, 1)` one
 upload and one draw call.
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
 about a null pointer: a runtime built for the scene-math tests has no GPU, and a
 script that reaches for a file in one should be told which of the two it is
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

		// Relative to the assets directory in a `--assets` boot, and to the working
		// directory otherwise. Resolved before the load so a path reaching out of
		// the game is refused by name rather than opening whatever it found.
		String? opening = self.resolve_asset(path, tmem);
		if (catch err = opening)
		{
			if (err == qjs::MODULE_ESCAPES_ROOT)
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
*>
fn qjs::Value texture_value(qjs::Context* js, int index, Texture* uploaded) @local
{
	qjs::Value fields = js.array();
	js.set_index(fields, 0, qjs::int_value(index));
	js.set_index(fields, 1, qjs::int_value((int)uploaded.width));
	js.set_index(fields, 2, qjs::int_value((int)uploaded.height));
	js.set_index(fields, 3, qjs::int_value((int)uploaded.levels));
	return fields;
}

<*
 `texture(path, space, mips)` — decode a PNG or JPEG and upload it.

 The path goes through `resolve_asset`, the same door `three.load` uses, so under
 `--assets` a texture may only come from inside the game.

 The index is not a generational handle, unlike an asset or a node, and does not
 need to be: the only way a script gets one is the `Texture` the prelude wraps it
 in, that object marks itself dead on `dispose()`, and a second `three.texture()`
 of the same file returns a second object holding a reference of its own. So a
 stale index cannot be presented.
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
			if (err == qjs::MODULE_ESCAPES_ROOT)
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

		ColorSpace space = color_space_of(arg_int(&js, argc, args, 1));
		bool mips = arg_truth_or(&js, argc, args, 2, true);

		int? index = self.pass.assets.load_texture_file(&self.renderer.gpu, opening, space, mips);
		if (catch err = index)
		{
			*out = js.raise(texture_failure(err, path));
			return;
		}

		*out = texture_value(&js, index, self.pass.assets.texture_at(index));
	};
}

<*
 `dataTexture(bytes, width, height, space, mips)` — pixels a script built.

 The bytes are borrowed and are copied before this returns. `js.bytes` points
 into the engine's own storage for the `Uint8Array` the script is holding, which
 moves if the array is resized and is gone when it is collected — so the only
 safe thing to do with it is read it inside the call. `claim_texture` hashes it,
 copies it into a staging buffer and uploads, all before control goes back to
 JavaScript.

 Deduplicated against every other texture, which is the interesting part: pixels
 generated in a script and the identical image loaded from a `.png` are one
 upload, because the hash is over RGBA bytes and has no idea where they came
 from. A script that regenerates the same texture every frame pays for one.

 The size is stated rather than inferred, and checked against the array's length.
 Deriving one from the other cannot tell a 64x64 from a 128x32, so a script that
 had its dimensions the wrong way round would get a skewed picture and no
 complaint.
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
		// has already widened a plain Array into a Uint8Array before this.
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

	// An `Image` over the borrowed bytes rather than a copy. `to_rgba` inside
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

	ColorSpace space = color_space_of(arg_int(&js, argc, args, 3));
	// `generateMipmaps` is worth reaching for here more than on a file. Pixels a
	// script generated are as often a table as a picture — a palette, a ramp, a
	// noise field indexed exactly — and a blurred level of a table is not a cheaper
	// approximation of anything.
	bool mips = arg_truth_or(&js, argc, args, 4, true);

	int? index = self.pass.assets.claim_texture(&self.renderer.gpu, borrowed, space, mips);
	if (catch err = index)
	{
		*out = js.raise(string::tformat("could not upload the texture: %s", err));
		return;
	}

	// Read back off the upload, not echoed from the arguments. The two agree when
	// everything is right, which is why echoing is tempting and wrong: it makes
	// `tex.width` a restatement of what the caller already said rather than a
	// report of what happened, so a dimension lost or transposed anywhere between
	// here and the device is invisible from JavaScript. Written as an echo first,
	// and a `.width`/`.height` swap injected into the `Image` above passed the
	// whole suite.
	*out = texture_value(&js, index, self.pass.assets.texture_at(index));
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
 — which makes `dispose()` safe to call the moment a script is done *referring*
 to a texture, rather than something to be timed against the materials that use
 it.

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
	self.pass.assets.release_texture(gpu, index);
}

<*
 `textureRead(index, into)` — copy a texture's pixels into a caller's
 `Uint8Array`.

 The destination is an argument, and that is the design. Building a plain `Array`
 costs one host crossing per element — 65,536 of them for a 128x128 texture.
 Handing out an `ArrayBuffer` over host memory means the host owns an allocation
 whose lifetime is decided by the script, and the only safe end to that is a
 detach the script has to be trusted to trigger.

 So the script supplies the memory and the host writes into it. `js.bytes` gives
 a mutable slice of the engine's own storage for the array — no copy, no
 ownership question, and the same function `dataTexture` already reads *from*. It
 also puts the allocation at the call site, where a caller reading a texture
 every frame can see what it costs.

 The bytes are the uploaded ones, not the sampled ones. The copy performs no
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
 where they get their Three.js names, defaults and range checks.

 The device is required and says so: a shape has to be uploaded to be drawn.
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

		// Clamped rather than trusted: the prelude has already refused anything out
		// of range with a better sentence, and this is what a script that called
		// `__three.primitive` itself gets instead of an allocation the size of the
		// device.
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
 `Vector3`s would be three property lookups and a released value per point, and
 `prelude.js` has to walk the caller's input anyway to validate it.

 Refused rather than clamped at both ends, unlike `primitive`'s segment counts:
 there is no nearest sensible cloud to substitute for a bad one, and a hull
 quietly built from the first 65536 of a script's points would be a shape nobody
 asked for.
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
			// one thing that can go wrong here that is about the caller's input, and
			// "CONVEX_HULL_IS_DEGENERATE" does not tell an agent staring at a
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
 One FNV-1a step over a single uint, split out because the ribbon key mixes a lot
 of them and the multiplier is easier to trust in one place.
*>
fn ulong ribbon_fnv(ulong hash, uint bits) @inline
{
	hash ^= (ulong)bits;
	hash *= 0x100000001b3u;
	return hash;
}

// Read one number out of a flat array argument, with the same finite backstop the
// other geometry reads use: `prelude.js` refuses a non-finite component with a
// sentence naming its index, and zero is what a forged call gets instead of
// spreading a NaN into sixty neighbouring vertices.
fn float ribbon_float(qjs::Context* js, qjs::Value array, uint idx)
{
	qjs::Value value = js.index(array, idx);
	double number = js.number(value);
	js.release(value);
	return math::is_finite(number) ? (float)number : 0.0f;
}

<*
 `ribbon(positions, normals, uvs, columns, rows)` — a strip geometry as an asset,
 built from a grid of vertices rather than from a parametric shape.

 Flat `positions`, `normals` and `uvs` arrays, row-major over `columns` x `rows`:
 one cross-section of `columns` vertices, one per row, in the order `row` walked
 down the path then `column` walked across the width. The host does the only
 thing it can know — emit the triangles between adjacent cells of the grid — and
 nothing about the shape of the curve, which is the prelude's domain.

 The index pattern is a grid like `Heightfield.build`'s, but wound the other way.
 A ribbon's across axis is 90 degrees counter-clockwise from its tangent (in the
 xz plane), so `across x along = +y`; the ground's axes run the other hand and
 its winding is mirrored. The triangles here are emitted so their front face
 points +y, matching the normals the prelude computed.

 Uploaded through `upload_built`, so it is an asset like any other — one draw
 call per unique ribbon, deduplicated by a hash of the vertices, filling the
 bounds and BVH through the same tail a built primitive uses. None of the data is
 retained on the slot: unlike a terrain, a ribbon answers no questions.
*>
fn void js_ribbon(
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

	long npos = argc > 0 ? js.length(args[0]) : -1;
	long nnorm = argc > 1 ? js.length(args[1]) : -1;
	long nuv = argc > 2 ? js.length(args[2]) : -1;
	if (npos < 3 || npos % 3 != 0)
	{
		*out = js.raise(
			"three.RibbonGeometry wants the vertex positions as a flat x, y, z array — its length must be a multiple of three"
		);
		return;
	}
	usz count = (usz)(npos / 3);
	if (nnorm != npos)
	{
		*out = js.raise("ribbon normals must be the same length as positions — one x, y, z per vertex");
		return;
	}
	if (nuv != (long)(count * 2))
	{
		*out = js.raise("ribbon uvs must be u, v per vertex — twice as many numbers as vertices");
		return;
	}
	int columns = (int)math::max(arg_int(&js, argc, args, 3), 0);
	int rows = (int)math::max(arg_int(&js, argc, args, 4), 0);
	if (columns < 2 || rows < 2)
	{
		*out = js.raise("a ribbon needs at least 2 columns across and 2 rows along");
		return;
	}
	if ((usz)columns * (usz)rows != count)
	{
		*out = js.raise(string::tformat(
			"columns x rows (%d x %d) must equal the number of vertices (%d)",
			columns, rows, count
		));
		return;
	}

	@pool()
	{
		GeometryBuilder geometry;
		geometry.init();
		defer geometry.free();

		ulong hash = 0xcbf29ce484222325u;
		for (usz i = 0; i < count; i++)
		{
			Vec3 position = { 0, 0, 0 };
			Vec3 normal = { 0, 1, 0 };
			for (usz axis = 0; axis < 3; axis++)
			{
				position[axis] = ribbon_float(&js, args[0], (uint)(i * 3 + axis));
				normal[axis] = ribbon_float(&js, args[1], (uint)(i * 3 + axis));
				hash = ribbon_fnv(hash, bitcast(position[axis], uint));
				hash = ribbon_fnv(hash, bitcast(normal[axis], uint));
			}
			float ux = ribbon_float(&js, args[2], (uint)(i * 2));
			float uy = ribbon_float(&js, args[2], (uint)(i * 2 + 1));
			hash = ribbon_fnv(hash, bitcast(ux, uint));
			hash = ribbon_fnv(hash, bitcast(uy, uint));
			geometry.vertex(position, normal, { ux, uy });
		}

		for (int r = 0; r + 1 < rows; r++)
		{
			for (int c = 0; c + 1 < columns; c++)
			{
				uint a = (uint)(r * columns + c);
				uint b = a + 1;
				uint cc = a + (uint)columns;
				uint d = cc + 1;
				geometry.triangle(a, b, cc);
				geometry.triangle(b, d, cc);
			}
		}

		if (geometry.indices.len() < 3 || geometry.positions.len() == 0)
		{
			*out = js.raise("the ribbon produced no triangles — check the path and the width");
			return;
		}

		String key = string::tformat("ribbon:%d:%d:%x", columns, rows, hash);
		if (try hit = self.pass.assets.built(key))
		{
			*out = asset_value(&js, hit);
			return;
		}

		AssetId? asset = self.pass.assets.upload_built(&self.renderer.gpu, key, "ribbon", &geometry);
		if (catch err = asset)
		{
			*out = js.raise(string::tformat("could not build a ribbon: %s", err));
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
 is the material `prelude.js` puts on it.

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
		// already refused anything out of range with a better sentence.
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
 `wireframe(index, generation, mesh)` — one mesh's triangles as the edges between
 them.

 The mesh has to be resident, and that is a sentence rather than an empty asset.
 The edges are read off `hull_positions`/`hull_triangles`, which are filled at
 upload, and a mesh reaches the device only when something drawing it is added to
 a scene. An empty wireframe would draw nothing and read as a helper that does
 not work.
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

 `js_load`'s other half, through the same door: the path is resolved by
 `resolve_asset`, so under `--assets` a script may write inside the game
 directory and nowhere else.

 No device is needed and none is used. `scene/export.c3` reads a mesh out of the
 file it came from or tessellates it again from its description, so an export is
 the one heavy verb here that works on a runtime with no GPU.

 The report is an object rather than a count because every number in it answers a
 different question about whether the file is the scene: `meshes` against
 `stats().uniqueMeshes`, `instances` against `stats().instances`, and `skipped`
 and `shaded` for the two things that deliberately did not survive the crossing.

 `batches` is how many of `nodes` were written as instanced nodes — the one
 number with no counterpart in `stats()`, saying how much of the scene the file
 managed to keep as repetition rather than as a thousand named copies.

 `layers` is `CUSTOM_materials_layers` records written, from a stack a file
 brought and from one a script built alike. It exists because `shaded` cannot
 answer for them: a layered material reaches the frame as a generated
 `ShaderMaterial` either way, so it is counted as a lost shader whether or not
 its stack survived.

 The second argument is `flatten`, which gives up the hierarchy to batch copies
 that are not siblings — the ones `asset.instantiate()` produces, each in a group
 of its own.
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
			if (err == qjs::MODULE_ESCAPES_ROOT)
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
		// this side stays a list of scalars, which keeps the two sides from
		// disagreeing about defaults.
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
		js.set_property(described, "layers", qjs::int_value((int)report.layers));
		js.set_property(described, "bytes", qjs::number_value((double)report.bytes));
		*out = described;
	};
}

<*
 `checkAsset(index, generation)` — raise if that handle no longer names an asset.

 `arg_asset`'s staleness check with nothing else attached to it, so that
 `new three.Mesh(ref)` can make it at the line naming the handle instead of
 leaving it to the `scene.add()` two lines later. It answers with nothing: the
 only thing a caller wants from it is the throw.

 The sentence is `arg_asset`'s own rather than a second one written beside it.
 One message means one place to keep it right, and an agent that hits it at the
 constructor reads exactly what it would have read at the add — including the
 recovery, which is the half that matters.
*>
fn void js_check_asset(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	// The handle itself is discarded: the pending throw is the whole answer.
	if (!arg_asset(self, &js, argc, args, 0, out).is_set()) return;
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
 the first, which is what `Assets.find_mesh` does.
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

 This costs nothing and is available before the mesh is on the device. A
 `GpuMesh` exists from the moment the JSON is parsed, and `bounds` is one of the
 three fields filled in then rather than at upload — it is the POSITION
 accessor's required `min`/`max`. So asking how big a kit piece is does not
 upload the kit.

 Per mesh index, not per name: a glTF mesh with several primitives produced
 several entries sharing a name, and a `Mesh` node draws exactly one of them.
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
 `meshMaterial(index, generation, mesh)` — what the primitive's glTF material
 said, beyond the base colour that is already on the mesh.

 `scene/asset.c3`'s `GpuMaterial` has what is in it. What crosses is one flat
 array, `js_mesh_layers`'s shape and for its reason — the QuickJS shim has no
 property enumeration, so a positional row is cheaper on both sides.

	 0  alphaMode ordinal      4  emissiveFactor r     8  metallic
	 1  alphaCutoff           5  emissiveFactor g     9  roughness
	 2  doubleSided           6  emissiveFactor b    10  normal texture
	 3  emissiveStrength      7  occlusion texture   11  metallicRoughness texture
	                                                 12  emissive texture

 Reading this uploads the mesh, and every read holds new references, exactly as
 `meshLayers` does: the images exist only once the primitive is on the device,
 and each texture handed back is a handle of its own.

 `null` for a primitive that names no material, which is a real glTF and means
 the default one.
*>
fn void js_mesh_material(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	uint index = (uint)arg_int(&js, argc, args, 2);
	self.pass.assets.ensure_uploaded(id, index);

	GpuMesh* mesh = self.pass.assets.mesh(id, index);
	if (mesh == null || !mesh.material.present)
	{
		*out = qjs::null_value();
		return;
	}

	GpuMaterial* material = &mesh.material;
	qjs::Value row = js.array();
	js.set_index(row, 0, qjs::int_value((int)material.alpha_mode));
	js.set_index(row, 1, qjs::number_value(material.alpha_cutoff));
	js.set_index(row, 2, qjs::bool_value(material.double_sided));
	js.set_index(row, 3, qjs::number_value(material.emissive_strength));
	js.set_index(row, 4, qjs::number_value(material.emissive_factor[0]));
	js.set_index(row, 5, qjs::number_value(material.emissive_factor[1]));
	js.set_index(row, 6, qjs::number_value(material.emissive_factor[2]));
	js.set_index(row, 7, layer_texture_value(&js, &self.pass.assets, material.occlusion_texture));
	js.set_index(row, 8, qjs::number_value(material.metallic));
	js.set_index(row, 9, qjs::number_value(material.roughness));
	js.set_index(row, 10, layer_texture_value(&js, &self.pass.assets, material.normal_texture));
	js.set_index(row, 11, layer_texture_value(&js, &self.pass.assets, material.metallic_roughness_texture));
	js.set_index(row, 12, layer_texture_value(&js, &self.pass.assets, material.emissive_texture));
	*out = row;
}

<*
 `splitMesh(index, generation, mesh)` — one mesh, cut into its connected
 components, as an array of `[index, generation]` asset handles.

 `scene/split.c3` has the algorithm and what a piece does and does not inherit.
 What is here is the boundary: the three refusals it can produce become three
 sentences an agent can act on, because "MESH_HAS_LAYERS" says nothing about what
 to do next.

 A mesh that is already one piece answers with an array of one holding *this*
 mesh's own handle — nothing is uploaded. That is not an error and is deliberately
 not reported as one: "this kit was already cut" is something a script finds out
 by looking at the length.
*>
fn void js_split_mesh(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	if (self.renderer == null)
	{
		*out = js.raise("splitting a mesh uploads its pieces, and this context has no GPU device");
		return;
	}

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	uint index = (uint)arg_int(&js, argc, args, 2);

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
					*out = js.raise(
						"that mesh carries a layer stack, and a piece cut out of it cannot inherit one — "
						"read the stack with ref.layers, build a LayeredMaterial from it, and put that on "
						"the pieces yourself"
					);
				case MESH_CANNOT_BE_SPLIT:
					*out = js.raise(
						"there are no triangles to cut there — that mesh index does not exist, or it is a "
						"line mesh, whose indices are pairs"
					);
				case TOO_MANY_SPLIT_PIECES:
					*out = js.raise(string::tformat(
						"that mesh comes apart into more than %d pieces, which is not a kit — it is "
						"geometry whose triangles do not touch each other",
						MAX_SPLIT_PIECES
					));
				default:
					*out = js.raise(string::tformat("that mesh could not be split: %s", err));
			}
			return;
		}

		// `[index, generation, mesh]` rather than `asset_value`'s pair: a piece
		// carries which mesh of its asset it is, because the one-component answer is
		// the source's own handle and that mesh need not be zero.
		qjs::Value list = js.array();
		foreach (i, piece : pieces)
		{
			qjs::Value triple = js.array();
			js.set_index(triple, 0, qjs::int_value((int)piece.asset.index));
			js.set_index(triple, 1, qjs::int_value((int)piece.asset.generation));
			js.set_index(triple, 2, qjs::int_value((int)piece.mesh));
			js.set_index(list, (uint)i, triple);
		}
		*out = list;
	};
}

<*
 `meshLayers(index, generation, mesh)` — one mesh's `CUSTOM_materials_layers`
 stack, or `null` when its material never carried the extension.

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

 The blend mode and the mask channel cross as the extension's own ordinals and
 are named on the far side, which keeps `gltf.c3l`'s enum the single authority
 for what the ordinals mean.

 @return `[maskTexture, [layer...]] where each layer is [name, enabled, blendMode, maskSource, maskChannel, invert, opacity, r, g, b, a, er, eg, eb, map, normal, emissive, maskTexture], or null.`
*>
fn void js_mesh_layers(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	uint index = (uint)arg_int(&js, argc, args, 2);
	self.pass.assets.ensure_uploaded(id, index);

	GpuMesh* mesh = self.pass.assets.mesh(id, index);
	if (mesh == null || !mesh.layers.present)
	{
		*out = qjs::null_value();
		return;
	}

	qjs::Value layers = js.array();
	foreach (i, &layer : mesh.layers.layers)
	{
		qjs::Value row = js.array();
		js.set_index(row, 0, js.string(layer.name));
		js.set_index(row, 1, qjs::bool_value(layer.enabled));
		js.set_index(row, 2, qjs::int_value((int)layer.blend_mode));
		js.set_index(row, 3, qjs::int_value((int)layer.mask_source));
		js.set_index(row, 4, qjs::int_value((int)layer.mask_channel));
		js.set_index(row, 5, qjs::bool_value(layer.invert));
		js.set_index(row, 6, qjs::number_value(layer.opacity));
		js.set_index(row, 7, qjs::number_value(layer.base_color[0]));
		js.set_index(row, 8, qjs::number_value(layer.base_color[1]));
		js.set_index(row, 9, qjs::number_value(layer.base_color[2]));
		js.set_index(row, 10, qjs::number_value(layer.base_color[3]));
		js.set_index(row, 11, qjs::number_value(layer.emissive_factor[0]));
		js.set_index(row, 12, qjs::number_value(layer.emissive_factor[1]));
		js.set_index(row, 13, qjs::number_value(layer.emissive_factor[2]));
		js.set_index(row, 14, layer_texture_value(&js, &self.pass.assets, layer.texture));
		js.set_index(row, 15, layer_texture_value(&js, &self.pass.assets, layer.normal_texture));
		js.set_index(row, 16, layer_texture_value(&js, &self.pass.assets, layer.emissive_texture));
		js.set_index(row, 17, layer_texture_value(&js, &self.pass.assets, layer.mask_texture));
		js.set_index(layers, (uint)i, row);
	}

	qjs::Value stack = js.array();
	js.set_index(stack, 0, layer_texture_value(&js, &self.pass.assets, mesh.layers.mask_texture));
	js.set_index(stack, 1, layers);
	*out = stack;
}

<*
 One of a layer's texture slots, as `[index, width, height, levels, colourspace]`
 — or `null` for a slot the layer does not use.

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
*>
fn qjs::Value layer_texture_value(qjs::Context* js, Assets* assets, int index) @local
{
	if (index < 0) return qjs::null_value();
	Texture* uploaded = assets.texture_at(index);
	if (uploaded == null) return qjs::null_value();
	assets.retain_texture(index);
	qjs::Value fields = texture_value(js, index, uploaded);
	js.set_index(fields, 4, qjs::int_value(uploaded.space == ColorSpace.LINEAR ? 1 : 0));
	return fields;
}

<*
 `assetNodes(index, generation)` — the asset's node tree, flattened into the
 objects `asset.instantiate()` builds.

 One entry per node that should exist, each naming its parent by position in the
 same array. Parents always come before their children, so `instantiate()` can
 walk it once and never look forward.

 The tree is not built here and its shape is not decided here. `Assets.flatten`
 decides — the same walk `Scene.instantiate` uses on the host — so a file placed
 by the CLI and a file placed by a script produce the same hierarchy. What
 crosses the boundary is a description, and JavaScript builds ordinary
 `Object3D`s from it that materialize through the normal `add` path. That is
 deliberate: an object handed back from here is one a script can move, hide,
 recolour and re-parent before it ever reaches a scene.

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

 @return `An array of [name, parent, mesh, px, py, pz, ex, ey, ez, sx, sy, sz, qx, qy, qz, qw, gltfNode, r, g, b, a, skin].`
*>
fn void js_asset_nodes(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	AssetId id = arg_asset(self, &js, argc, args, 0, out);
	if (!id.is_set()) return;

	// Whether the file's bone nodes become objects. False by default, which drops
	// a character's skeleton — its pose comes out of the baked table and the nodes
	// would drive nothing. See `Assets.flatten`.
	bool skeleton = argc > 2 ? arg_truth(&js, argc, args, 2) : false;

	List{PlacedNode} placed;
	placed.init(mem, 16);
	defer placed.free();
	self.pass.assets.flatten(id, &placed, skeleton);

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
		// The per-copy tint, which is white for everything but a copy an instanced
		// node placed. Four numbers rather than an object because the row is already
		// a flat array and `mesh.color` is already a flat array.
		js.set_index(row, 17, qjs::number_value(entry.color[0]));
		js.set_index(row, 18, qjs::number_value(entry.color[1]));
		js.set_index(row, 19, qjs::number_value(entry.color[2]));
		js.set_index(row, 20, qjs::number_value(entry.color[3]));
		// Which skin poses this node, or -1. The JS tree carries it to
		// `_materialize`, which is where a host node learns it — the JavaScript path
		// builds its nodes through the ordinary `add`, not through
		// `Scene.instantiate`, so nothing else would ever set it.
		js.set_index(row, 21, qjs::int_value(entry.skin));

		js.set_index(nodes, (uint)i, row);
	}
	*out = nodes;
}

<*
 `assetClips(index, generation)` — the names of a file's animations.

 Free: names and durations are read at load out of the JSON chunk, so this
 answers on a file that has uploaded nothing. `mesh.animations` is what a script
 sees, and it is a plain array of strings rather than clip objects because a name
 is the only handle `play` takes.
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

 `scene/inventory.c3` carries the argument. In short: without it, finding out
 what a file held means uploading it, so "what have I got" — the question an
 agent asks first — is the most expensive one it can ask.

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
	if (self.modules.root.len == 0)
	{
		*out = listed;
		return;
	}

	Inventory? found = take_inventory(self.modules.root);
	if (catch err = found)
	{
		js.release(listed);
		*out = js.raise(string::tformat("could not read %s: %s", self.modules.root, err));
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

		// Omitted rather than zeroed when the file had no position accessor to read
		// them from: a box at the origin and "we could not tell" are different
		// answers, and only one of them is safe to place a camera by.
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

<*
 `terrain(width, depth, segments, skirt, heights)` — a heightfield, as an asset.

 `heights` is a flat array of `(segments + 1)^2` numbers, row-major in z then x,
 for `js_convex`'s reason: it is the one shape the crossing can read in a single
 pass, and the prelude has to walk the caller's input to validate it anyway. A
 callback is resolved on the JS side into exactly this array, which is why there
 is no callback here.

 The length is checked against the segment count in `Assets.terrain` and refused
 rather than padded: a height array off by a row is a surface that reads at the
 wrong stride, which produces a plausible-looking diagonal ripple and nothing
 that says why.
*>
fn void js_terrain(
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

	float width = arg_float(&js, argc, args, 0);
	float depth = arg_float(&js, argc, args, 1);
	long segments = arg_int(&js, argc, args, 2);
	float skirt = arg_float(&js, argc, args, 3);

	if (segments < (long)MIN_TERRAIN_SEGMENTS || segments > (long)MAX_TERRAIN_SEGMENTS)
	{
		*out = js.raise(string::tformat(
			"a terrain has between %d and %d segments a side, got %d",
			MIN_TERRAIN_SEGMENTS, MAX_TERRAIN_SEGMENTS, segments
		));
		return;
	}

	long wanted = (segments + 1) * (segments + 1);
	long length = argc > 4 ? js.length(args[4]) : -1;
	if (length != wanted)
	{
		*out = js.raise(string::tformat(
			"a %d-segment terrain wants %d heights, got %d — the array is (segments + 1) squared, row-major in z",
			segments, wanted, length
		));
		return;
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
		for (long i = 0; i < wanted; i++)
		{
			qjs::Value sample = js.index(args[4], (uint)i);
			double value = js.number(sample);
			js.release(sample);
			// The prelude refuses a non-finite height with a sentence naming its
			// index. Zero is the backstop for a forged call: a NaN here would spread
			// through the normals into every neighbouring vertex and put a black
			// hole in the middle of the ground.
			field.heights.push(math::is_finite(value) ? (float)value : 0.0f);
		}

		AssetId? asset = self.pass.assets.terrain(&self.renderer.gpu, &field);
		if (catch err = asset)
		{
			*out = js.raise(string::tformat("could not build a terrain: %s", err));
			return;
		}
		*out = asset_value(&js, asset);
	};
}

<*
 `terrainAt(asset, generation, x, z)` — the ground and its normal at a point.

 Both in one crossing and one array, because every caller wants both: something
 placed on a hillside needs the height to sit at and the normal to lean with, and
 two calls would sample the grid twice to answer one question.

 `[y, nx, ny, nz]`, or an empty array when the handle does not name a live
 terrain — which the prelude turns into a sentence. Not a throw here, because the
 same call answers "is this a terrain at all" and a fault would make the ordinary
 negative answer expensive.
*>
fn void js_terrain_at(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	AssetId id = {
		.index = (uint)arg_int(&js, argc, args, 0),
		.generation = (uint)arg_int(&js, argc, args, 1),
	};
	Heightfield* field = self.pass.assets.terrain_field(id);

	qjs::Value list = js.array();
	if (field == null)
	{
		*out = list;
		return;
	}

	float x = arg_float(&js, argc, args, 2);
	float z = arg_float(&js, argc, args, 3);
	Vec3 normal = field.normal_at(x, z);
	js.set_index(list, 0, qjs::number_value((double)field.height_at(x, z)));
	js.set_index(list, 1, qjs::number_value((double)normal.x));
	js.set_index(list, 2, qjs::number_value((double)normal.y));
	js.set_index(list, 3, qjs::number_value((double)normal.z));
	*out = list;
}
