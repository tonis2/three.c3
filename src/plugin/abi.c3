<*
 The plugin ABI — the one file compiled into both images.

 `plugin_abi.md` is the design; this is its declaration half, and the two are
 meant to be read together. What is here is only what crosses: no engine types,
 no cui, no Vulkan, nothing that would drag three's source into a plugin's build.
 A plugin adds this one file to its sources and links nothing of three's at all.

 ## Why this is not `module three`

 Everything else in this project is, and that is the rule this file is the
 exception to. A plugin is a foreign image that must not claim three's namespace
 — it has its own `main`, its own runtime and its own idea of what `module three`
 would mean — so the shared vocabulary lives somewhere neither side owns.

 ## Handles, not pointers

 `Asset` and `Node` are `ulong`, not `AssetId` and `NodeId`. A handle survives
 the host reallocating the list behind it and cannot be dereferenced by a plugin
 holding a stale one, which is the same decision `scene/node.c3` already made for
 JavaScript and for the same reasons. Zero is "nothing" on both sides — the index
 is stored plus one, so a zeroed struct is empty rather than pointing at slot 0.

 ## Nothing here allocates

 Every string crossing is a `ZString` borrowed for the duration of the call, and
 every variable-length answer is a caller-provided buffer with a count returned.
 See `plugin_abi.md` §6: no ownership crosses, so no verb needs a matching free
 and there is no lifetime rule to get wrong.
*>
module three_abi;

<*
 Bumped on any change to `HostApi`'s or `PluginDesc`'s layout — a field added,
 removed, reordered or retyped.

 There is no minor version and no negotiation: a plugin either was built against
 this engine or was not, and a host that loaded a mismatched one would be
 reading a struct by a map that no longer describes it.
*>
const uint ABI_VERSION = 11;

// The symbol the host looks for. One per image.
const ZString PLUGIN_ENTRY = "three_plugin_main";

<*
 An asset or a node, as the plugin sees it: the host's index plus one in the low
 half, its generation in the high half.

 Plus one so that zero is the empty handle. A `PluginDesc` or a plugin's own
 struct that has been zeroed then holds no stale references by construction,
 which is worth more than the one wasted index.
*>
alias Asset = ulong;
alias Node  = ulong;

<*
 A scene, as its own id.

 Not packed, because a `Scene` already carries a process-wide `uint id` from
 `next_scene_id` and zero is already "none" there. Node verbs take one alongside
 the node: a node handle is unique across scenes, so the host *could* find the
 scene by searching, and `bind_scene.c3` has already done that search by the time
 it calls — paying for it twice per verb is the cost §5 exists to avoid.
*>
alias Scene = ulong;

const Asset NO_ASSET = 0;
const Node  NO_NODE  = 0;
const Scene NO_SCENE = 0;

// What the plugin cannot poll for itself. Input is not here: it is pulled
// through `HostApi`, because that is where a script gets it and there must not
// be two answers to "is the left button down".
enum HostEventKind : char
{
	// The render target changed size. `width` and `height` are the new one.
	RESIZE,
	// The window manager asked to close. The host is going to shut down.
	CLOSING,
	// The window gained or lost focus, in `flag`.
	FOCUS,
}

struct HostEvent
{
	HostEventKind kind;
	uint width;
	uint height;
	bool flag;
}

<*
 What the plugin may ask of the engine.

 One entry per verb, and the list grows toward `js/install_bindings`'s — see
 `plugin_abi.md` §5, which is the rule that keeps the two from becoming two
 surfaces: `install_bindings` is this table's first consumer, not its sibling.

 This is the spike's slice of it. What is missing is most of it.
*>
// A line on the host's stdout, prefixed with the plugin's name. Present from the
// first version because a plugin that cannot say anything is a plugin that can
// only be debugged from outside.
alias LogFn = fn void(ZString message);

// A `.glb` off disk. NO_ASSET if it could not be read — the reason goes to the
// host's own stderr, because a fault does not cross.
alias LoadFn = fn Asset(ZString path);

// Instantiate an asset's node hierarchy under `parent`, or at the root when
// parent is NO_NODE. Answers the group it went into.
alias PlaceFn = fn Node(Asset asset, Scene scene, Node parent);

// The scene being drawn, which is what a plugin that has just started wants.
alias ActiveSceneFn = fn Scene();

