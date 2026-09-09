import CPython
import Foundation

/// The interpreter, started on first use.
///
///     try cpy.run("print('hello')")
///
/// Registering extra builtin modules has to happen before CPython starts, so
/// call ``Python/initialize(modules:)`` yourself before touching this.
@MainActor
public let cpy = PyAPI()

/// The embedded interpreter as a value: creating it starts CPython, the way
/// SwiftPy's `py` does for pocketpy.
@MainActor
public struct PyAPI {
    /// A binding as CPython calls it: `(self, args) -> result`, where a nil
    /// return means an exception is set. pocketpy passes `(argc, argv)` and
    /// answers with a Bool, so only the shape of the two differs.
    public typealias CFunction = @convention(c) (PyRef?, PyRef?) -> PyRef?

    init() {
        do {
            try PyRuntime.initialize()
        } catch {
            // Startup only fails when the interpreter is packaged wrong, which
            // no caller can recover from and every later call would trip over.
            fatalError("CPython failed to start: \(error)")
        }
    }

    @inlinable
    public var version: String { PyRuntime.version }

    @inlinable
    public var isInitialized: Bool { PyRuntime.isInitialized }

    /// Runs a block of Python source in `__main__`.
    @inlinable
    public func run(_ source: String) throws(PythonError) {
        try PyRuntime.run(source)
    }

    /// Runs a code object from ``PythonCompiler/compile(_:filename:mode:)``.
    @discardableResult
    @inlinable
    public func execute(
        _ code: PyObject,
        globals: PyObject? = nil,
        locals: PyObject? = nil
    ) throws(PythonError) -> PyObject {
        try PyRuntime.execute(code, globals: globals, locals: locals)
    }

    /// Evaluates a Python expression and returns `str()` of its result.
    @discardableResult
    @inlinable
    public func evaluate(_ expression: String) throws(PythonError) -> String {
        try PyRuntime.evaluate(expression)
    }

    /// Adds a directory to `sys.path`.
    @inlinable
    public func addSearchPath(_ path: String) throws(PythonError) {
        try PyRuntime.addSearchPath(path)
    }

    /// Routes `sys.stdout` and `sys.stderr` to a Swift closure.
    @inlinable
    public func redirectOutput(to hook: ((String) -> Void)?) throws(PythonError) {
        try PyRuntime.redirectOutput(to: hook)
    }
}

public extension PyAPI {
    /// The module `name`, importing it the way `import name` does.
    func module(_ name: String) -> PyModule? {
        PyModule(name)
    }

    /// A new, empty native module, registered so Python can import it.
    func newmodule(_ name: String) -> PyModule? {
        PyModule(creating: name)
    }

    var main: PyModule { PyModule("__main__")! }

    /// Runs a binding body, turning a thrown error into a raised Python
    /// exception. The counterpart of SwiftPy's `PyAPI.return`.
    ///
    /// The body runs on the main actor: CPython only ever calls back on the
    /// thread that holds the GIL, which is the one the interpreter started on.
    nonisolated static func `return`(
        _ body: @MainActor () throws -> (any PythonConvertible)?
    ) -> PyRef? {
        nonisolated(unsafe) var result: PyRef?
        MainActor.assumeIsolated {
            do {
                guard let value = try body() else {
                    result = Py_GetConstant(UInt32(Py_CONSTANT_NONE))
                    return
                }
                // The caller owns what it returns, and the box would release
                // this on the way out.
                let object = try value.toPython()
                Py_IncRef(object.reference)
                result = object.reference
            } catch let error as PythonError {
                raise(error)
            } catch {
                raise(.RuntimeError("\(error)"))
            }
        }
        return result
    }

    /// Sets `error` as the raised exception.
    static func raise(_ error: PythonError) {
        PyErr_SetString(PyRuntime.exceptionType(named: error.type), error.value)
    }
}
