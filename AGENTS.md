`plan.md` is the task list and holds nothing else. It is a local note: gitignored, never
committed, and absent from a fresh clone. The same goes for a game's `gameplan.md`.

Don't reference `plan.md` in code, comments, docs or commit messages. Comments are for the people
reading the code: keep them short and easy to read.

Close every running `three` before running the C3 tests.

While working on the engine, test without the leak checker:

    c3c test --test-noleak                         # the whole suite
    c3c test --test-noleak --test-filter <name>    # only the tests that match

    c3c build three                                # the engine, contracts checked
    c3c build --safe=no -O3                        # the fast one: no contracts, optimised

There is no -D DEBUG. Validation layers and debug logging are `./build/three --debug` at run time,
and the suite asks for the layer itself, so every build has both.

Tabletop Siege, the VR game, lives in its own repo beside this one (`../tabletop-siege`). Game work
goes there; engine fixes it turns up go here.
