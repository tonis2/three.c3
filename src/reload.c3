<*
 Hot reload — §8, and the two answers §9 wanted before it could land.

 shift+R in a `--debug` window, or `three.reload()` from a script or a tool call
 in any run at all.

 ## What a reload collects, and what it deliberately does not

 The assets stay. `three.unloadUnused()` across a reload would free the exact
 things that make the *next* one fast, and the cost is bounded by the game's own
 asset set rather than by how many times somebody has hit the key.
*>
module three;

import std::io;
import c3w;
import qjs;

<*
 Tears the world down and boots it again.

 The order is the whole content of this function and every step of it is load
 bearing:

 1. `take_persist` **before** the close, because it runs JavaScript.
 2. `close` before the world is touched, because every retained callback is a
 reference into the context and releasing one afterwards releases it into an
 engine that is no longer there.
 3. The post chain before the scenes, because `PostPass.clear` gives images back
 to the same `Assets` table `Scene.free` is about to release nodes against.
 4. `activate_scene` **before** the script rather than after: a `main.js` that
 never calls `new three.Scene()` still has to start on a default background
 and no camera follow, and the fresh scene is what carries those.
 5. `restore_persist` before the script and after the prelude, which is the only
 window in which `three` exists and `main.js` has not read it yet.

 A boot that throws is printed and carried on with, exactly as the first one is —
 there is nothing to roll back to, since the world it replaced has already been
 freed, and an empty scene beside the reason for it is what somebody about to fix
 a typo wants to see.

 @param pass : `The world — renderer.pass in every caller that has a device.`
 @param renderer : `Null in a scene-math runtime, which has no post chain and nothing on a device to give back.`
 @param window : `Put back on the new runtime, which is otherwise the one thing a fresh context could not find out for itself.`
 @param assets : `The game directory this process booted from, or empty.`
 @param script : `The one .js file this process booted from, or empty.`
 @param boot : `False when this process booted with --no-boot, so a reload does not start the game the run deliberately did not.`
 @param entry_module : `The one .js file this process booted as a module, or empty.`
 @return ? JS_ENGINE_FAILED : `The engine would not start a second time, which is out of memory and nothing else.`
*>
fn void? reload(
	JsRuntime* runtime,
	MeshPass* pass,
	Renderer* renderer = null,
	c3w::Window* window = null,
	String assets = "",
	String script = "",
	bool boot = true,
	String entry_module = ""
)
{
	Gpu* gpu = renderer != null ? &renderer.gpu : null;

	String kept = runtime.take_persist(mem);
	defer kept.free(mem);

	runtime.close();

	if (renderer != null) renderer.post.clear(gpu, &pass.assets);
	pass.reset_world(gpu);

	runtime.open(pass, renderer)!;
	runtime.window = window;
	runtime.activate_scene(pass.scene);
	runtime.restore_persist(kept);

	boot_world(runtime, assets, script, boot, entry_module)!;
}

<*
 Whether this frame's input asked for a reload — shift+R.

 An edge on the R and a level on either shift, which is the pair every accelerator
 is: holding the combination reloads once, not sixty times a second.

 It is a reserved key while `--debug` is on, the way escape is, and only then —
 which is what makes reserving it affordable. A shipped game binds shift+R to
 whatever it likes and keeps it; a developer diagnosing that game loses the
 binding for as long as the flag is up, and knows why. The loop is what applies
 the gate; this only answers what the keys are doing. The two are named together
 in the line it prints at startup, and that line prints only when they work.

 The reading is the window's own, before `JsRuntime.tick` folds `three.input.press`
 into it — so a script cannot reload the process by pressing its own keys, which
 is one fewer thing for a headless run to do by accident.
*>
fn bool wants_reload(InputState input)
{
	if (!input.pressed.has(c3w::EventKey.R)) return false;
	return input.down.has(c3w::EventKey.LEFT_SHIFT) || input.down.has(c3w::EventKey.RIGHT_SHIFT);
}

<*
 Empties the world and leaves one scene in it, keeping everything a rebuild would
 have to pay for again.

 The pair `free_scenes`/`init_scenes` rather than a walk that removes nodes: a
 scene owns a node pool, a physics world and a nav bake, and emptying it by hand
 would be a fourth place that has to be told when a fifth thing is added to a
 `Scene`. `init_scenes` also puts the bootstrap scene back, which is what lets the
 new script's first `new three.Scene()` claim it instead of counting two.

 The follow is cleared for `activate_scene`'s reason — it names a `NodeId` into a
 pool that has just been freed, and a camera that silently tracked a dead node
 would look like the follow being broken.

 @param gpu : `Null in a scene-math runtime. The material collection then frees no images, which is right: there are none.`
*>
fn void MeshPass.reset_world(&self, Gpu* gpu)
{
	self.free_scenes();
	self.init_scenes();
	self.release_script_materials(gpu);
	self.follow = { };
}