<*
 The scene a node is in, or NO_SCENE if the handle names nothing.

 The search `bind_scene.c3`'s `arg_handle` does, exposed once so a plugin holding
 a bare node can do it once and keep the answer rather than paying for it in every
 verb. Node generations come from one process-wide counter, so a handle matches in
 at most one scene and a stale one matches in none.
*>
alias NodeSceneFn = fn Scene(Node node);

alias SetPositionFn = fn void(Scene scene, Node node, float x, float y, float z);

// Multiplies albedo. Per copy, not per material — see `Instance.color`.
alias SetColorFn = fn void(Scene scene, Node node, float r, float g, float b, float a);

// Aim the camera at everything in the scene. What `three.load` does for a
// script, and what a plugin that has just placed its first asset wants.
alias FrameCameraFn = fn void();

<*
 A node's children, into the caller's buffer.

 The count-first shape §6's table names, and the answer to `place` handing back a
 *group*: colour is per drawn node — `Instance.color` — so a group has nowhere to
 put one, and this is how a plugin reaches the nodes that do. Answers the full
 count whether or not it fitted, so a caller can size a buffer and ask again.

 A group's children may be groups themselves; a plugin that wants every drawn
 node under an asset walks. There is no depth argument because a recursive verb
 would be a walk the host does badly on the plugin's behalf.
*>
alias NodeChildrenFn = fn usz(Scene scene, Node parent, Node* out, usz cap);

<*
 Ask for another iteration.

 The window loop sleeps in the kernel when nothing owes a frame, and a plugin
 that animates is something it cannot see: `is_animating` is the runtime's
 question and `ui_idle` is cui's. A plugin that draws an interface needs nothing
 here — its invalidation already sets cui's flag — and one that only moves nodes
 would otherwise stall on an idle window.

 Reading is what clears it, so the loop asks once per iteration.
*>
alias RequestFrameFn = fn void();

<*
 The rest of the node surface, and the shape §5 says the JS bindings become the
 first consumers of.

 Three patterns run through it, and they are the three answers to "what does a
 verb do when it will not do the thing":

 - **A plain write** — `set_visible`, `set_collides`, `set_name`, `set_variant`,
   `set_color`. There is nothing to refuse, so nothing is answered.
 - **A write that can be refused** — `set_transform`, `set_quaternion`,
   `set_static`, `remove_node`, `set_parent`. These answer a bool. A vtable cannot
   raise a JavaScript exception, so **the vtable answers and the caller throws**;
   `transform_refusal` is how the caller gets the sentence to throw.
 - **A read into the caller's buffer** — `world_position`, `object_bounds`. §6's
   shape, with the bool separating "nothing there" from a zero answer.
*>
// `sz` is a builtin type name, so the scale channels are spelled out rather than
// abbreviated — `float sz` is a parse error whose message blames the alias.
alias SetTransformFn = fn bool(Scene scene, Node node, float px, float py, float pz, float rx, float ry, float rz, float scale_x, float scale_y, float scale_z);

alias SetQuaternionFn = fn bool(Scene scene, Node node, float x, float y, float z, float w);

<*
 Why a transform write would be refused, into the caller's buffer.

 Zero means it would not be. The sentence is the solver's own — a node a physics
 body owns is not something a script or a plugin may also move, and the message
 names which body and why. The caller decides what to do with it: `bind_scene.c3`
 raises it, and a plugin might log it.
*>
alias TransformRefusalFn = fn usz(Scene scene, Node node, char* buffer, usz cap);

alias SetVisibleFn  = fn void(Scene scene, Node node, bool on);
alias SetCollidesFn = fn void(Scene scene, Node node, bool on);

// False when the node has a skin: "it does not move" is not true of one, and
// saying so is more useful than silently not caching it.
alias SetStaticFn = fn bool(Scene scene, Node node, bool on);

alias SetNameFn    = fn void(Scene scene, Node node, ZString name);
alias SetVariantFn = fn void(Scene scene, Node node, uint row);

// Three floats. World matrices are brought up to date first, so a read straight
// after a write sees the write.
alias WorldPositionFn = fn bool(Scene scene, Node node, float* out_xyz);

// Six floats, min then max. False when nothing under the node draws — which is
// not the same as a zero-sized box at the origin.
alias ObjectBoundsFn = fn bool(Scene scene, Node node, float* out_min_max);

