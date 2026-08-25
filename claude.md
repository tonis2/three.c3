`plan.md` is the task list and holds nothing else. `notes.md` holds how things
work, why they were decided that way, and the traps that have already cost a
session. Both use the same section numbers, so a source comment citing §N
resolves against whichever file still has material under it. **When something is
finished, delete its entry from `plan.md`** — into `notes.md` if it explains
something, into `git log` if it does not.

Before running C3 tests, close all three instances

For testing use

c3c build --trust=full
c3c test --trust=full --test-noleak     # while working
c3c test --trust=full -D DEBUG          # the one that has to pass before done
c3c test --trust=full --test-filter <suite>

**Run the `-D DEBUG` suite once. Do not run `c3c test --trust=full` as well.**
Leak tracking is on in both — `--test-noleak` is what turns it off, not the
build flag — so the `-D DEBUG` run already covers everything the plain run
covers and adds the validation layers on top of it. Running both is a second
build and a second full suite for one thing: the `$if !DEBUG_BUILD` branches in
`gpu/device.c3`, which are a `return false` and a diagnostic line that nothing
asserts on.

`-D DEBUG` compiles in the Vulkan validation layers and `@debug_log`; without it
they are not in the binary at all. It is the only switch for them — there is no
`--validate` on the command line, and a `-D DEBUG` build always runs the layers.
The suite passes either way, but the validation half of it only runs with the
flag — `src/debug.c3` has the argument and the measurements.

c3c build --trust=full -D DEBUG         # validation layers + debug logging
c3c build --trust=full --safe=no -O3    # the fast one: no contracts, optimised
