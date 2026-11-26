<*
 glTF `extras` — Blender's custom properties — from a file to `object.extras` and
 `asset.extras`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::extras`

 The file is built here with gltf.c3l's writer, the shape a region export takes: a
 tile instanced three times, with a box collider and `ground` / `walk` tags; a
 marker node carrying `piece`, `kind`, `footprint` and `interior`; a plain node with
 no extras; and the file's own extras. It is written under `build/` and deleted
 after, as `export_test` does with its files.
*>
module three_tests::extras;

import three;
import three_tests::device;
import gltf;
import std::core::test;
import std::io::file;
import std::math::vector;

const String REGION = "build/extras_region.glb";

macro @with_gpu_js(; @body(three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(200, 150);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

// The tile's tags, which every copy and every proxy of it carries.
const String TILE_EXTRAS = `{"ground":true,"walk":true,"water":false,"cost":1.5}`;

<*
 A unit box `tile`, drawn by an instanced node at x = 0, 2 and 4 with a 1 m box
 collider, and by a `plain` node at z = 6; a `marker` group at z = 3.
*>
fn void write_region(String path)
{
	gltf::GltfBuilder out = gltf::builder();
	defer out.free();

	Vec3[8] corners = {
		{ -0.5, -0.5, -0.5 }, { 0.5, -0.5, -0.5 }, { 0.5, 0.5, -0.5 }, { -0.5, 0.5, -0.5 },
		{ -0.5, -0.5, 0.5 }, { 0.5, -0.5, 0.5 }, { 0.5, 0.5, 0.5 }, { -0.5, 0.5, 0.5 },
	};
	uint[36] faces = {
		0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
		3, 6, 2, 3, 7, 6, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
	};
	uint mesh = out.add_mesh("tile");
	gltf::WriteAttribute[1] position = { { .name = "POSITION", .accessor = out.add_positions(corners[..]) } };
	out.add_primitive(mesh, position[..], (int)out.add_indices(faces[..]));

	uint tiles = out.add_node("tiles", mesh: (int)mesh);
	Vec3[3] spots = { { 0, 0, 0 }, { 2, 0, 0 }, { 4, 0, 0 } };
	gltf::WriteAttribute[1] placed = { { .name = "TRANSLATION", .accessor = out.add_vec3(spots[..]) } };
	out.add_instancing(tiles, placed[..]);
	uint box = out.add_shape({ .type = BOX, .size = { 1, 1, 1 } });
	out.add_collider(tiles, {
		.shape = (int)box,
		.node = -1,
		.material = -1,
		.collision_filter = -1,
		.mesh = -1,
		.base_node = -1,
	});
	out.set_node_extras(tiles, TILE_EXTRAS);

	uint marker = out.add_node("marker", translation: { 0, 0, 3 });
	out.set_node_extras(marker,
		`{"piece":"wall_stone","kind":"door","footprint":[2,1],"interior":{"floor":1,"lit":true,"name":"cellar – café"}}`);

	uint plain = out.add_node("plain", mesh: (int)mesh, translation: { 0, 0, 6 });

	uint region = out.add_node("region");
	out.add_child(region, tiles);
	out.add_child(region, marker);
	out.add_child(region, plain);
	out.add_root(region);

	out.set_extra("region", "lumbridge");
	out.set_extra_json("version", "3");
	out.set_extra_json("grid", "[16,16]");
	out.save_glb(path)!!;
}

<*
 Every object `instantiate` builds carries its glTF node's extras as a plain
 object — the instanced copies and their collider proxies included, which are
 entries the walk made up and which a tile grid is built from.

 Each object has its own: writing one copy's tags leaves the next copy's alone.
 A node with no extras has `{}`, so `o.extras.walk` never throws on a traverse.
*>
fn void every_object_carries_its_nodes_extras() @test
{
	write_region(REGION);
	defer (void)file::delete(REGION);

	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const asset = three.load('build/extras_region.glb');
			const root = asset.instantiate('region', { physics: true });
			new three.Scene().add(root);

			const copies = [], proxies = [];
			let tiles = null, marker = null, plain = null, region = null;
			root.traverse((o) => {
				if (o.collisionOnly) proxies.push(o);
				else if (o.name === 'tile') copies.push(o);
				else if (o.name === 'tiles') tiles = o;
				else if (o.name === 'marker') marker = o;
				else if (o.name === 'plain') plain = o;
				else if (o.name === 'region') region = o;
			});

			const tagged = (o) => o.extras.ground === true && o.extras.walk === true
				&& o.extras.water === false && o.extras.cost === 1.5;
			const allTagged = [tiles, ...copies, ...proxies].every(tagged);

			copies[0].extras.walk = false;
			const own = copies[1].extras.walk === true && proxies[0].extras.walk === true;

			const m = marker.extras;
			return {
				copies: copies.length,
				proxies: proxies.length,
				allTagged,
				own,
				marker: [m.piece, m.kind, Array.isArray(m.footprint) && m.footprint.join('x'),
					m.interior.floor, m.interior.lit, m.interior.name],
				plain: JSON.stringify(plain.extras),
				region: JSON.stringify(region.extras),
				root: JSON.stringify(root.extras),
			};
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value.contains(`"copies":3,"proxies":3`),
			"three copies, one proxy each: %s", result.value);
		test::@check(result.value.contains(`"allTagged":true`),
			"the node, its copies and their proxies all carry the tile's tags: %s", result.value);
		test::@check(result.value.contains(`"own":true`),
			"each object has its own extras: %s", result.value);
		test::@check(result.value.contains(`"marker":["wall_stone","door","2x1",1,true,"cellar – café"]`),
			"strings, an array and a nested object come through as themselves: %s", result.value);
		test::@check(result.value.contains(`"plain":"{}","region":"{}","root":"{}"`),
			"a node with none, and the tree's own group, have an empty object: %s", result.value);
	};
}

<*
 The other doors onto the file carry the same extras: `node(name)`, `nodeAsync`
 and `instantiateAsync` build through the same rows. `asset.extras` is the file's
 own, and is read once.
*>
fn void the_file_and_every_door_carry_extras() @test
{
	write_region(REGION);
	defer (void)file::delete(REGION);

	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const asset = three.load('build/extras_region.glb');
			const x = asset.extras;
			const piece = asset.node('marker').extras.piece;
			const piece2 = (await asset.nodeAsync('marker')).extras.piece;

			const tiles = await asset.nodeAsync('tiles', { physics: true });
			let walkable = 0;
			tiles.traverse((o) => { if (o.extras.walk) walkable++; });

			const whole = await asset.instantiateAsync('region');
			let cost = 0;
			whole.traverse((o) => { if (o.name === 'tile') cost += o.extras.cost; });

			return [x.region, x.version, x.grid.join('x'), asset.extras === x, piece, piece2, walkable, cost];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		// Seven under `tiles`: the node, three copies and their three proxies.
		test::@check(result.value == `["lumbridge",3,"16x16",true,"wall_stone","wall_stone",7,4.5]`,
			"the file's extras, and a node's through every door; got %s", result.value);
	};
}

<*
 A file with no extras answers `{}` for itself and for its nodes.
*>
fn void a_file_without_extras_answers_empty_objects() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const asset = three.load('test/fixtures/hierarchy.glb');
			let empty = true;
			asset.instantiate().traverse((o) => { if (Object.keys(o.extras).length) empty = false; });
			return [JSON.stringify(asset.extras), empty];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		test::@check(result.value == `["{}",true]`, "nothing anywhere; got %s", result.value);
	};
}

<*
 The tile-grid question: what collider does a probe at a tile's centre stand in,
 and what are its tags.

 The probe is wholly inside the tile's 1 m box collider — 0.2 m below its top
 face with a 0.1 m radius — so no surface is in reach, and `three.query.sweep` from the
 point to itself says nothing is there. `three.query.overlap` finds the proxy it
 is inside, which carries the tile's extras. Between two tiles it finds nothing.
*>
fn void an_overlap_finds_the_collider_a_tile_is_inside() @test
{
	write_region(REGION);
	defer (void)file::delete(REGION);

	@with_gpu_js(; three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			const asset = three.load('build/extras_region.glb');
			new three.Scene().add(asset.instantiate('region', { physics: true }));

			const probe = { radius: 0.1, height: 0.2 };
			const inside = three.query.overlap([2, 0.3, 0], probe);
			const swept = three.query.sweep([2, 0.3, 0], [2, 0.3, 0], probe);
			const between = three.query.overlap([1, 0, 0], probe);
			return [
				inside?.name, inside?.object?.extras.ground, inside?.object?.collisionOnly,
				+inside.point.y.toFixed(3), +inside.normal.y.toFixed(3), inside.distance,
				swept, between,
			];
		`);
		defer result.free();

		test::@check(result.ok, "the script succeeded: %s", result.error);
		// The way out is through the top face, the nearest at 0.2 m.
		test::@check(result.value == `["tiles.collider",true,true,0.5,1,0,null,null]`,
			"the probe is inside the tile's proxy, which a sweep cannot see; got %s", result.value);
	};
}
