`plan.md` is the task list and holds nothing else. `notes.md` holds how things
work, why they were decided that way, and the traps that have already cost a
session. Both use the same section numbers, so a source comment citing §N
resolves against whichever file still has material under it. **When something is
finished, delete its entry from `plan.md`** — into `notes.md` if it explains
something, into `git log` if it does not.

Dont reference plan.md in code comments, code comments are for human users, keep code comments short and easy to read.

Before running C3 tests, close all three instances

For testing use

c3c build --trust=full
c3c test --trust=full --test-noleak # while working
c3c test --trust=full -D DEBUG   # the one that has to pass before done
c3c test --trust=full --test-filter <suite>

When running full tests only use c3c test --trust=full -D DEBUG

c3c build --trust=full -D DEBUG         # validation layers + debug logging
c3c build --trust=full --safe=no -O3    # the fast one: no contracts, optimised
