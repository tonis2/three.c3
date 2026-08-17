module three_tests::bench;

import std::io;
import std::time;
import std::collections::list;
import std::math::vector;
import gltf;
import collision;
import three;

const String SCRATCH = "/private/tmp/claude-501/-Users-tonis-Documents-c3-three-c3/cd13b985-cc3a-47cb-99f7-a2ee690c4f7f/scratchpad";

fn void say(File* out, String line)
{
	out.write(line)!!;
	out.write("\n")!!;
	out.flush()!!;
}

fn void dump_primitives() @test
{
	File out = file::open(string::tformat("%s/dump.txt", SCRATCH), "w")!!;
	defer (void)out.close();

	gltf::GltfStream stream = gltf::open("lib/gltf.c3l/test/truck.glb")!!;
	defer stream.close();
	stream.load_all_buffers()!!;

	int n = 0;
	foreach (mesh : stream.gltf.meshes)
	{
		foreach (primitive : mesh.primitives)
		{
			List{Vec3} p;
			p.init(mem, 256);
			defer p.free();
			stream.@each_position(primitive; Vec3 position, sz i) { p.push(position); };
			if (p.len() == 0) continue;
			n++;
			say(&out, string::tformat("primitive %d: %d verts", n, p.len()));
			File pf = file::open(string::tformat("%s/prim%d.txt", SCRATCH, n), "w")!!;
			defer (void)pf.close();
			foreach (v : p)
			{
				pf.write(string::tformat("%.9g %.9g %.9g\n", v.x, v.y, v.z))!!;
			}
			pf.flush()!!;
		}
	}
	say(&out, "dump done");
}
