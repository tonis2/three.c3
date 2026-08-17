# M3 — the agent loop closes

The step-by-step record of what M3 built, where it departed from `plan.md`, and
what was actually run to believe any of it. `base_stage.md` is the same document
for M0/M1 and `m2_stage.md` for M2.

**The done condition, from `plan.md` §5: the example in §4 arrives over JSON-RPC
as a string, runs, and comes back as a PNG plus the stats block.** It is met, it
is asserted in `three_tests::mcp`, and it has been driven over a real socket.

    $ three --mcp 8811 --headless --width 320 --height 240
    mcp: http://127.0.0.1:8811/mcp
         run_script, screenshot, get_api_docs

    $ curl -s -X POST http://127.0.0.1:8811/mcp -d @tier1.json
    blocks: ['text', 'image']
    ok: True
    stats: {'drawCalls': 1, 'uniqueMeshes': 1, 'instances': 12, 'nodes': 13, ...}
    png bytes: 1624 magic ok: True

Twelve JS-placed meshes, one draw call, and a picture of it — which is the M2
claim surviving the binding rather than being restated by it.

## The steps

### S1 — the API is JavaScript, not a binding (`src/js/prelude.js`)

The largest decision here, and the one everything else got cheaper because of.

`plan.md` §4's rule is "copy Three.js exactly where the semantics match". Doing
that in the host means one C3 function per property per class — `position` alone
is three getters and three setters, and each has to find its instance with no
`JS_SetOpaque` to hang it off. Doing it in JavaScript means `class Mesh extends
Object3D` and a `children` array that *is* an array.

So the host exposes eighteen flat verbs on `globalThis.__three` — take numbers,
answer with numbers — and `prelude.js` builds `Scene`/`Mesh`/`Group`/`Vector3`/
`Asset`/`camera` on top. Every Three.js-ism lives in the language that has them.

**`$embed`, and that is not a contradiction of `shader/load.c3`.** The trap that
file documents is a *generated* artifact: `c3c build shaders` without
`--trust=full` skips the exec, reports success, and `$embed` picks up the
previous SPIR-V. `prelude.js` is hand-written source with no build step to skip,
so it is exactly as stale as the `.c3` files beside it. Embedding it means the
file that *defines* the API cannot be missing at runtime.

**`getApiDocs()` is in the same file as the API it describes**, which is the only
arrangement where the two cannot drift. The `get_api_docs` tool asks the runtime
for it rather than keeping a copy.

### S2 — every script is an async function body (`src/js/runtime.c3`)

The source is wrapped in `(async()=>{` … `})()` before evaluation. That buys
`await` at the top level — `const kit = await three.load(...)` is the line an
agent that has memorized Three.js writes, and a SyntaxError on it would be the
API being surprising on the first line of the first script — and it buys
`return`, which is where the returned value comes from.

**The open brace carries no newline**, so line 1 of the script is line 1 in every
stack trace. A test asserts on that, because getting it wrong is invisible until
someone tries to fix a script by the number in the error.

The cost is that a bare trailing expression is not the result; `return` it. That
is in `getApiDocs()` because it is the one place this shape shows from outside.

`JS_EVAL_FLAG_ASYNC` does all of this natively and quickjs.c3l's shim does not
expose it — `qjs_eval` maps its `type` onto GLOBAL or MODULE and nothing else.
Reaching it would mean changing that submodule. The promise is settled by
attaching `then` from the host and draining the job queue, for the same reason:
`JS_PromiseResult` passes `JSValue` by value, which is the ABI bet the shim
exists to avoid.

### S3 — handles revalidate, which is what M2 paid for

`plan.md` §1 requires a JS handle to revalidate on access and *throw* rather than
dereference a freed node. Every verb that names a node resolves `(index,
generation)` through `Scene.node` first, and a stale one raises a JS `Error`
saying what happened.

This is the milestone where `NodeId`'s generation stops being defensive clutter.
`m2_stage.md` S1 said paying for it then would make the M3 binding a lookup
rather than a lifetime redesign; it did.

The pair crosses as two plain numbers rather than as an opaque object, because
the shim has no way to hang host data off a JS object. A script can read and
forge them — and forging one produces the stale-handle throw, which is why
revalidation is the guard rather than concealment.

### S4 — an object is not in the scene until it is added

`new three.Mesh(ref)` creates **no host node**. `scene.add(m)` does.

The alternative — create the node at construction, under the root — is one line
shorter and quietly renders a mesh that was never added. That is the failure §4
warns about directly: a half-match is worse than a new name, because the agent
will not read the docs for a name it recognizes.

Everything set before the add is replayed onto the node at that moment: the
transform, the name, the visibility, and whole subtrees, so `group.add(mesh)`
before `scene.add(group)` works the way it does in Three.js. Removing an object
turns it back into a detached description that can be added again.

**Re-parenting moves the node rather than rebuilding it.** Destroy-and-recreate
would climb the generation and invalidate every handle to something that never
left the scene.

### S5 — one scene, and the divergence is made loud

There is one host `Scene`, so a second `new three.Scene()` empties the first.
Three.js lets you hold several.

Rather than let the older `Scene` quietly operate on the newer one's nodes, each
carries an epoch that is checked on use, and the stale one throws a sentence
saying what happened. Every divergence from Three.js is listed in
`getApiDocs().differences` for the same reason: the divergences are short, and
each one is a script that would otherwise fail.

### S6 — three tools, and the answer shape (`src/mcp/server.c3`)