// False for a scene's root: emptying one is `unload` and freeing it is `dispose`.
alias RemoveNodeFn = fn bool(Scene scene, Node node);

// False across scenes. Two scenes are two node pools, so this would have to
// destroy the subtree and rebuild it, invalidating every handle into something
// that never left the graph.
alias SetParentFn = fn bool(Scene scene, Node node, Node parent);

alias AddGroupFn = fn Node(Scene scene, Node parent, ZString name);
alias AddMeshFn  = fn Node(Scene scene, Asset asset, uint mesh, Node parent, ZString name);

<*
 Geometry a plugin computed, as an asset it can then place.

 The door `plugin_abi.md` §5 left for a plugin that is not placing files. Three
 kinds of thing need it and none of them can be a `.glb` on disk: a mesh built
 from a voxel grid, one edited vertex by vertex, and one whose colours change
 while it is on screen.

 ## Streams

 `positions` and `normals` are three floats each and `colors` is four; all three
 are `vertex_count` long and `normals` and `colors` may be null. `indices` is
 `index_count` long, wound counter-clockwise, and must be a multiple of three.
 Nothing is retained: the arrays are read during the call and the caller may free
 them the moment it returns — §6's rule, and the reason there is no matching
 release verb.

 A mesh with no colour stream draws in the material's own colour and a node's
 `set_color` multiplies it, which is the cheap way to tint a whole model. The
 stream is for the other case, where the tint is per vertex and the point of the
 picture — a weight map, a heat map, a segmentation.

 ## `key` is an identity, not a name

 Two calls with the same key answer with the same asset and the second one
 uploads nothing, exactly as two `new three.BoxGeometry(1,1,1)` do. That makes a
 rebuild cheap to ask for and is a trap for a plugin whose mesh *changed*: a key
 that does not move means the new vertices are silently dropped. Vary it —
 append a counter — and give the old one back with `remove_node` followed by
 `unload_unused`.

 NO_ASSET if the streams do not describe a mesh: no vertices, fewer than three
 indices, or an index count that is not a multiple of three.
*>
alias BuildMeshFn = fn Asset(
	ZString key,
	float* positions,
	float* normals,
	float* colors,
	uint vertex_count,
	uint* indices,
	uint index_count
);

<*
 Free every asset nothing in any scene still names. `three.unloadUnused()`.

 What a plugin that rebuilds its geometry calls after taking the old node out.
 Answers how many assets went, which is zero on the ordinary frame where nothing
 was dropped — so it is cheap to call unconditionally after a rebuild rather than
 tracking whether one is owed.
*>
alias UnloadUnusedFn = fn uint();

<*
 The part of the window the scene draws into, as fractions of it — x, y, width,
 height, y down from the top.

 `{ 0, 0, 1, 1 }` is the whole window and is where a host starts. Anything else
 is a *pane*: a plugin that draws an interface around the scene sets this to the
 rect of the element the scene belongs in, and the engine scissors to it and
 takes the projection's aspect from it. Without that the model is centred on the
 window rather than on the pane and is stretched by the window's shape, which
 reads as the camera being subtly wrong rather than as a rect being unset.

 Fractions rather than pixels because the two ends measure differently: a laid-out
 interface is in logical points and the attachment is in physical ones. A fraction
 needs no backing-scale factor and survives a resize between this call and the
 frame that reads it.

 A rect that lands outside the window is clamped into it, and one that resolves to
 less than a pixel is drawn as one pixel — a pane dragged shut is a picture nobody
 can see, which is right, rather than a validation error.
*>
alias SetViewRectFn = fn void(float x, float y, float width, float height);

<*
 The camera, as the orbit it already is.

 Every field of the engine's own camera except roll, which a plugin that wants it
 can reach from a script. Angles in degrees: yaw turns around +Y with zero
 putting the eye on +Z, pitch lifts the eye above the horizon, and `fov` is
 vertical.

 A plugin that draws its own overlays over the scene — a gizmo, a bone, a label
 pinned to a joint — needs the projection it is projecting with to be the one the
 scene was drawn with. Pushing the camera every frame is what makes those the
 same numbers rather than two things kept in step by hand. Note the *aspect* is
 not here: it is the view rect's, which the engine already knows and the plugin
 would otherwise have to compute the same way twice.
