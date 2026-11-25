<*
 The Quest build's entry point: what `main` is on the desktop.

 A NativeActivity has no argv, no terminal and no working directory worth the
 name, so this fills an `Options` itself (the seam `boot.c3` describes), sends
 stdout and stderr to logcat, and finds the game on disk before booting it.
*>
module three @feat(ANDROID);

import std::io;
import std::io::file;
import std::io::path;
import std::os::env;
import std::os::posix;
import std::os::android;
import std::thread;
import std::time;
import libc;
import three::ndk;

const ZString LOG_TAG = "three";

// Frames the headless probe runs when OpenXR is not up.
const uint PROBE_FRAMES = 300;

<*
 Called by android_native_app_glue on its own thread once the activity exists.
 Returning ends the activity; the process is exited too, because the engine's
 globals are not built to be booted twice in one process.
*>
fn void android_main(ndk::App* app) @export("android_main")
{
	start_logcat_pipe();
	app.on_app_cmd = &on_app_cmd;

	// The glue's thread is not the process's main thread, so the temp allocator
	// the engine leans on has to be made here; only main gets one implicitly.
	@pool_init(mem, 256 * 1024)
	{
		ndk::NativeActivity* activity = app.activity;
		String internal = activity.internal_data_path.str_view();
		String external = activity.external_data_path != null ? activity.external_data_path.str_view() : "";
		io::printfn("three: android_main, sdk %d", activity.sdk_version);
		io::printfn("three: internal %s", internal);
		io::printfn("three: external %s", external);

		if (catch err = run_android(app, internal, external))
		{
			io::eprintfn("three: stopped: %s", err);
		}
	};

	io::printn("three: exiting");
	libc::fflush(libc::stdout());
	libc::fflush(libc::stderr());
	libc::exit(0);
}

fn void on_app_cmd(ndk::App* app, CInt cmd)
{
	switch (cmd)
	{
		case ndk::APP_CMD_RESUME: io::printn("three: resumed");
		case ndk::APP_CMD_PAUSE: io::printn("three: paused");
		case ndk::APP_CMD_DESTROY: io::printn("three: destroy requested");
		default:
	}
}

fn void? run_android(ndk::App* app, String internal, String external)
{
	// Saves land in the app's own data directory; `paths.c3` reads this.
	env::set_var("XDG_CONFIG_HOME", internal);
	env::set_var("HOME", internal);

	GameDir game = find_game(app.activity.asset_manager, internal, external)!;
	io::printfn("three: game %s, %s", game.root, game.script.len > 0 ? game.script : ENTRY_MODULE);

	// Before the engine: the runtime decides which Vulkan device and extensions
	// the engine opens with. Without it the run is the headless probe.
	XrHost* host = mem::new(XrHost);
	defer mem::free(host);
	bool xr_up = @ok(host.open(app, xr_render_scale(), xr_layer_filter()));
	if (!xr_up)
	{
		io::eprintn("three: OpenXR is not available; running the headless probe");
		host.close();
	}

	Options opts = {
		.assets        = game.root,
		.script        = game.script,
		// Both eyes, side by side.
		.width         = xr_up ? host.eye_width * 2 : 1280,
		.height        = xr_up ? host.eye_height : 720,
		.headless      = true,
		.cache_dir     = string::tformat("%s/shader-cache", internal),
		.cache_dir_set = true,
	};
	choose_caches(opts);

	Engine* engine = mem::new(Engine);
	defer mem::free(engine);
	defer engine.close();
	// Both eyes in one multiview pass where the device can.
	engine.open(opts.width, opts.height, headless: true, views: xr_up ? 2 : 1)!;
	engine.renderer.gpu.report();
	// No depth prepass on the headset. Adreno bins the frame and builds a coarse
	// depth of all of it (LRZ) before shading, which throws away hidden fragments
	// without one, so the prepass here mostly doubled the vertex work - the
	// binning pass ran every vertex twice per eye. `examples/vr_bench.js`: a
	// 400k-triangle scene 15 ms with it and 8.5 ms without; four overlapping
	// walls cheaper without it too. A script can still turn it on.
	engine.renderer.pass.prepass.enabled = false;
	// Shadows with one hardware-filtered tap: the four taps against the receiver's
	// plane were 3.2 ms of a 7.7 ms frame on the game's table, and one tap 1.0 ms,
	// with the same 2x2 filter and no difference anyone could see at the headset's
	// shadow distances (`SKIP_RECEIVER_PLANE`).
	engine.renderer.pass.one_tap_shadows = true;
	// For profiling: whether the per-pass GPU timestamps and the statistics query
	// cost anything shows in Meta's own app GPU time (the VrApi line) with them gone.
	if (ndk::property("debug.three.timestamps").trim() == "0")
	{
		engine.renderer.timer.free(&engine.renderer.gpu);
		io::printn("xr: debug.three.timestamps is 0, so no GPU timing this run");
	}
	// Runs before `engine.close`: the session holds the engine's device.
	defer host.close();
	if (xr_up) host.start(&engine.renderer.gpu)!;
	// Before the boot, so a script can ask what the headset can do.
	engine.renderer.xr_display.passthrough_supported = host.passthrough_supported;

	JsRuntime runtime;
	runtime.open(&engine.renderer.pass, &engine.renderer)!;
	defer runtime.close();
	boot_world(&runtime, opts.assets, opts.script)!;

	if (xr_up)
	{
		// Heap, not stack: the tools hold pointers into it.
		HeadsetDev* dev = mem::new(HeadsetDev);
		defer mem::free(dev);
		dev.open(&runtime, &engine.renderer, game, external);
		defer dev.close();
		run_xr(app, host, &engine.renderer, &runtime, dev)!;
		return;
	}
	defer game.free();
	run_probe(app, &engine.renderer, &runtime)!;
}

