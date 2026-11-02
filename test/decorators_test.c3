<*
 The decorators for game classes — `src/js/prelude/decorators.js`.

	`c3c test --trust=full --test-noleak --test-filter three_tests::decorators`

 Each test declares a class the way a game would, runs a few ticks with a
 hand-fed clock, and reads back what the decorated methods did.
*>
module three_tests::decorators;

import three;
import three_tests::device;
import vk;
import std::core::test;

macro @with_gpu_js(; @body(three::JsRuntime* run))
{
	three::Renderer* renderer = device::borrow(200, 150);
	defer device::release();

	three::JsRuntime runtime;
	runtime.open(&renderer.pass, renderer)!!;
	defer runtime.close();

	@body(&runtime);
}

macro String @value(three::JsRuntime* run, String source, String what)
{
	three::RunResult result = run.run(source);
	defer result.free();
	test::@check(result.ok, "%s: %s", what, result.error);
	return result.value.copy(tmem);
}

macro String @refusal(three::JsRuntime* run, String source)
{
	three::RunResult result = run.run(source);
	defer result.free();
	return result.ok ? "".copy(tmem) : result.error.copy(tmem);
}

macro @ticks(three::JsRuntime* run, int frames)
{
	static double at;
	for (int i = 0; i < frames; i++)
	{
		at += 16.0;
		run.tick(at);
	}
}

fn void entity_methods_become_class_systems() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@value(run, `
			globalThis.log = [];
			globalThis.G = { on: true };
			class Bug extends three.Entity {
				static capacity = 4;
				constructor(n) { super(); this.n = n; }
				@three.systems.frame({ when: () => G.on })
				walk(dt) { log.push('walk' + this.n); }
				@three.systems.frame
				static flock(dt) { log.push('flock' + Bug.count); }
			}
			globalThis.Bug = Bug;
			Bug.spawn(1); Bug.spawn(2);
		`, "declaring and spawning");
		@ticks(run, 1);
		// The class's own static system first, then each entity's.
		test::eq(@value(run, `return log.join(' ')`, "reading"), `"flock2 walk1 walk2"`);
		@value(run, `log.length = 0; G.on = false;`, "turning walking off");
		@ticks(run, 1);
		test::eq(@value(run, `return log.join(' ')`, "reading"), `"flock2"`);
		// Named after the class, and disposed with it.
		test::eq(@value(run, `return ['Bug.walk', 'Bug.flock'].every(n => three.systems.list().some(s => s.name === n))`, "names"), "true");
		test::eq(@value(run, `Bug.dispose(); return three.systems.list().some(s => s.name === 'Bug.walk')`, "dispose"), "false");
	};
}

fn void the_entity_decorator_registers_at_once() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@value(run, `
			globalThis.ticks = 0;
			@three.entity({ speed: 1, kind: 'bees' })
			class Swarm extends three.Entity {
				static speed = 2;
				@three.systems.frame static pulse(dt) { ticks++; }
			}
			globalThis.Swarm = Swarm;
		`, "declaring");
		@ticks(run, 2);
		// Registered with no spawn at all, and the static field won over the option.
		test::eq(@value(run, `return [ticks, Swarm.speed, Swarm.kind, Swarm.count].join()`, "reading"), `"2,2,bees,0"`);
		assert(@refusal(run, `@three.entity() class Loose {}`).starts_with("TypeError: @three.entity goes on a class that extends three.Entity — Loose does not"));
	};
}

fn void plain_classes_register_statics_now_and_instances_when_made() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@value(run, `
			globalThis.seen = [];
			class Game {
				constructor(name) { this.name = name; }
				@three.systems.frame tick(dt) { seen.push(this.name); }
				@three.systems.frame static clock(dt) { seen.push('clock'); }
			}
			new Game('first');
			new Game('second');
		`, "declaring");
		@ticks(run, 1);
		// The latest instance owns the system's name.
		test::eq(@value(run, `return seen.sort().join(' ')`, "reading"), `"clock second"`);
	};
}

fn void keys_bind_and_list_what_they_do() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		@value(run, `
			globalThis.pressed = [];
			class Controls {
				@three.key('space', 'jump') jump() { pressed.push('jump'); }
				@three.key('p') static pause() { pressed.push('pause'); }
			}
			new Controls();
			three.input.press('space');
			three.input.press('p');
		`, "declaring");
		@ticks(run, 1);
		test::eq(@value(run, `return pressed.sort().join(' ')`, "reading"), `"jump pause"`);
		test::eq(@value(run, `return three.keys()`, "the table"), `{"p":"pause","space":"jump"}`);
	};
}

fn void owned_fields_are_disposed_with_their_entity() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		test::eq(@value(run, `
			const disposed = [];
			class Thing { constructor(n) { this.n = n; } dispose() { disposed.push(this.n); } }
			class Crate extends three.Entity {
				@three.owned lid = new Thing('lid');
				@three.owned timer = three.cooldown(0.5);
				@three.owned nothing = null;
			}
			const a = Crate.spawn();
			Crate.spawn();
			a.remove();
			const one = disposed.join();
			Crate.clear();
			return one + '|' + disposed.join();
		`, "disposing"), `"lid|lid,lid"`);
	};
}

fn void decorator_misuse_is_explained() @test
{
	@with_gpu_js(; three::JsRuntime* run)
	{
		assert(@refusal(run, `class A { @three.systems.step x = 1; }`).starts_with("TypeError: @three.systems.step goes on a method — the method is the system — not on a field"));
		assert(@refusal(run, `class A { @three.systems.frame({ when: 3 }) f() {} }`).starts_with("TypeError: @three.systems.frame: when is a function answering whether the system runs this tick"));
		assert(@refusal(run, `class A { @three.owned m() {} }`).starts_with("TypeError: @three.owned goes on a field holding something to dispose, not on a method"));
		// The registry's own verbs still take a name.
		test::eq(@value(run, `return three.systems.frame('plain', () => {})`, "a named system"), `"plain"`);
	};
}
