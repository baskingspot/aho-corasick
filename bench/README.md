# Benchmarks

`just bench` runs the testingx suite in `src/bench_impl.zig`. The suite builds
ReleaseFast against a ReleaseFast copy of the library. Pin it to one core so
the numbers settle:

```sh
taskset -c 3 just bench -- --benchtime=200ms --count=3
```

The dictionary is 1,000 generated words of 4 to 10 lowercase letters. `Dense`
is 64 KiB of those words separated by spaces; it exercises the failure links
and the outputs. `Miss` is 64 KiB of digits and punctuation, so every byte
takes the no-class path. `ByteSum` is the floor, a plain loop over the miss
text. `NextState` calls the transition function without the iterator, which
separates the automaton from the search loop.

`just bench-smoke` runs every row once in CI. It proves the suite builds and
runs; it does not measure.

## Local baseline

These are medians of three runs on the aarch64 Linux box, Zig 0.17,
ReleaseFast, with the process pinned to one core. They are local numbers, not
claims.

| Row                     | Time    | Throughput |
| ----------------------- | ------- | ---------- |
| `ByteSum`               | 10.1 µs | 6.5 GB/s   |
| `NextStateMiss`         | 26.0 µs | 2.5 GB/s   |
| `ComptimeFindMiss`      | 77.4 µs | 847 MB/s   |
| `ComptimeIsMatchMiss`   | 76.9 µs | 853 MB/s   |
| `ComptimeFindIterDense` | 317 µs  | 207 MB/s   |
| `LeftmostFindIterDense` | 273 µs  | 240 MB/s   |
| `RuntimeFindIterDense`  | 532 µs  | 123 MB/s   |
| `RuntimeFindMiss`       | 74.7 µs | 877 MB/s   |
| `OverlappingSmall`      | 77.1 µs | 372 MB/s   |

The miss rows are faster than the dense rows because no pattern byte occurs in
the haystack; each byte takes one class lookup and returns to the root. The
dense rows pay the failure walks and report a match for every word.

The runtime automaton is slower than the comptime one because its state ids and
masks are wider: `u32` states and a fixed 256-bit mask (32 bytes per state)
against the comptime narrow state and 26-bit mask (4 bytes). The next
compression experiment is a runtime mask with one word per 64 alphabet classes.

SIMD does not vectorize the state machine itself; each byte depends on the
previous state. The lever is a prefilter before the automaton, such as Teddy
over a set of pattern prefixes, which can skip a haystack that cannot start a
match. That is a separate change; this suite gives it a baseline.