<*
 Gives back every material the old script was holding a handle to.

 Materials are the one thing here that a reload has to collect by hand, and the
 reason is that they are freed by a *handle* going away rather than by a node
 dying: `material.dispose()` is what releases one, and every handle that would
 have called it went down with the context. Without this, ten reloads of a game
 with twenty materials is two hundred live materials, each holding a pipeline,
 and `MATERIAL_WARN_AT` would start advising about a leak the person at the
 keyboard cannot do anything about.

 The two built-in materials are skipped for `MeshPass.editable`'s reason: they are
 shared by every node that was never given one of its own, and nobody's to
 dispose.

 Called after the fresh scene exists, because `collect_materials` walks the active
 scene to find out what is still named — and the answer it needs is "nothing",
 which is what an empty scene says.
*>
fn void MeshPass.release_script_materials(&self, Gpu* gpu)
{
	foreach (i, &material : self.materials)
	{
		if (!material.alive || material.released) continue;
		if ((uint)i == DEFAULT_MATERIAL || (uint)i == LINE_MATERIAL) continue;
		material.released = true;
		self.pending_materials++;
	}
	self.collect_materials(gpu);
}

<*
 Reads `three.persist` out of a context that is about to close.

 JavaScript, and so it has to run before `close` — which is the only reason this
 is a separate verb rather than the first three lines of `reload`.

 The answer is already JSON: `RunResult.value` is `js.json` of whatever the script
 returned, so a persist object crosses as the text of itself with no second
 stringify. A value `JSON.stringify` refuses — a cycle, a `Map`, a function — comes
 back as the empty string and is simply not restored. That is reported by
 `restore_persist` rather than here, because here there is no longer a context to
 report it into.

 @return `The state as JSON, "null" for a game that never wrote any, or empty when it could not be serialised. Owned by the caller.`
*>
fn String JsRuntime.take_persist(&self, Allocator allocator)
{
	if (!self.ready) return "".copy(allocator);

	// `drain_frame: false` — this run is the host's own and not the agent's, so
	// what the animation loop logged stays where it is for whoever asked next.
	RunResult saved = self.run("return three.persist ?? null;", "<reload>", drain_frame: false);
	defer saved.free();
	if (!saved.ok) return "".copy(allocator);
	return saved.value.copy(allocator);
}

<*
 Puts it back, and says that this boot is a reload.

 Both writes land on the `three` object the prelude has just built, before
 `main.js` runs, which is the only moment at which that is possible: the prelude
 declares `persist` and `reloaded` so that a first boot reads sensible values from
 them, and this is what makes the second boot's values different.

 Parsed through the engine rather than spliced into a source string. A JSON object
 is a valid JavaScript expression but not the *same* expression — `{"__proto__":
 {}}` is an own property to `JSON.parse` and a prototype assignment to an object
 literal — and a game's saved state is exactly the place that difference would go
 unnoticed.

 @param json : `What take_persist answered with. Empty or "null" restores nothing and still marks the boot.`
*>
fn void JsRuntime.restore_persist(&self, String json)
{
	qjs::Value global = self.js.global();
	defer self.js.release(global);

	qjs::Value api = self.js.property(global, "three");
	defer self.js.release(api);
	if (api.tag() != qjs::TAG_OBJECT) return;

	// Set whether or not there is state to put back: a game that keeps nothing
	// still wants to know it is starting from a reload rather than from a boot.
	self.js.set_property(api, "reloaded", qjs::bool_value(true));

	if (json.len == 0 || json == "null")
	{
		// The empty string is the serialisation having failed, which is worth a
		// line — the game asked for something to be kept and it was not.
		if (json.len == 0)
		{
			io::printn("three: three.persist was not JSON and did not survive the reload");
		}
		return;
	}

	qjs::Value? state = self.js.from_json(json, "<three.persist>");
	if (catch state)
	{
		// Taken rather than left pending: the next thing to run is `main.js`, and a
		// stray exception from the host's own restore would surface as the game
		// having thrown.
		String message = self.js.exception(mem);
		defer message.free(mem);
		io::printfn("three: three.persist did not parse back: %s", message);
		return;
	}
	self.js.set_property(api, "persist", state);
}

<*
 `three.reload()` — asks for one, rather than performing one.

 The call is made from inside the context a reload destroys, so doing it here
 would free the engine that is running this function. The flag is read by the
 window loop between `pump` and the tick, which is the one point in a frame where
 nothing is on the JavaScript stack.

 That also makes it the `--mcp` half of §8: an agent's `run_script` sets the flag,
 the loop performs the reload before the next tick, and the screenshot after it
 shows the edited file. It is answered synchronously either way — the call returns
 immediately and the reload has not happened yet.

 A run with no loop to read the flag — a `--frames` batch, a test — never performs
 one. Nothing is raised about it: the same script has to work in both, and a verb
 that threw under `--frames` would make a game unrunnable in the mode that checks
 it.
*>
fn void js_reload(qjs::ContextRef ctx, qjs::Value* this_val, int argc, qjs::Value* args, void* opaque, qjs::Value* out)
{
	JsRuntime* self = (JsRuntime*)opaque;
	self.reload_wanted = true;
	*out = qjs::undefined_value();
}