*>
alias SetCameraFn = fn void(
	float target_x, float target_y, float target_z,
	float distance,
	float yaw, float pitch,
	float fov,
	float near_plane, float far_plane
);

<*
 The interface: the two verbs that let a plugin own the screen's foreground.

 A `void*` rather than a `cui::Ui*` because this file is compiled into images
 that have no cui — a plugin that wants one casts on its own side, against the
 same cui the host links. That is `plugin_abi.md` §2's rule showing up in a
 signature: the pointer is only meaningful because there is one cui, and if there
 were two this would be the place it went wrong.

 Null is a layer that would not come up. Everything else about it — hit testing,
 focus, `wants_pointer`, whether the window may go back to sleep — is the host's
 already, and a plugin's tree is subject to all of it.
*>
alias UiContextFn = fn void*();

// A `cui::Element*` built with that Ui, mounted as the interface's content, or
// null to clear. A script's `three.ui.set` and this are exclusive: the last
// writer holds the floor.
alias UiSetRootFn = fn void(void* element);

<*
 A place inside the plugin's own tree for a script's snapshot, or null to
 withdraw the offer.

 The verb that stops a native plugin and a script being two writers over one
 floor. `ui_set_root` says "the interface is mine"; this says "and scripts draw
 *here*", naming a `cui::Element*` of the tree already mounted. `three.ui.set`
 then lands inside the plugin's layout instead of replacing it.

 The obligation is one line long: withdraw before the element goes. cui releases
 a subtree children-first, so a widget's `unmount` hook runs after the snapshot
 under it was recycled — safe, because the host checks, but too late to be
 tidy. `ui_set_root` withdraws for a plugin that rebuilds wholesale.

 Withdrawing clears the snapshot rather than re-homing it, and a script watches
 `three.ui.slot.generation` to know it must draw again. One slot per host: see
 `render/ui.c3`'s `set_slot` for why, and for what the second would cost.
*>
alias UiSetSlotFn = fn void(void* element);

<*
 JavaScript, without QuickJS in the plugin's build.

 `plugin_abi.md` §8 wrote these as `qjs::Value` and it was wrong to: quickjs is a
 static archive, so a plugin that named its types would link a second copy of the
 engine — a second class-id allocator and a second set of C statics behind one
 `JSContext*`. §2's rule is about *state*, and this is the one library where two
 copies of the code would mean two copies of it.

 So a call frame is opaque and arguments are read through the host. The verb
 layer that results is flat — numbers and strings in, one number or string out —
 which is the shape crig's bindings already have.
*>
alias JsCall = void*;

// One verb's body. Reads its arguments and writes its answer through the host,
// and answers `undefined` by writing nothing.
alias JsVerbFn = fn void(void* user, JsCall call, int argc);

<*
 Hang `name` off `globalThis.<namespace>`, creating the namespace object if this
 is the first verb in it.

 `globalThis.three` stays three's and `globalThis.crig` is the plugin's, so
 nothing a plugin registers can enlarge three's API — they are different objects.
 False if there is no runtime up yet, which is every moment outside
 `PluginDesc.install_js`.
*>
alias JsDefineFn = fn bool(ZString namespace, ZString name, int arity, JsVerbFn body, void* user);

// Zero for an argument that is not there or is not a number — the same answer
// `js/bind_scene.c3`'s `arg_number` gives, for the same reason.
alias JsArgNumberFn = fn double(JsCall call, int at);

<*
 An argument as text, into the caller's buffer.

 Answers the full length whether or not it fitted, so a plugin can tell it was
 truncated and ask again with a bigger one. Always terminates when `cap > 0`.
 Caller-provided, because §6 says no ownership crosses and a returned string
 would need a matching free.
*>
alias JsArgTextFn = fn usz(JsCall call, int at, char* buffer, usz cap);

alias JsReturnNumberFn = fn void(JsCall call, double value);
alias JsReturnTextFn   = fn void(JsCall call, ZString value);
alias JsReturnBoolFn   = fn void(JsCall call, bool value);
// Raise a JS exception from the verb. The call answers nothing after this.
alias JsThrowFn = fn void(JsCall call, ZString message);

<*
 Run a plugin's own prelude, after its verbs exist.

 A pointer and a length rather than a `ZString`, because the source a plugin has
 is an `$embed`ed file and `$embed` does not terminate one. `Context.eval` copies
 the bytes regardless — QuickJS requires `input[len]` to be `\0` and it is the
 host that guarantees it — so the terminator would be a plugin-side copy made
 only to be made again.

 False if it threw; the message goes to the host's stderr, because a fault does
 not cross.
