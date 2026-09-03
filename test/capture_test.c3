<*
 Writing an image from a script: `three.screenshot(path)` and `texture.save(path)`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::capture`

 Both are doors out of the process onto the disk, and there are two of them
 because there are two kinds of image a script has: the frame, and a texture.
 Neither existed before — the only way to get a picture out was the
 `--screenshot` flag, which writes the frame the *harness* chose on a schedule
 made of `--frames` and `--every`. `examples/trimsheet.js` had six images to
 write and had to arrange for the state of each one to fall on the frame the flag
 would capture, which is the thing these checks are really about: two shots of one
 run, taken at two moments the script picked, come out as two different pictures.

 **The files go under `build/`**, which is gitignored, so a failed run leaves
 nothing that becomes a diff and `rm -rf build` is the whole of the cleanup. The
 sandbox checks need a game directory and a file next door to try to reach, which
 is `@with_game` below — a smaller version of `shipping_test.c3`'s `@with_assets`,
 because the interesting file here is a `.png` this run wrote rather than a level
 list a fixture holds.
*>
module three_tests::capture;

import three;
import three_tests::device;
import vk;
import std::core::test;
import std::io::file;
import std::io::path;

const uint W = 200;
const uint H = 150;

// Where a check that only wants a file writes it.
const String SHOTS = "build/test-shots";

// A game directory and a file outside it, for the two sandbox checks.
const String GAME = "build/test-shot-game";
const String OUTSIDE = "build/test-shot-outside.png";
const String OUTSIDE_TEXT = "not a picture, and must stay that way";

// The eight bytes every PNG starts with. Checked rather than assumed: a verb
// that wrote the raw readback would still produce a file of about the right
// size, and `bytes > 0` would pass.
const char[8] PNG_MAGIC = { 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

macro @with_gpu_js(; @body(three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(W, H);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

// The same with no device at all, for the two checks that are about the refusal.
macro @with_js(; @body(three::JsRuntime* run))
{
	three::MeshPass pass;
	pass.assets.init();
	pass.init_scenes();
	pass.camera = three::default_camera();
	defer pass.free_scenes();
	defer pass.assets.free(null);

	three::JsRuntime runtime;
	runtime.open(&pass)!!;
	defer runtime.close();

	@body(&runtime);
}

// An empty directory to write into, gone before and after.
macro @with_shots(; @body)
{
	(void)path::rmtree((Path)SHOTS);
	defer (void)path::rmtree((Path)SHOTS);
	path::mkdir((Path)SHOTS, recursive: true)!!;
	@body();
}

<*
 A game directory with a file sitting outside it, which is what the sandbox is
 for: `..` out of the root is the obvious way to reach it and must not work.
*>
macro @with_game(; @body)
{
	(void)path::rmtree((Path)GAME);
	(void)path::delete((Path)OUTSIDE);
	defer
	{
		(void)path::rmtree((Path)GAME);
		(void)path::delete((Path)OUTSIDE);
	}

	path::mkdir((Path)GAME, recursive: true)!!;
	file::save(OUTSIDE, (char[])OUTSIDE_TEXT)!!;

	@body();
}

macro @ok(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the setup script succeeded: %s", result.error);
}

macro String @answer(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the reading script succeeded: %s", result.error);
	return result.value.copy(tmem);
}

// The sentence a script that was refused got, for the checks that are about it.
macro String @refusal(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(!result.ok, "'%s' was allowed", source);
	return result.error.copy(tmem);
}

// Whether a file on disk is a PNG, by its first eight bytes.
fn bool is_png(String path)
{
	char[]? bytes = file::load_temp(path);
	if (catch bytes) return false;
	if (bytes.len < 8) return false;
	foreach (i, c : PNG_MAGIC) if (bytes[i] != c) return false;
	return true;
}

// ============================================================================
// The frame
// ============================================================================

<*
 A shot is a PNG, at the render size, and the report describes the file.

 Every field is checked against something independent: the magic against the
 bytes on disk, the size against `three.renderSize()`, and `bytes` against what
 the filesystem says the file is — so a report assembled from the arguments
 rather than from what happened cannot pass.
*>
fn void a_shot_is_a_png_at_the_render_size() @test
{
	@with_shots()
	{
		@with_gpu_js(; three::JsRuntime* run)
		{
			String said = @answer(run, `
				const scene = new three.Scene();
				scene.background = 0x2060a0;
				const shot = three.screenshot('build/test-shots/one.png');
				const size = three.renderSize();
				return [shot.path, shot.width, shot.height, shot.bytes,
					shot.width === size.width && shot.height === size.height].join(' ');
			`);

			test::@check(said.contains("build/test-shots/one.png"), "the report did not name the file: %s", said);
			test::@check(said.contains("200 150"), "the shot was not the render size: %s", said);
			test::@check(said.ends_with(" true\""), "the report disagreed with renderSize(): %s", said);

			test::@check(is_png("build/test-shots/one.png"), "what was written is not a PNG");

			long? size = path::file_size((Path)"build/test-shots/one.png");
			if (catch size)
			{
				test::@check(false, "the file the report named is not on disk");
				return;
			}
			test::@check(said.contains(string::tformat(" %d ", size)),
				"the reported byte count is not the file's: %s", said);
		};
	};
}

<*
 **The point of the verb.** Two shots at two moments the script chose are two
 different pictures.

 This is what `--screenshot` cannot do: the flag writes the frame the harness
 picked, so a script wanting two images had to arrange for the state of each to
 land on the frame the schedule would capture. Here the script says when, twice,
 in one run and with no animation loop at all.

 Compared as bytes rather than by size, because two PNGs of two flat colours are
 very nearly the same length.
*>
fn void two_shots_in_one_run_are_two_pictures() @test
{
	@with_shots()
	{
		@with_gpu_js(; three::JsRuntime* run)
		{
			@ok(run, `
				const scene = new three.Scene();
				scene.background = 0x2060a0;
				three.screenshot('build/test-shots/blue.png');
				scene.background = 0xa03020;
				three.screenshot('build/test-shots/red.png');
			`);

			char[] blue = file::load_temp("build/test-shots/blue.png")!!;
			char[] red = file::load_temp("build/test-shots/red.png")!!;
			test::@check(blue.len > 0 && red.len > 0, "one of the two shots was not written");
			test::@check((String)blue != (String)red,
				"two shots taken either side of a background change are the same file");
		};
	};
}

<*
 The interface is in the file, because there is one recording path and a
 screenshot goes down it.

 The claim `docs/functions.md` makes about this verb — "what it writes is what
 the window would show" — and the one an agent driving over MCP depends on: a
 panel that is on screen and not in the PNG would make every interface it drew
 invisible to it.

 Checked as "the file changed" rather than by looking for pixels of a panel: the
 UI is drawn after the post chain into the same target, so a frame with one in it
 cannot encode to the same bytes as the frame without.
*>
fn void the_interface_is_in_the_shot() @test
{
	@with_shots()
	{
		@with_gpu_js(; three::JsRuntime* run)
		{
			@ok(run, `
				const scene = new three.Scene();
				scene.background = 0x101418;
				three.screenshot('build/test-shots/bare.png');
				three.ui.set({ type: 'anchored', at: 'top-left', margin: 8,
					child: { type: 'label', text: 'hello', color: 0xffffff } });
				three.screenshot('build/test-shots/panel.png');
			`);

			char[] bare = file::load_temp("build/test-shots/bare.png")!!;
			char[] panel = file::load_temp("build/test-shots/panel.png")!!;
			test::@check((String)bare != (String)panel, "the interface did not reach the file");
		};
	};
}

<*
 A first shot into a folder that is not there yet is the ordinary case.

 `scene.export` and `three.writeText` make their own folder, and this goes
 through the same `make_way_for` they do — so the check is that the third door
 was not given a rule of its own.
*>
fn void a_shot_makes_the_folder_it_names() @test
{
	@with_shots()
	{
		@with_gpu_js(; three::JsRuntime* run)
		{
			@ok(run, `three.screenshot('build/test-shots/deeper/still/here.png');`);
			test::@check(is_png("build/test-shots/deeper/still/here.png"),
				"the shot did not land in a folder it had to make");
		};
	};
}

<*
 No device, no picture, and the sentence says which of the two is missing.

 A runtime with no GPU is a real configuration — `three.render()` and
 `scene.export` both work in one — so this has to be a sentence rather than a
 fault name that reads as a bug in the engine.
*>
fn void a_shot_without_a_device_says_so() @test
{
	@with_js(; three::JsRuntime* run)
	{
		String said = @refusal(run, `three.screenshot('build/test-shots/nope.png');`);
		test::@check(said.contains("GPU device"), "the refusal did not name the device: %s", said);
	};
}

<*
 A path is required, and the refusal comes from the prelude before the host is
 called at all — so it says what the argument is for rather than what the host
 found missing.
*>
fn void a_shot_wants_a_path() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		String said = @refusal(run, `three.screenshot();`);
		test::@check(said.contains("wants a path"), "the refusal did not ask for a path: %s", said);
	};
}

// ============================================================================
// A texture
// ============================================================================

<*
 A texture written to a file and loaded back is the same bytes.

 The whole claim of `texture.save`, and it is stronger than "a PNG appeared":
 `read_pixels` converts nothing and the encode is lossless, so a `DataTexture`
 that goes out through this door and comes back through `three.texture` has to be
 byte-for-byte what the script built. A colour space applied on the way out or
 the way in would show up here as a bent ramp rather than as a wrong-looking
 picture nobody is watching.

 The values are a ramp and its complement rather than a flat colour, so a save
 that wrote one channel over all four, or wrote the rows upside down, cannot
 agree with the original.
*>
fn void a_texture_round_trips_through_a_file() @test
{
	@with_shots()
	{
		@with_gpu_js(; three::JsRuntime* run)
		{
			String said = @answer(run, `
				const px = new Uint8Array(8 * 8 * 4);
				for (let i = 0; i < 64; i++) {
					px[i * 4] = i * 4;
					px[i * 4 + 1] = 255 - i * 4;
					px[i * 4 + 2] = (i * 17) % 256;
					px[i * 4 + 3] = 255;
				}
				const tex = new three.DataTexture(px, 8, 8,
					{ colorSpace: three.LinearSRGBColorSpace, generateMipmaps: false });
				const wrote = tex.save('build/test-shots/ramp.png');

				const back = three.texture('build/test-shots/ramp.png',
					{ colorSpace: three.LinearSRGBColorSpace }).read();
				let worst = 0;
				for (let i = 0; i < px.length; i++) worst = Math.max(worst, Math.abs(back[i] - px[i]));
				return [wrote.width, wrote.height, wrote.bytes > 0, worst].join(' ');
			`);

			test::@check(said.contains("8 8 true 0"),
				"a texture did not survive the round trip through a file: %s", said);
			test::@check(is_png("build/test-shots/ramp.png"), "what was written is not a PNG");
		};
	};
}

<*
 A compressed texture is refused by name, as `read()` refuses one.

 There are no pixels behind a block without a decoder, and the failure that
 matters is the one that does not happen: a quarter of the bytes written into a
 PNG header would produce a file that opens and is wrong. The message names the
 format, so an author knows the file is compressed rather than that the verb is
 broken.
*>
fn void a_compressed_texture_cannot_be_saved() @test
{
	@with_shots()
	{
		@with_gpu_js(; three::JsRuntime* run)
		{
			String said = @refusal(run, `
				const tex = three.texture('test/fixtures/oblong_bc7.ktx2');
				tex.save('build/test-shots/blocks.png');
			`);
			test::@check(said.contains("BC7"), "the refusal did not name the format: %s", said);
			test::@check(!path::exists((Path)"build/test-shots/blocks.png"),
				"a refused save still wrote a file");
		};
	};
}

<*
 A disposed handle names no image, and saving through one says so rather than
 writing whatever took the slot.
*>
fn void a_disposed_texture_cannot_be_saved() @test
{
	@with_shots()
	{
		@with_gpu_js(; three::JsRuntime* run)
		{
			String said = @refusal(run, `
				const tex = new three.DataTexture(new Uint8Array(4 * 4), 2, 2);
				tex.dispose();
				tex.save('build/test-shots/gone.png');
			`);
			test::@check(said.contains("disposed"), "the refusal did not name the dispose: %s", said);
		};
	};
}

// ============================================================================
// The sandbox
// ============================================================================

<*
 Neither image door can climb out of the game directory, and the file next door
 is untouched afterwards.

 The sandbox is `resolve_write`'s — the same call `scene.export` and
 `three.writeText` make — so this is a check that two more doors were not given
 rules of their own. The second half is what makes the first half mean something:
 a refusal that fired after the file was opened would leave the neighbour
 truncated, and the sentence would still read correctly.
*>
fn void neither_image_door_can_climb_out_of_the_game_directory() @test
{
	@with_game()
	{
		@with_gpu_js(; three::JsRuntime* run)
		{
			run.set_assets_root(GAME);

			String[*] attempts = {
				`three.screenshot('../test-shot-outside.png');`,
				`three.screenshot('shots/../../test-shot-outside.png');`,
				`new three.DataTexture(new Uint8Array(4 * 4), 2, 2).save('../test-shot-outside.png');`,
			};
			foreach (attempt : attempts)
			{
				String said = @refusal(run, attempt);
				test::@check(said.contains("climbs out of the assets directory"),
					"'%s' was refused without saying why: %s", attempt, said);
			}

			test::@check(file::load_temp(OUTSIDE)!! == OUTSIDE_TEXT,
				"a refused write reached the file next door");
		};
	};
}

<*
 Inside the game directory both doors work, and a leading `/` is that directory
 rather than the disk's.

 The other half of the check above: the refusals mean something only if the
 ordinary path is the one that lands, and it has to land *under the root* rather
 than wherever the process was started.
*>
fn void an_image_path_is_rooted_at_the_game_directory() @test
{
	@with_game()
	{
		@with_gpu_js(; three::JsRuntime* run)
		{
			run.set_assets_root(GAME);

			@ok(run, `three.screenshot('shots/frame.png');`);
			@ok(run, `new three.DataTexture(new Uint8Array(4 * 4), 2, 2).save('/shots/tex.png');`);

			test::@check(is_png(string::tformat("%s/shots/frame.png", GAME)),
				"the shot did not land under the game directory");
			test::@check(is_png(string::tformat("%s/shots/tex.png", GAME)),
				"an absolute path did not mean the game directory");
		};
	};
}
