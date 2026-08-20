Close three instance after working on it, so on next session it doesent clash with the scene rendering.

For testing use

c3c build --trust=full
c3c test --trust=full --test-noleak     # while working
c3c test --trust=full                   # with leak tracking; much slower
c3c test --trust=full --test-filter <suite>