*>
alias JsEvalFn = fn bool(ZString name, char* source, usz len);

<*
 The element type a buffer is read or published as.

 The ABI's own numbering, deliberately not quickjs's `ARRAY_*` — those are
 `JSTypedArrayEnum` values, and a contract two images are compiled against
 separately should not be a third library's enum reachable by neither of them.
 `host_js.c3` maps them across in one switch, which is the place a quickjs bump
 would break loudly rather than silently.
*>
const int BUFFER_U8  = 0;
const int BUFFER_I32 = 1;
const int BUFFER_U32 = 2;
const int BUFFER_F32 = 3;
const int BUFFER_F64 = 4;

<*
 An argument's bytes, borrowed for the duration of the call.

 The other half of `js_arg_text`, and the verb that makes item 4 of
 `plugin_plan.md` possible: a plugin cannot link quickjs, so a typed array is
 unreadable to it unless the host hands over the pointer. Any typed array or
 `ArrayBuffer` answers; a plain `Array` does not, because it has no contiguous
 bytes to point at.

 **Bytes, not elements.** The length is in bytes and the pointer is untyped,
 because the plugin already knows what it asked the script to pack — and a
 length in elements would need the kind to mean anything, which is one more
 thing for the two sides to disagree about.

 `bytes` is written even when the answer is zero, so a caller that ignores the
 return value reads a null rather than whatever was in the variable.

 @param bytes : `Where to write the borrowed pointer. Valid only until the verb returns.`
 @return `The length in bytes, or zero for anything that is not a buffer.`
*>
alias JsArgBufferFn = fn usz(JsCall call, int at, char** bytes);

<*
 A typed array as the call's answer.

 `shared` is the whole decision. False copies the bytes into an array
 JavaScript owns, which is what a result computed into scratch wants — the
 plugin is free the moment the verb returns and there is no lifetime rule at
 all. True publishes a **frozen, zero-copy view over the plugin's own memory**,
 which is what a per-frame read of a large array wants and what
 `crig/src/mcp/jsdata.c3` proved against the executable.

 A shared view is recorded by its base address, and `js_drop_buffer` is how the
 plugin says the memory behind it is gone. Nothing else can know: the host has
 no idea when a plugin reallocates, so a shared buffer that is never dropped is
 a script reading released pages.

 Nothing is answered when `len` is zero or `bytes` is null — the call keeps
 whatever it had, which for a verb that wrote nothing else is `undefined`.

 @param kind : `One of the BUFFER_* constants above.`
*>
alias JsReturnBufferFn = fn void(JsCall call, char* bytes, usz len, int kind, bool shared);

<*
 Detach every shared view over `bytes`, before the memory goes away.

 A read through a detached view throws `TypeError: detached ArrayBuffer` at that
 moment, which is the whole point: the alternative is not an error but a wrong
 answer some time later.

 Null drops every view this plugin shared, which is what a plugin does when it
 rebuilds a whole document. Idempotent, and harmless for an address that was
 never shared.

 Not a `JsCall` verb: it is called when the memory changes, which is almost
 never inside a verb body. The host's runtime is the only thing it needs, and
 the host already knows which one that is.
*>
alias JsDropBufferFn = fn void(char* bytes);

<*
 MCP: a plugin's tools land in three's server beside `run_script`.

 `mcp::ToolDef` is already a C registration record — a name, a description, a
 schema, a function pointer and an opaque — so what crosses here is that record
 with two substitutions. `ToolHandlerFn` answers a `String?`, which is a C3 fault
 union with a compiler-internal return ABI and no stated owner for the string;
 and it reads a parsed `json::Object*`, which would tie both images to one
 collection type's layout. Both become text and a bool.

 ## Who provides the storage

 Arguments arrive as a borrowed `ZString` and answers are written back, and the
 difference from `js_arg_text` above is not an inconsistency: **the host lends
 what it already has, and the plugin provides storage for what would have to be
 made.** The tool call's arguments are already a host-owned JSON string alive for
 the call; a JavaScript argument is a `JSValue` that has to be converted, and a
 borrowed answer would need per-call scratch with a lifetime rule to get wrong.
*>
alias McpCall = void*;

