<*
 The outliner's `tree` from JavaScript: rows that carry an icon, a highlight and
 an eye, a style, and the three things it reports — a pick with the modifier
 keys, the chevron, and the eye column — through the named handlers.

	`c3c test --trust=full --test-noleak --test-filter three_tests::tree`
*>
module three_tests::tree;

import three;
import three_tests::device;
import image;
import std::core::test;

macro @with_panel_js(; @body(three::Renderer* renderer, three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(520, 400);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(renderer, &runtime);
}

macro @ok(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the script succeeded: %s", result.error);
}

macro String @answer(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "the reading script succeeded: %s", result.error);
	return result.value.copy(mem);
}

fn void laid_out(three::Renderer* renderer)
{
	image::Image shot = renderer.capture()!!;
	shot.free();
}

// Rows 24 high, so row 1's middle is y 36, and a 24-wide eye column against the
// right edge of a 520-wide panel, 6 in: its centre is x 502.
const String OUTLINER = `
	const { Tree } = three.ui;
	globalThis.log = [];
	class Outliner extends three.Widget {
		render() {
			return new Tree([
				{ label: 'Scene', depth: 0, expandable: true, expanded: true, icon: 'scene', toggles: [{ icon: 'eye', on: true }] },
				{ label: 'mesh', depth: 1, icon: 'mesh', highlighted: true, toggles: [{ icon: 'eye', on: false }] },
				{ label: 'lamp', depth: 1, icon: 'light', toggles: [{ icon: 'eye', on: true }] },
			], 9, (row, mods) => globalThis.log.push('select ' + row + ' ' + mods), {
				key: 'tree',
				style: { rowHeight: 24, indent: 16, iconSize: 14, toggleWidth: 24, padding: 6 },
				onToggle: row => globalThis.log.push('chevron ' + row),
				onRowToggle: (row, column) => globalThis.log.push('eye ' + row + ' ' + column),
			});
		}
	}
	globalThis.outliner = new Outliner();
	globalThis.outliner.mount();
`;

macro click(three::JsRuntime* run, three::Renderer* renderer, String at, double t)
{
	@ok(run, string::tformat("three.input.movePointer(%s);", at));
	run.tick(t);
	@ok(run, `three.input.pressButton(0);`);
	run.tick(t + 16);
	@ok(run, `three.input.releaseButton(0);`);
	run.tick(t + 32);
	laid_out(renderer);
}

<*
 A click on a row reports the row and the modifier bits, a click on the eye
 column reports the row and the column and picks nothing, and a click on the
 chevron of a row that opens reports that alone.
*>
fn void a_tree_reports_picks_eyes_and_chevrons() @test
{
	@with_panel_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		@ok(run, OUTLINER);
		run.tick(0);
		laid_out(renderer);

		click(run, renderer, "200, 36", 16);
		@ok(run, `three.input.press('shift');`);
		run.tick(60);
		click(run, renderer, "200, 60", 80);
		@ok(run, `three.input.release('shift');`);
		click(run, renderer, "502, 36", 160);
		click(run, renderer, "14, 12", 240);

		String log = @answer(run, `return globalThis.log.join('|');`);
		defer log.free(mem);
		test::@check(
			log == `"select 1 0|select 2 1|eye 1 0|chevron 0"`,
			"the handlers heard %s", log
		);
	};
}

<*
 A row naming an icon the host does not have is refused by name, in the script
 that wrote it, rather than drawn blank.
*>
fn void an_unknown_icon_is_refused_by_name() @test
{
	@with_panel_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		three::RunResult result = run.run(`
			three.ui.set({ type: 'tree', rows: [{ label: 'x', icon: 'no_such_icon' }] });
		`);
		defer result.free();
		test::@check(!result.ok && result.error.contains("no_such_icon"), "an unknown icon was accepted: %s", result.error);
	};
}

<*
 `three.ui.icon` adds an icon a row can then name, and answers its number.
*>
fn void a_script_can_add_an_icon() @test
{
	@with_panel_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		String ids = @answer(run, `
			const id = three.ui.icon('crate', '<svg xmlns="http://www.w3.org/2000/svg" viewBox="-9 -9 18 18"><rect x="-5" y="-5" width="10" height="10"/></svg>', { color: 0xf0a040 });
			three.ui.set({ type: 'tree', rows: [{ label: 'x', icon: 'crate' }] });
			return id;
		`);
		defer ids.free(mem);
		test::@check(ids == "9", "the first added icon is number 9, after the 8 built in, got %s", ids);
	};
}
