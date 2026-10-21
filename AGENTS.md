`plan.md` is the task list and holds nothing else.

Dont reference plan.md in code comments, code comments are for human users, keep code comments short and easy to read.

Run C3 tests only after changing engine code. JavaScript scripts and examples
are not covered by `c3c test`; when a change is limited to JavaScript, verify it
by running that script through the engine instead. Use a headless screenshot
when its rendered output matters.

Before running C3 tests, close all three instances.

For engine changes, use:

c3c build
c3c test --test-noleak # while working
c3c test  # the one that has to pass before done
c3c test --test-filter <suite>

When running full tests, only use `c3c test`.

c3c build --safe=no -O1    # the fast one: no contracts, optimised

There is no -D DEBUG. Validation layers and debug logging are `./build/three --debug`
at run time, and the suite asks for the layer itself, so every build has both.
