<*
 Morph targets: per-copy blend shapes, and the weights that drive them.

 A morph target is a *displacement* of every vertex, and a mesh may carry several.
 The vertex a shader draws is the base position plus every target's displacement
 scaled by that target's weight — so a face with a `smile` target and a `blink`
 target can do both at once, which is the property absolute positions do not have
 and the reason glTF stores deltas.

 ## Where the three pieces live

 - **The displacements are on the asset**, uploaded once with the rest of the
   geometry — `GpuMesh.morph`. They are immutable data a hundred copies of a head
   share, exactly like the baked pose table.
 - **The weights are per copy**, because two characters built from one head mesh
   have to be able to wear different expressions. They sit in `Scene.morphs`, a
   side table rather than a field on `Node`: almost no node has any, and a `List`
   per node would be a pointer, a length and a capacity per crate in the level.
 - **The frame's weights are one buffer**, written by
   `MeshPass.write_morph_weights` and pointed at by `FrameBlock.morph_weights`.
   An instance names its slice with one `uint`, the way it names its pose with
   one, and for the same reason: a morphing copy and a still one stay in one
   `vkCmdDrawIndexed`.

 ## What this deliberately does not do

 **No morph normals beyond the file's own.** A target that carries a NORMAL
 accessor moves normals; one that does not leaves them where the base mesh put
 them, and nothing here recomputes them. Recomputing would mean a pass over the
 triangles per copy per frame — the cost of the whole feature again — to fix
 lighting on a deformation the artist chose not to author normals for.

 **No target names.** glTF puts them in `mesh.extras.targetNames`, which is an
 extras convention rather than a required field, so weights are addressed by
 index. `mesh.morphs` is how many there are.
*>
module three;

import std::collections::list;
import std::math;

<*
 One node's morph weights.

 `weights` is as long as the mesh has targets, seeded to zero, and stays that
 length: a script setting fewer leaves the rest where they were, and one setting
 more is refused rather than growing a list the shader will not read.
*>
struct MorphWeights
{
	NodeId node;
	List{float} weights; // owned
}

<*
 How many morph targets the mesh this node draws carries, or zero.

 The question a script asks before setting a weight, and the one that decides
 whether there is anything to set. Answered off the mesh rather than off the
 weights, so it is the same number before and after anything has been set.
*>
fn uint Scene.morph_target_count(&self, NodeId id)
{
	Node* node = self.node(id);
	if (node == null || self.assets == null) return 0;

	Asset* owner = self.assets.slot(node.asset);
	if (owner == null || node.mesh >= owner.meshes.len()) return 0;
	return owner.meshes[node.mesh].morph_targets;
}

<*
 This node's morph weights, or an empty view.

 A view into the table and not a copy, so a caller may read it every frame. It
 goes stale the moment the table grows, which is why nothing keeps one.
*>
fn float[] Scene.morph_weights(&self, NodeId id)
{
	foreach (&entry : self.morphs)
	{
		if (entry.node == id) return entry.weights.array_view();
	}
	return {};
}

<*
 Sets this node's morph weights.

 Longer than the mesh has targets is truncated and shorter leaves the rest where
 they were, which makes `set(0, 1)` on a twenty-target face one call rather than
 twenty numbers a script has to carry.

 **All zero removes the entry**, and that is not just tidiness: an instance with
 no entry carries `morph == 0`, which is the shader's test for skipping the loop
 entirely — so a face that has finished its expression stops costing anything at
 all rather than costing a loop over twenty multiplications by zero.

 @return `False when the node is gone or its mesh has no targets, which is a question rather than an error.`
*>
fn bool Scene.set_morph_weights(&self, NodeId id, float[] values)
{
	uint targets = self.morph_target_count(id);
	if (targets == 0) return false;

	MorphWeights* entry = null;
	foreach (&candidate : self.morphs)
	{
		if (candidate.node == id) { entry = candidate; break; }
	}

	if (entry == null)
	{
		MorphWeights fresh = { .node = id };
		fresh.weights.init(mem, targets);
		for (uint i = 0; i < targets; i++) fresh.weights.push(0);
		self.morphs.push(fresh);
		entry = &self.morphs[self.morphs.len() - 1];
	}

	foreach (i, value : values)
	{
		if (i >= entry.weights.len()) break;
		entry.weights[i] = value;
	}

	bool driven = false;
	foreach (weight : entry.weights)
	{
		if (weight != 0) { driven = true; break; }
	}
	if (!driven) self.clear_morph_weights(id);
	return true;
}

<*
 Takes a node out of the weight table, and off the morph path with it.

 @return `Whether it was on it.`
*>
fn bool Scene.clear_morph_weights(&self, NodeId id)
{
	foreach (i, &entry : self.morphs)
	{
		if (entry.node != id) continue;
		entry.weights.free();
		self.morphs.remove_at(i);

		// The offset an instance would otherwise go on carrying into a buffer that
		// no longer has a slice for it.
		Node* node = self.node(id);
		if (node != null) node.morph = 0;
		return true;
	}
	return false;
}

<*
 Every entry whose node is gone, dropped.

 Called from `write_morph_weights` for `update_sockets`' reason: a node's death is
 one of several paths, and sweeping a short list at the one place that walks it
 anyway is cheaper than a hook on the frequent one.
*>
fn void Scene.sweep_morphs(&self)
{
	for (sz i = self.morphs.len(); i > 0; i--)
	{
		if (self.node(self.morphs[i - 1].node) != null) continue;
		self.morphs[i - 1].weights.free();
		self.morphs.remove_at(i - 1);
	}
}
