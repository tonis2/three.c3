<*
 `three.load()`, `three.BoxGeometry()` and what an asset can be asked about.

 Four verbs, and the smallest set that lets `prelude.js` build an `Asset` whose
 `mesh(name)` lookup happens in JavaScript: the load itself, the path back, the
 mesh names in order, and one shape builder for all five parametric kinds.
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

		uint? asset = self.pass.assets.load(&self.renderer.gpu, path);
		if (catch err = asset)
		{
			// The fault name verbatim: ASSET_HAS_NO_MESHES and the io faults are
			// each a different thing to do about it, and flattening them into
			// "could not load" would cost the agent the one word that says which.
			*out = js.raise(string::tformat("could not load %s: %s", path, err));
			return;
		}

		*out = qjs::int_value((int)asset);
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

		uint? asset = self.pass.assets.primitive(&self.renderer.gpu, shape);
		if (catch err = asset)
		{
			*out = js.raise(string::tformat("could not build a %s: %s", name, err));
			return;
		}

		*out = qjs::int_value((int)asset);
	};
}

fn void js_asset_path(
	qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out
)
{
	JsRuntime* self = (JsRuntime*)opaque;
	qjs::Context js = qjs::wrap(ctx);

	int index = arg_int(&js, argc, args, 0);
	if (index < 0 || index >= self.pass.assets.assets.len())
	{
		*out = js.raise(string::tformat("there is no asset %d", index));
		return;
	}
	*out = js.string(self.pass.assets.assets[index].path);
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

	int index = arg_int(&js, argc, args, 0);
	if (index < 0 || index >= self.pass.assets.assets.len())
	{
		*out = js.raise(string::tformat("there is no asset %d", index));
		return;
	}

	qjs::Value names = js.array();
	foreach (i, &mesh : self.pass.assets.assets[index].meshes)
	{
		js.set_index(names, (uint)i, js.string(mesh.name));
	}
	*out = names;
}
