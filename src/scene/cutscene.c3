<*
 A cutscene file's one-off clips, put on the actor that plays them.

 `CUSTOM_cutscene` (the Blender add-on's `extensions/cutscene.md`) keeps the
 acting that exists for one cutscene alone as ordinary glTF animations on stub
 nodes: one per actor, named after its object, with a child per animated bone
 named after the bone. Playing one is binding those names to the actor's own
 nodes and adding the result to the actor's asset as a clip of its own, after
 which `play` finds it by name like any other. The cutscene takes it off again
 when it is disposed.

 The timeline itself is JSON and `prelude/cutscene.js` reads it.
*>
module three;

import std::collections::list;
import gltf;

excuse STUB_NOT_FOUND, STUB_OUTSIDE_ACTOR;

// Deeper than any rig; a deeper stub tree is a loop in a malformed file.
const uint STUB_DEPTH = 64;

<*
 Which node of the actor's asset a stub node of the cutscene file stands for.

 The actor's own stub is `anchor`, the node the live object came from. For a
 whole file instantiated as a group (`anchor` negative) it is the node named like
 the stub. A bone stub is the first node of its name under that one, or anywhere
 in the file when there is no such node.

 @param [&in] actor : "The asset of the object playing the clip"
 @param [&in] file : "The cutscene file"
 @return "An index into the actor asset's nodes"
 @return? STUB_NOT_FOUND, STUB_OUTSIDE_ACTOR
*>
fn uint? bind_stub(Asset* actor, gltf::Gltf* file, uint stub_root, int anchor, uint node)
{
	if (node >= file.nodes.len() || stub_root >= file.nodes.len()) return STUB_OUTSIDE_ACTOR~;
	int root = anchor >= 0 && anchor < actor.nodes.len() ? anchor : actor.node_named(file.nodes[stub_root].name);
	if (node == stub_root)
	{
		if (root < 0) return STUB_NOT_FOUND~;
		return (uint)root;
	}
	if (!stub_below(file, stub_root, node, 0)) return STUB_OUTSIDE_ACTOR~;
	int found = actor.node_named(file.nodes[node].name, root);
	if (found < 0) return STUB_NOT_FOUND~;
	return (uint)found;
}

// Whether `node` hangs somewhere under `from` in the cutscene file.
fn bool stub_below(gltf::Gltf* file, uint from, uint node, uint depth) @local
{
	if (depth > STUB_DEPTH) return false;
	foreach (child : file.nodes[from].children)
	{
		if (child == node) return true;
		if (child < file.nodes.len() && stub_below(file, child, node, depth + 1)) return true;
	}
	return false;
}

<*
 Animation `index` of an open cutscene file as a clip for `actor`, each channel
 moved from its stub onto the actor's node of the same name.

 Unnamed: the caller names it, because the name it plays under has to be free on
 the actor's asset.

 @param [&inout] file : "The cutscene file, open"
 @param [&in] actor : "The asset of the object playing it"
 @param [&out] unbound : "On a failure to bind, the stub node it was about"
 @require index < file.gltf.animations.len() : "No such animation"
 @return? STUB_NOT_FOUND, STUB_OUTSIDE_ACTOR
*>
fn AnimationClip? read_one_off(gltf::GltfStream* file, uint index, Asset* actor, uint stub_root, int anchor, uint* unbound)
{
	file.load_animation_buffers(index)!;

	gltf::Animation source = file.gltf.animations[index];
	AnimationClip clip = { .start = source.min_time, .duration = source.duration(), .source = index };
	clip.channels.init(mem, 4);
	defer catch clip.free();

	read_channels(file, index, &clip.channels);
	foreach (&channel : clip.channels)
	{
		*unbound = channel.node;
		channel.node = bind_stub(actor, &file.gltf, stub_root, anchor, channel.node)!;
	}
	return clip;
}

<*
 A name for a clip on `owner` that no clip there has yet: `wanted`, or `wanted#2`
 and on. A one-off must never shadow the character's own clip of the same name.

 @return "Heap-allocated, for the clip to own"
*>
fn String free_clip_name(Asset* owner, String wanted)
{
	if (owner.find_clip(wanted) < 0) return wanted.copy(mem);
	for (int n = 2; ; n++)
	{
		String candidate = string::tformat("%s#%d", wanted, n);
		if (owner.find_clip(candidate) < 0) return candidate.copy(mem);
	}
}
