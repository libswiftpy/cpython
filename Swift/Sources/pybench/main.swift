import Foundation
import Python
import CPython

typealias PyObject = Python.PyObject

// pybench — timings for the paths the Python actor work changes. Each case
// prints the median of five runs; see Swift/Benchmarks/.

@MainActor
func median(of samples: [Duration]) -> Duration {
    let sorted = samples.sorted()
    return sorted[sorted.count / 2]
}

@MainActor
func measure(_ name: String, runs: Int = 5, _ body: () throws -> Void) rethrows {
    var samples: [Duration] = []
    let clock = ContinuousClock()
    for _ in 0..<runs {
        let start = clock.now
        try body()
        samples.append(start.duration(to: clock.now))
    }
    report(name, median(of: samples))
}

@MainActor
func measure(_ name: String, runs: Int = 5, _ body: () async throws -> Void) async rethrows {
    var samples: [Duration] = []
    let clock = ContinuousClock()
    for _ in 0..<runs {
        let start = clock.now
        try await body()
        samples.append(start.duration(to: clock.now))
    }
    report(name, median(of: samples))
}

func report(_ name: String, _ duration: Duration) {
    let milliseconds = Double(duration.components.seconds) * 1000
        + Double(duration.components.attoseconds) / 1e15
    print("\(name): \(String(format: "%.2f", milliseconds)) ms")
}

@MainActor
func compile(_ source: String) throws -> PyObject {
    try PythonCompiler.compile(source, filename: "<bench>")
}

@MainActor
func run() async throws {
    print("CPython \(py.version)")

    // A Swift-bound function and a Swift-bound type with a method, the way a
    // host binds them.
    let module = py.newmodule("bench")!
    module.def("touch(value: int) -> int") { _, args in
        PyAPI.return {
            guard let first = PyTuple_GetItem(args, 0) else { return 0 }
            return try Int.cast(first) + 1
        }
    }

    try py.run("""
    import bench

    class Component:
        def __init__(self):
            self.ticks = 0
            self.value = 3

        def update(self, dt):
            self.ticks += 1
            return dt * 2

    component = Component()
    """)
    let component = py.main.component!

    // 1. Compute cell: the interpreter on its own.
    let compute = try compile("""
    total = 0
    for i in range(400_000):
        total += i * i
    """)
    try measure("compute cell") { try py.execute(compute) }

    // 2. Binding calls: Python calling into Swift.
    let bindings = try compile("""
    for i in range(100_000):
        bench.touch(i)
    """)
    try measure("100k binding calls") { try py.execute(bindings) }

    // 3. PyObject from main: attribute reads and method calls with Python idle.
    try measure("100k attribute reads from main") {
        for _ in 0..<100_000 {
            let _: Int? = component.value
        }
    }
    try measure("100k method calls from main") {
        for _ in 0..<100_000 {
            try component.update?(0.3)
        }
    }

    // 4. Main-actor latency while a cell runs: how long `update` waits.
    let busy = try compile("""
    import time
    deadline = time.monotonic() + 1.0
    n = 0
    while time.monotonic() < deadline:
        n += 1
    """)
    // Latency is measured from when the loop meant to call `update` (a
    // 1 ms cadence) to when the call returned, so waiting for the actor and
    // waiting for the GIL both count.
    var latencies: [Duration] = []
    let clock = ContinuousClock()
    let cell = Task { @MainActor in
        try py.execute(busy)
    }
    let end = clock.now + .seconds(1.2)
    var wake = clock.now + .milliseconds(1)
    while wake < end {
        try await Task.sleep(until: wake)
        try component.update?(0.3)
        latencies.append(wake.duration(to: clock.now))
        wake = max(wake + .milliseconds(1), clock.now)
    }
    _ = try await cell.value
    let sorted = latencies.sorted()
    report("update latency under load p50", sorted[sorted.count / 2])
    report("update latency under load p99", sorted[sorted.count * 99 / 100])
    report("update latency under load max", sorted[sorted.count - 1])
    print("update samples during the 1 s cell: \(latencies.count)")

    // 5. Async cell: the coroutine driver round trip.
    let asyncCell = try compile("""
    import _swiftpy
    for i in range(10_000):
        await _swiftpy.sleep(0)
    """)
    try await measure("10k awaits") {
        let coroutine = try py.execute(asyncCell)
        try await PyRuntime.drive(coroutine)
    }

    // 6. Box churn: PyObject boxes made and dropped on main.
    try measure("1M boxes") {
        for _ in 0..<1_000_000 {
            _ = PyObject.none
        }
    }
}

try await run()
PyRuntime.finalize()