// The tool's body. False is a failure, and whatever it replied is the reason.
alias McpToolFn = fn bool(void* user, McpCall call);

<*
 One tool, as the record `mcp::ToolDef` already is.

 A struct rather than seven arguments because that is what it is on the far side,
 and because the two flags below were found by the first real consumer rather
 than guessed: crig hides 21 of its 27 tools and three of them answer with a
 picture. A signature that had to grow twice in a week is one that should have
 been a struct.
*>
struct McpTool
{
	ZString name;
	ZString description;
	// Raw JSON, inserted verbatim into `tools/list`.
	ZString input_schema;
	McpToolFn body;
	void* user;

	<*
	 Whether `tools/list` leaves this one out.

	 **Hidden is not disabled** — `tools/call` dispatches to it exactly as before.
	 The flag decides what a client is *told about*, nothing else. crig's argument
	 for it is the one that matters: its hidden tools are thirty-five thousand
	 characters of description and schema that would otherwise sit in every
	 session's context whether or not anything was rigged, and `run_script`
	 reaches all of them anyway.
	*>
	bool hidden;

	<*
	 Whether the reply is the content array itself rather than text to put in one.

	 Off is the ordinary tool. On is for a tool whose answer is not text at all —
	 an image block carries base64 in a `data` member beside a `mimeType`, and
	 escaping that structure into a text block would deliver the characters of the
	 JSON instead of the JSON. A raw reply must be a well-formed JSON array of
	 content blocks; nothing validates it.
	*>
	bool raw_content;
}

<*
 Register one tool. False if the name is taken — by three, or by a tool this
 plugin already added — rather than shadowing it, because a client that called
 `screenshot` and reached something else has no way to find out.

 The record is copied, including its strings, so a plugin may build one on the
 stack and let it go.
*>
alias McpAddToolFn = fn bool(McpTool* tool);

// The call's arguments, as the JSON object the client sent. Borrowed for the
// call; `{}` when it sent none.
alias McpArgsFn = fn ZString(McpCall call);

// Append to the answer. Called any number of times; the pieces are concatenated
// in order, so a tool can build a long reply without a buffer of its own.
alias McpReplyFn = fn void(McpCall call, ZString text);

<*
 A plugin's documentation, addressable on its own.

 Merged into three's it would make one answer longer than either audience needs
 and hide which half a verb came from — so `get_api_docs` keeps them as separate
 sections under the names registered here.

 Pointer and length for `js_eval`'s reason: the docs a plugin has are an
 `$embed`ed file, and `$embed` does not terminate one.
*>
alias McpDocsFn = fn void(ZString namespace, char* markdown, usz len);

struct HostApi
{
	// The host's own, checked against the plugin's before anything else runs.
	uint abi_version;

	LogFn         log;
	LoadFn        load;
	PlaceFn       place;
	SetPositionFn set_position;
	SetColorFn    set_color;
	FrameCameraFn frame_camera;

	ActiveSceneFn  active_scene;
	NodeSceneFn    node_scene;
	NodeChildrenFn node_children;
	RequestFrameFn request_frame;

	SetTransformFn     set_transform;
	SetQuaternionFn    set_quaternion;
	TransformRefusalFn transform_refusal;
	SetVisibleFn       set_visible;
	SetCollidesFn      set_collides;
	SetStaticFn        set_static;
	SetNameFn          set_name;
	SetVariantFn       set_variant;
	WorldPositionFn    world_position;
	ObjectBoundsFn     object_bounds;
	RemoveNodeFn       remove_node;
	SetParentFn        set_parent;
	AddGroupFn         add_group;
	AddMeshFn          add_mesh;
	BuildMeshFn        build_mesh;
	UnloadUnusedFn     unload_unused;
	SetViewRectFn      set_view_rect;
	SetCameraFn        set_camera;

	UiContextFn ui_context;
	UiSetRootFn ui_set_root;
	UiSetSlotFn ui_set_slot;

	JsDefineFn       js_define;
	JsArgNumberFn    js_arg_number;
	JsArgTextFn      js_arg_text;
	JsReturnNumberFn js_return_number;
	JsReturnTextFn   js_return_text;
	JsReturnBoolFn   js_return_bool;
	JsThrowFn        js_throw;
	JsEvalFn         js_eval;
	JsArgBufferFn    js_arg_buffer;
	JsReturnBufferFn js_return_buffer;
	JsDropBufferFn   js_drop_buffer;

