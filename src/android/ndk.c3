<*
 The few NDK calls a NativeActivity needs, and the public half of
 android_native_app_glue's `android_app`.

 The glue itself is C from the NDK, compiled and linked in by
 packaging/android/build-apk.sh; it owns the activity callbacks and calls
 `android_main` on a thread of its own.
*>
module three::ndk @feat(ANDROID);

import std::io;

struct Rect
{
	CInt left;
	CInt top;
	CInt right;
	CInt bottom;
}

// ANativeActivity, from <android/native_activity.h>.
struct NativeActivity
{
	void* callbacks;
	void* vm;
	void* env;
	void* clazz;
	ZString internal_data_path;
	ZString external_data_path;
	CInt sdk_version;
	void* instance;
	void* asset_manager;
	ZString obb_path;
}

alias AppCmdFn = fn void(App* app, CInt cmd);
alias InputEventFn = fn CInt(App* app, void* event);

<*
 The fields of `struct android_app` up to `destroyRequested`. The rest is the
 glue's private state, which this side never touches, so it is left out.
*>
struct App
{
	void* user_data;
	AppCmdFn on_app_cmd;
	InputEventFn on_input_event;
	NativeActivity* activity;
	void* config;
	void* saved_state;
	usz saved_state_size;
	void* looper;
	void* input_queue;
	void* window;
	Rect content_rect;
	CInt activity_state;
	CInt destroy_requested;
}

alias PollProcessFn = fn void(App* app, PollSource* source);

struct PollSource
{
	CInt id;
	App* app;
	PollProcessFn process;
}

const CInt LOOPER_ID_MAIN  = 1;
const CInt LOOPER_ID_INPUT = 2;

const CInt APP_CMD_INIT_WINDOW  = 1;
const CInt APP_CMD_TERM_WINDOW  = 2;
const CInt APP_CMD_GAINED_FOCUS = 6;
const CInt APP_CMD_LOST_FOCUS   = 7;
const CInt APP_CMD_START        = 10;
const CInt APP_CMD_RESUME       = 11;
const CInt APP_CMD_PAUSE        = 13;
const CInt APP_CMD_STOP         = 14;
const CInt APP_CMD_DESTROY      = 15;

extern fn CInt looper_poll_once(CInt timeout_ms, CInt* out_fd, CInt* out_events, void** out_data) @cname("ALooper_pollOnce");

const CInt ASSET_MODE_BUFFER = 3;

extern fn void* asset_open(void* manager, ZString filename, CInt mode) @cname("AAssetManager_open");
extern fn void* asset_buffer(void* asset) @cname("AAsset_getBuffer");
extern fn long asset_length(void* asset) @cname("AAsset_getLength64");
extern fn void asset_close(void* asset) @cname("AAsset_close");

extern fn CInt dup2(CInt old_fd, CInt new_fd) @cname("dup2");

// PROP_VALUE_MAX in sys/system_properties.h.
const sz PROPERTY_VALUE_MAX = 92;

extern fn CInt system_property_get(ZString name, char* value) @cname("__system_property_get");

<*
 A system property, as `adb shell setprop` set it; empty when it is unset.

 @return "Temp memory"
*>
fn String property(ZString name)
{
	char[PROPERTY_VALUE_MAX] value;
	CInt len = system_property_get(name, &value);
	if (len <= 0) return "";
	return ((String)value[:(sz)len]).tcopy();
}

<*
 Runs every event the looper has ready, waiting up to `timeout_ms` for the first.

 @param [&inout] app : "The glue's app"
 @param timeout_ms : "0 to not wait, -1 to wait until something arrives"
*>
fn void pump(App* app, CInt timeout_ms)
{
	while (true)
	{
		void* data;
		CInt id = looper_poll_once(timeout_ms, null, null, &data);
		if (id < 0) return;
		PollSource* source = data;
		if (source != null) source.process(app, source);
		if (app.destroy_requested != 0) return;
		// Only the first wait may block; the rest is draining.
		timeout_ms = 0;
	}
}

<*
 A file from the APK's assets/ directory, copied into `alloc`.

 @param [&in] manager : "The activity's AAssetManager"
 @return? io::FILE_NOT_FOUND
*>
fn char[]? read_asset(void* manager, String name, Allocator alloc)
{
	void* asset = asset_open(manager, name.zstr_tcopy(), ASSET_MODE_BUFFER);
	if (asset == null) return io::FILE_NOT_FOUND~;
	defer asset_close(asset);
	long len = asset_length(asset);
	char* bytes = asset_buffer(asset);
	if (bytes == null || len < 0) return io::FILE_NOT_FOUND~;
	return (char[])((String)bytes[:(usz)len]).copy(alloc);
}
