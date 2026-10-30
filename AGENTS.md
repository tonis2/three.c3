`plan.md` is the task list and holds nothing else.

Dont reference plan.md in code comments, code comments are for human users, keep code comments short and easy to read.

Before running C3 tests, close all three instances.

For engine changes, use:

Test only with `c3c test --test-noleak` # while working or `c3c tes --test-filter <suite>`


c3c build --safe=no -O3    # the fast one: no contracts, optimised

There is no -D DEBUG. Validation layers and debug logging are `./build/three --debug`
at run time, and the suite asks for the layer itself, so every build has both.