	McpAddToolFn mcp_add_tool;
	McpArgsFn    mcp_args;
	McpReplyFn   mcp_reply;
	McpDocsFn    mcp_docs;
}

<*
 What the engine may ask of the plugin, filled in by `three_plugin_main`.

 `ctx` is handed back to every callback untouched and is never read by the host.
 A null callback is "nothing to do" rather than an error, so a plugin that only
 wants `frame` leaves the other two alone.
*>
// Once per host iteration, after input and before the render, so a write lands
// in the picture the same iteration it was made.
alias PluginFrameFn = fn void(void* ctx, float dt);
alias PluginEventFn = fn void(void* ctx, HostEvent* event);
// Before the device is torn down, so a plugin holding GPU handles still has
// somewhere to give them back to.
alias PluginShutdownFn = fn void(void* ctx);

<*
 Install the plugin's JavaScript namespace.

 Called once for every runtime the host brings up — at boot, and again after
 every `three.reload()`, because the runtime on the far side of a reload is a
 different object. A plugin that captured a context at load time instead would be
 holding a freed one from the first reload onward, and the verbs it installed
 would be gone with it.

 The only place `js_define` and `js_eval` answer true.
*>
alias PluginInstallJsFn = fn void(void* ctx);

<*
 Register the plugin's MCP tools.

 Once per run, when the server is built — which is not every run: `--mcp` is what
 brings one up, and a plugin with no tools to add leaves this null. Unlike
 `install_js` there is no reload to survive; the server outlives every runtime
 the loop makes.

 The only place `mcp_add_tool` and `mcp_docs` answer.
*>
alias PluginInstallToolsFn = fn void(void* ctx);

struct PluginDesc
{
	// ABI_VERSION as the plugin saw it at compile time.
	uint abi_version;
	// For `--help`, the title bar and diagnostics. Must outlive the run; a
	// string literal is the expected answer.
	ZString name;
	void* ctx;

	<*
	 The plugin's own JavaScript directory, or null for a plugin that ships none.

	 **A relative path is relative to the plugin's binary, not to the process.**
	 That is what makes the pair a bundle: the `.js` travels with the `.dylib`,
	 and a plugin works whatever directory three was started in. An absolute path
	 is used as written.

	 Its modules resolve under `plugin:` — `plugin:panels/rig.js` is a file, and
	 `./shared.js` inside it resolves as it would anywhere. The space is separate
	 from the one `--assets` owns, so a game directory and a plugin directory can
	 both be live in one process, and it is readable from the outside: a game's
	 `main.js` may import a plugin's panel to extend it.
	*>
	ZString scripts;
	<*
	 The module three evaluates once the plugin's verbs are installed, relative to
	 `scripts`, or null for a directory that is only ever imported *from*.

	 Evaluated inside `install_js`'s call, which is what makes it survive a reload:
	 the runtime after a reload is a different object, the verbs are installed into
	 it again, and this is run against it again. A panel written against the
	 editor is therefore edited and reloaded with shift+R, no rebuild involved.
	*>
	ZString entry;

	PluginFrameFn      frame;
	PluginEventFn      event;
	PluginShutdownFn      shutdown;
	PluginInstallJsFn     install_js;
	PluginInstallToolsFn  install_tools;
}

<*
 The one exported symbol.

 False is a refusal the host reports and exits on — a wrong ABI version, an
 argument it will not take, a file it could not open. It is not a crash and not
 a silently dead window.

 `argv` is everything after `--` on three's command line, so a plugin parses its
 own flags and three never has to know what they mean.
*>
alias PluginMainFn = fn bool(HostApi* host, int argc, ZString* argv, PluginDesc* desc);

<*
 Pack a host-side index and generation into a handle. `index` is stored plus
 one, so a zero handle is empty rather than slot zero.
*>
fn ulong pack(uint index, uint generation) @inline
{
	return ((ulong)(index + 1)) | (((ulong)generation) << 32);
}

// The index a handle names, or `uint::max` for the empty handle.
fn uint unpack_index(ulong handle) @inline
{
	uint low = (uint)(handle & 0xFFFFFFFF);
	return low == 0 ? uint::max : low - 1;
}

fn uint unpack_generation(ulong handle) @inline => (uint)(handle >> 32);
