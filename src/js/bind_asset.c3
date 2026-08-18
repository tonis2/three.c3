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
