# Before the Python actor

`swift build -c release --product pybench && .build/release/pybench`, median
of 5 runs, Apple Silicon, macOS 27. The interpreter holds the GIL on the main
thread and every cell runs there.

| Case | Time |
| --- | --- |
| compute cell (400k iterations) | 29–32 ms |
| 100k binding calls | 32–36 ms |
| 100k attribute reads from main | 22–26 ms |
| 100k method calls from main | 45–47 ms |
| update latency under load, p50 | 0.4–0.6 ms |
| update latency under load, p99 | 1.7–2.1 ms |
| update latency under load, max | 999 ms |
| update samples during the 1 s cell | 193–194 (all before the cell got the actor) |
| 10k awaits (`_swiftpy.sleep(0)`) | 108 ms |
| 1M boxes | 78 ms |

The latency case shows the problem: the cell takes the main actor for its
whole second, so one `update` call waits 999 ms and nothing runs meanwhile.

## SwiftPy (`SWIFTPY_BENCH=1 swift test -c release --filter BenchmarkTests`)

Through `Interpreter.execute`: task-locals, line tracer and output routing on.

| Case | Time |
| --- | --- |
| 100k binding calls (`PyBind.function`) | 329 ms |
| update latency under load, p50 / p99 / max | 0.8 / 1.4 / 999 ms |
| update samples during the 1 s cell | 194 |
| 10k awaits (`asyncio.sleep(0)`) | 81 ms |
