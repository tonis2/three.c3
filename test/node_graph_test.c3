<*
 A node editor from JavaScript: `three.ui.NodeGraph` mounted by a widget, driven
 with the scripted pointer, reporting through the named handlers.

	`c3c test --trust=full --test-noleak --test-filter three_tests::node_graph`

 What is being checked is the round trip the studio depends on: the graph tells
 the script, the script changes its data and renders again, and the change
 lands as a patch — the cards move, the wire appears — without anything else
 being rebuilt.
*>
module three_tests::node_graph;

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

// Two nodes: A's output at (10 + 220, 10 + 41) and B's input at (260, 51) —
// a card is 220 wide, and its first port row is centred 41 below its top.
const String GRAPH = `
	const { NodeGraph, NodeCard, TextField } = three.ui;
	globalThis.state = {
		nodes: [{ pos: [10, 10], title: 'A' }, { pos: [260, 10], title: 'B' }],
		ports: [{ node: 0, output: true, label: 'out', color: 0xff8800 }, { node: 1, label: 'in', color: 0xff8800 }],
		wires: [],
		refuse: false,
		selected: -2,
		moves: 0,
		contexts: 0,
	};
	class Graph extends three.Widget {
		render() {
			const s = globalThis.state;
			return new NodeGraph({
				key: 'graph',
				nodes: s.nodes, ports: s.ports, wires: s.wires,
				onSelect: (node, mode) => {
					s.selected = node;
					s.nodes = s.nodes.map((n, i) => ({ ...n, selected: mode === 'replace' ? i === node : n.selected || i === node }));
				},
				onMove: (dx, dy, done) => {
					s.moves++;
					s.nodes = s.nodes.map(n => n.selected ? { ...n, pos: [n.pos[0] + dx, n.pos[1] + dy] } : n);
				},
				canConnect: (from, to) => !s.refuse,
				onConnect: (from, to) => { s.wires = [...s.wires, { from, to }]; },
				onContext: (target, index) => { s.contexts++; s.lastContext = target + ':' + index; },
			},
				new NodeCard(0, new TextField({ key: 'field' })),
				new NodeCard(1));
		}
	}
	globalThis.graph = new Graph();
	globalThis.graph.mount();
`;

macro drag(three::JsRuntime* run, three::Renderer* renderer, String from, String to, double t)
{
	@ok(run, string::tformat("three.input.movePointer(%s); ", from));
	run.tick(t);
	@ok(run, `three.input.pressButton(0);`);
	run.tick(t + 16);
	@ok(run, string::tformat("three.input.movePointer(%s);", to));
	run.tick(t + 32);
	@ok(run, string::tformat("three.input.movePointer(%s);", to));
	run.tick(t + 48);
	@ok(run, `three.input.releaseButton(0);`);
	run.tick(t + 64);
	laid_out(renderer);
}

fn void a_wire_dragged_between_ports_reaches_the_script() @test
{
	@with_panel_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		@ok(run, GRAPH);
		run.tick(0);
		laid_out(renderer);

		drag(run, renderer, "231, 51", "261, 51", 16);
		String wires = @answer(run, `return JSON.stringify(globalThis.state.wires);`);
		defer wires.free(mem);
		test::@check(wires == `"[{\"from\":0,\"to\":1}]"`, "the wire came over as %s", wires);

		// And refused when the script says no: nothing connects.
		@ok(run, `globalThis.state.wires = []; globalThis.state.refuse = true; globalThis.graph.update();`);
		run.tick(200);
		laid_out(renderer);
		drag(run, renderer, "231, 51", "261, 51", 216);
		String refused = @answer(run, `return globalThis.state.wires.length;`);
		defer refused.free(mem);
		test::@check(refused == "0", "a refused wire connected anyway: %s", refused);
	};
}

fn void dragging_a_card_moves_it_by_patch() @test
{
	@with_panel_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		@ok(run, GRAPH);
		run.tick(0);
		laid_out(renderer);

		drag(run, renderer, "60, 20", "100, 50", 16);
		String moved = @answer(run, `const s = globalThis.state; return [s.selected, s.moves > 0, s.nodes[0].pos.join('/')].join(',');`);
		defer moved.free(mem);
		test::@check(moved == `"0,true,50/40"`, "the card's press and drag came over as %s", moved);

		// The card followed: a press where it now is, not where it was, picks it.
		@ok(run, `globalThis.state.selected = -2;`);
		drag(run, renderer, "95, 45", "95, 45", 116);
		String again = @answer(run, `return globalThis.state.selected;`);
		defer again.free(mem);
		test::@check(again == "0", "the moved card was not where it was drawn: %s", again);
	};
}

fn void a_right_click_names_what_it_landed_on() @test
{
	@with_panel_js(; three::Renderer* renderer, three::JsRuntime* run)
	{
		@ok(run, GRAPH);
		run.tick(0);
		laid_out(renderer);

		@ok(run, `three.input.movePointer(300, 20);`);
		run.tick(16);
		@ok(run, `three.input.pressButton(1);`);
		run.tick(32);
		@ok(run, `three.input.releaseButton(1);`);
		run.tick(48);
		String hit = @answer(run, `return globalThis.state.lastContext;`);
		defer hit.free(mem);
		test::@check(hit == `"node:1"`, "the right click landed on %s", hit);
	};
}
