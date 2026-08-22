Close three instance after working on it, so on next session it doesent clash with the scene rendering.

For testing use

c3c build --trust=full
c3c test --trust=full --test-noleak     # while working
c3c test --trust=full                   # with leak tracking; much slower
c3c test --trust=full --test-filter <suite>

`-D DEBUG` compiles in the Vulkan validation layers and `@debug_log`; without it
they are not in the binary at all, and `--mcp` no longer implies `--validate`.
The suite passes either way, but the validation half of it only runs with the
flag — `src/debug.c3` has the argument and the measurements.

c3c build --trust=full -D DEBUG         # validation layers + debug logging
c3c test  --trust=full -D DEBUG         # and the validation half of the suite
c3c build --trust=full --safe=no -O3    # the fast one: no contracts, optimised