`run_script` *is* the API surface — every scene verb is already a JavaScript
call — so a fourth tool would be a second, worse spelling of something the script
can do, and one more thing to keep in step. `screenshot` and `get_api_docs` exist
because they are the two things a script cannot answer for itself.

`run_script` returns a **content array**, not text, because one of the four
things it always answers with is a PNG and an image block is the only way to
carry one. The first block is the report — log, value, error, stats, as JSON —
and the second is the frame. **Both, whether or not the script succeeded**
(§4). A failed run that returns only an error makes the agent guess how far it
got, and the picture of a half-built scene is often the thing that says.

`value` is spliced into the report rather than escaped into it: it is already
JSON, and quoting it would hand the agent the characters of its own result.

### S7 — `--mcp [port]`, and where the handlers run

`Listener` gives its own thread to moving bytes; `Listener.pump` runs
`handle_message` on the caller's. So the scene, the JS context and the Vulkan
device are all touched from the one loop that renders, and none of the three
needs a lock — which is what they are each prepared for and nothing more.

Windowed and headless both serve. Windowed keeps rendering between requests,
because a window that only redrew when a tool was called reads as a hung
application.

`--mcp` is checked before every one-shot path: a server does not render one
frame and exit.

## What was wrong before M3 and is fixed now

- **`lib/quickjs.c3l/vendor/quickjs-ng` was uninitialised**, so the shim had no
  `quickjs.h` and the build failed in the C compiler, several layers from
  anything that mentions submodules. `plan.md` already warned that `--recursive`
  is not optional for this dependency; `project.json` now says so at the line
  that adds it.
- **`Scene` had no way to rename a node.** `create_slot` copies the name it is
  given and `kill` frees it, so a rename that did not free the old one would leak
  on every `m.name = ...`. `Scene.set_name` is the missing half.

## Where this departed from `plan.md`

- **`js/bind_shader.c3` was not written**, and will not be before M4 — it is the
  tier-2 material surface, which needs a runtime Slang compiler that does not
  exist yet. §4 says to ship tier 1 alone first; this is that.
- **`js/prelude.js` is not in §4's file list**, because §4 assumed the API would
  be built out of `Context.accessor` calls. See S1 for why it is not.
- **The camera diverges deliberately.** `plan.md` calls for a Three.js-shaped
  `PerspectiveCamera`; what exists is still M1's turntable, so the API exposes
  `three.camera.orbit(yaw, pitch, distance)` and `frameAll()` — names Three.js
  does not have — rather than a `camera.position` that would half-match. §4's own
  rule: clearly diverge where the semantics do not match.
- **`scene.raycast()` is still not exposed to JS.** §5 puts it at M5 and there is
  no reason to pull it forward; `scene/pick.c3` has been built and tested since
  M2.

## Verification

    c3c build --trust=full                               clean
    c3c test --trust=full --test-noleak                  60 passed, 0 failed
    c3c test --trust=full                                60 passed, leak-clean

Thirty-one of those are new: twenty-three in `three_tests::js` and eight in
`three_tests::mcp`. Twenty of the twenty-three need no GPU and run in under a
millisecond each, because the scene graph, the handles, the staleness checks and
`stats()` are all reachable with a `MeshPass` that was never given a pipeline.

The MCP suite drives the wire **in-process** — raw JSON-RPC in, parsed JSON out,
no socket and no subprocess — which `plan.md` §5 asks for and which is what keeps
the whole tool surface at unit-test speed.

**Every regression test claimed here was checked by re-introducing the bug it
catches** (`plan.md` §7: an unexercised regression test is an assumption). Each
was injected, the named test observed to fail, and the source restored and
verified byte-identical by checksum:

| bug injected | test that caught it |
|---|---|
| the async wrapper opens with a newline | `a_stack_points_at_the_scripts_own_lines` |
| handles are not revalidated | `a_handle_into_a_removed_object_throws` |
| a replaced `Scene` stays silent | `a_replaced_scene_says_so` |
| re-parenting rebuilds the node | `reparenting_keeps_the_same_node` |
| `add()` never reaches the host scene | `an_object_joins_the_scene_only_when_added` |
| `RunResult.free` guards on length, not pointer | `a_script_returns_what_it_returned` (leak-tracked run only) |

The last one is worth its own note. `DString.copy_str` allocates even for an
empty string — one byte, for the terminator — so `if (len > 0)` frees three of
the four fields and leaks whichever a run left empty. Which is most runs: a
script that succeeds has no `error`, one that returns nothing has no `value`. It
is a byte at a time, invisible in a suite that runs a script once, and unbounded
in an agent loop. **`--test-noleak` cannot see it**; only the tracked run can,
which is the argument for running the slow one before believing a milestone.
quickjs.c3l's `Context.text` documents the same rule from the other side: always
allocate, so the caller can always free.

On top of that, run by hand against a live server on port 8811:

| what | result |
|---|---|
| `tools/list` over HTTP POST | three tools, named |
| §4's example as a JSON-RPC string, `truck.glb` | `drawCalls: 1`, `instances: 12`, a 1624-byte PNG |
| three whole trucks via `Group`, 4 primitives each | `drawCalls: 4`, `instances: 12`, correctly lit and textured |
| the returned base64, decoded | a real PNG, magic bytes checked |

The second and third are the same claim from two directions: twelve instances of
one mesh is one draw, and twelve instances spread across four meshes is four —
so `drawCalls` counts distinct geometry rather than anything about how many times
`add` was called.
