import CPython
import Foundation

/// The interpreter, started on first use.
///
///     try cpy.run("print('hello')")
///
/// Registering extra builtin modules has to happen before CPython starts, so
/// call ``Python/initialize(modules:)`` yourself before touching this.
@MainActor
public let cpy = PythonAPI()

/// The embedded interpreter as a value: creating it starts CPython, the way
/// `PyAPI` does for pocketpy.
@MainActor
public struct PythonAPI {
    init() {
        do {
            try Python.initialize()
        } catch {
            // Startup only fails when the interpreter is packaged wrong, which
            // no caller can recover from and every later call would trip over.
            fatalError("CPython failed to start: \(error)")
        }
    }

    @inlinable
    public var version: String { Python.version }

    @inlinable
    public var isInitialized: Bool { Python.isInitialized }

    /// Runs a block of Python source in `__main__`.
    @inlinable
    public func run(_ source: String) throws(PythonError) {
        try Python.run(source)
    }

    /// Runs a code object from ``PythonCompiler/compile(_:filename:mode:)``.
    @discardableResult
    @inlinable
    public func execute(
        _ code: PyObject,
        globals: PyObject? = nil,
        locals: PyObject? = nil
    ) throws(PythonError) -> PyObject {
        try Python.execute(code, globals: globals, locals: locals)
    }

    /// Evaluates a Python expression and returns `str()` of its result.
    @discardableResult
    @inlinable
    public func evaluate(_ expression: String) throws(PythonError) -> String {
        try Python.evaluate(expression)
    }

    /// The module `name`, importing it the way `import name` does.
    @inlinable
    public func module(_ name: String) throws(PythonError) -> PyObject {
        try Python.module(name)
    }

    /// Adds a directory to `sys.path`.
    @inlinable
    public func addSearchPath(_ path: String) throws(PythonError) {
        try Python.addSearchPath(path)
    }

    /// Routes `sys.stdout` and `sys.stderr` to a Swift closure.
    @inlinable
    public func redirectOutput(to hook: ((String) -> Void)?) throws(PythonError) {
        try Python.redirectOutput(to: hook)
    }
}
