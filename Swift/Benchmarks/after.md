# After the Python actor

Same machine and commands as `before.md`. Main holds the GIL while its run
loop is awake; `PythonActor` runs cells on its own thread while main sleeps.

| Case | Before | After |
| --- | --- | --- |
| compute cell (400k iterations), on main | 29–32 ms | 29 ms |
| compute cell on the actor | — | 29 ms |
| 100k binding calls, cell on main | 32–36 ms | 34–36 ms |
| 100k binding calls, cell on the actor | — | 890–905 ms |
| 100k attribute reads from main | 22–26 ms | 16 ms |
| 100k method calls from main | 45–47 ms | 25 ms |
| update latency under load, p50 | 0.4–0.6 ms | 0.8–1.1 ms |
| update latency under load, p99 | 1.7–2.1 ms | 1.8 ms |
| update latency under load, max | 999 ms | 2.4–2.7 ms |
| update samples during the 1 s cell | 193–194, then blocked | 915–918 |
| 10k awaits (`_swiftpy.sleep(0)`) | 108 ms | 264–269 ms |
| 1M boxes | 78 ms | 24 ms |

What moved:

- The latency case is the point of the change: `update` from main answers
  within the switch interval throughout the cell instead of waiting for it
  to finish. About 920 calls landed during the one-second cell.
- A binding called from a cell on the actor costs a hop to main and back,
  about 9 µs. A cell that calls bindings in a tight loop pays it every time;
  a binding that touches no main-actor state can be registered without the
  hop (the source finder is), which is the escape hatch for a hot one.
- Reads and calls from main got faster: a `PyObject` box no longer has an
  isolated `deinit`, and a box dropped with the GIL in hand is released on
  the spot.
- An await round trip now crosses to the actor and back, so the async cell
  takes about 2.5× longer per await; each await is still ~25 µs.

## SwiftPy (`SWIFTPY_BENCH=1 swift test -c release --filter BenchmarkTests`)

| Case | Before | After |
| --- | --- | --- |
| 100k binding calls (`PyBind.function`) | 329 ms | 2456 ms |
| update latency under load, p50 / p99 / max | 0.8 / 1.4 / 999 ms | 1.0 / 1.8 / 2.5 ms |
| update samples during the 1 s cell | 194 | 934 |
| 10k awaits (`asyncio.sleep(0)`) | 81 ms | 216 ms |

The end-to-end binding call is ~24 µs: the hop, plus the execution context
carried across it (two task-local bindings) and the line tracer's lock.