<*
 Ticks and renders offscreen for a fixed number of frames, then waits for the
 activity to be closed. Proves the device, the shaders and the script all work
 on the headset before anything is shown.
*>
fn void? run_probe(ndk::App* app, Renderer* renderer, JsRuntime* runtime)
{
	DString said;
	said.init(mem, 256);
	defer said.free();

	renderer.pass.clock.frame_ms = HEADLESS_FRAME_MS;
	Clock started = clock::now();
	for (uint i = 0; i < PROBE_FRAMES && app.destroy_requested == 0; i++)
	{
		ndk::pump(app, 0);
		Clock host_started = clock::now();
		runtime.tick((double)i * HEADLESS_FRAME_MS);
		print_frame_output(runtime, &said);
		if (runtime.quit_wanted) return;
		long wait_ns;
		renderer.render_offscreen(&wait_ns)!;
		runtime.complete_host_frame((long)host_started.to_now(), wait_ns);
	}
	long took_ms = (long)started.to_now() / 1_000_000;
	SceneStats stats = renderer.pass.stats();
	io::printfn("three: probe rendered %d frames in %d ms (%.1f ms/frame), %d draw calls, %d instances, %d triangles",
		PROBE_FRAMES, took_ms, (double)took_ms / PROBE_FRAMES, stats.draw_calls, stats.instances, stats.triangles);

	while (app.destroy_requested == 0) ndk::pump(app, -1);
}

struct GameDir
{
	// Owned, both.
	String root;
	// Empty when the root has a main.js to boot instead.
	String script;
}

fn void GameDir.free(&self)
{
	if (self.root.len > 0) free(self.root);
	if (self.script.len > 0) free(self.script);
	*self = {};
}

<*
 Where the game is: a folder pushed with adb wins, so a script can be changed
 without rebuilding the APK; otherwise the copy packed in the APK.
 A folder holds either a `main.js` (booted as a module) or a `script.js`.

 @return? io::FILE_NOT_FOUND
*>
fn GameDir? find_game(void* assets, String internal, String external)
{
	if (external.len > 0)
	{
		String pushed = string::format(mem, "%s/game", external);
		if (try found = game_in(pushed)) return found;
		free(pushed);
	}
	String unpacked = string::format(mem, "%s/game", internal);
	unpack_game(assets, unpacked)!;
	return game_in(unpacked);
}

<*
 @return? io::FILE_NOT_FOUND
*>
fn GameDir? game_in(String root)
{
	if (file::is_file(string::tformat("%s/%s", root, ENTRY_MODULE))) return { .root = root };
	String script = string::format(mem, "%s/script.js", root);
	if (file::is_file(script)) return { .root = root, .script = script };
	free(script);
	return io::FILE_NOT_FOUND~;
}

<*
 Copies assets/game/** out of the APK, which is a zip and not a directory the
 engine can read. `game/manifest.txt` lists the files, a stamp first; the copy
 is skipped when the stamp matches the last one written, and otherwise starts
 from an empty folder.

 @return? io::FILE_NOT_FOUND
*>
fn void? unpack_game(void* assets, String dest) => @pool()
{
	char[] listing = ndk::read_asset(assets, "game/manifest.txt", tmem)!;
	String[] lines = ((String)listing).tsplit("\n");
	if (lines.len == 0) return io::FILE_NOT_FOUND~;
	String stamp = lines[0].trim();

	String stamp_path = string::tformat("%s/.stamp", dest);
	if (try old = file::load_temp(stamp_path))
	{
		if ((String)old == stamp)
		{
			io::printfn("three: game already unpacked (%s)", stamp);
			return;
		}
	}

	// A different APK: what the last one unpacked goes first. Left in place, a
	// game folder's main.js would win over the new APK's script.js, and the old
	// game would boot instead of the new one.
	if (file::is_dir(dest)) path::rmtree(path::tnew(dest)!)!;
	path::mkdir(dest, recursive: true)!;
	usz count;
	foreach (line : lines[1..])
	{
		String name = line.trim();
		if (name.len == 0) continue;
		char[] data = ndk::read_asset(assets, string::tformat("game/%s", name), tmem)!;
		String out = string::tformat("%s/%s", dest, name);
		if (try parent = out.path_tdirname()) path::mkdir(parent, recursive: true)!;
		file::save(out, data)!;
		count++;
	}
	file::save(stamp_path, stamp)!;
	io::printfn("three: unpacked %d files (%s)", count, stamp);
}

// The read end of the pipe stdout and stderr were pointed at.
CInt log_read_fd @local;
// Global rather than a local: the new thread reads it after `create` returns.
Thread log_reader @local;

<*
 Points stdout and stderr at a pipe and forwards each line to logcat, since an
 app's own stdout goes nowhere on Android.
*>
fn void start_logcat_pipe()
{
	CInt[2] fds;
	if (posix::pipe(&fds) != 0) return;
	libc::setvbuf(libc::stdout(), null, libc::_IOLBF, 0);
	libc::setvbuf(libc::stderr(), null, libc::_IONBF, 0);
	ndk::dup2(fds[1], 1);
	ndk::dup2(fds[1], 2);
	log_read_fd = fds[0];
	Thread* reader = &log_reader;
	if (catch reader.create(&forward_log, null)) return;
	(void)reader.detach();
}

fn int forward_log(void* arg)
{
	char[4096] buf;
	usz used;
	while (true)
	{
		sz got = libc::read((libc::Fd)log_read_fd, &buf[used], buf.len - 1 - used);
		if (got <= 0) return 0;
		used += (usz)got;
		usz start;
		for (usz i = 0; i < used; i++)
		{
			if (buf[i] != '\n') continue;
			buf[i] = 0;
			android::log_write(ANDROID_LOG_INFO, LOG_TAG, (ZString)&buf[start]);
			start = i + 1;
		}
		// A line longer than the buffer goes out in pieces rather than stalling.
		if (start == 0 && used == buf.len - 1)
		{
			buf[used] = 0;
			android::log_write(ANDROID_LOG_INFO, LOG_TAG, (ZString)&buf[0]);
			used = 0;
			continue;
		}
		used -= start;
		if (start > 0 && used > 0) mem::move(&buf[0], &buf[start], (sz)used);
	}
}
