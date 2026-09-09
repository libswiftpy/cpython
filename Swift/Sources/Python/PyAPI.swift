import CPython
import Foundation

/// The interpreter, started on first use.
///
///     try cpy.run("print('hello')")
///
/// Registering extra builtin modules has to happen before CPython starts, so
/// call ``Python/initialize(modules:)`` yourself before touching this.
@MainActor
public let py = PyAPI()

/// The older spelling, kept so existing call sites still read.
@MainActor
public let cpy = py

/// The embedded interpreter as a value: creating it starts CPython, the way
/// SwiftPy's `py` does for pocketpy.
@MainActor
public struct PyAPI {
    /// A binding as CPython calls it: `(self, args) -> result`, where a nil
    /// return means an exception is set. pocketpy passes `(argc, argv)` and
    /// answers with a Bool, so only the shape of the two differs.
    public typealias CFunction = @convention(c) (PyRef?, PyRef?) -> PyRef?

    /// The spellings SwiftPy's bindings use for a reference and what it points
    /// at. pocketpy names a tagged value here; CPython an object header.
    public typealias Value = CPython.PyObject
    public typealias Reference = PyRef

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
    /// Takes `Any?` rather than a convertible: a bound getter reads whatever
    /// the Swift property holds, and what is not convertible goes to the host's
    /// box.
    nonisolated static func `return`(_ body: @MainActor () throws -> Any?) -> PyRef? {
        var result: GILBound<CPython.PyObject>?
        MainActor.assumeIsolated {
            do {
                guard let value = try body() else {
                    result = GILBound(Py_GetConstant(UInt32(Py_CONSTANT_NONE)))
                    return
                }

                let object: PyObject
                switch value {
                case let convertible as PythonConvertible:
                    object = try convertible.toPython()
                default:
                    guard let boxed = PyBridge.box?(value) else {
                        throw PythonError.TypeError("Cannot convert \(type(of: value)) to Python")
                    }
                    object = boxed
                }

                // The caller owns what it returns, and the box would release
                // this on the way out.
                Py_IncRef(object.reference)
                result = GILBound(object.reference)
            } catch let error as PythonError {
                raise(error)
            } catch {
                raise(.RuntimeError("\(error)"))
            }
        }
        return result?.pointer
    }

    /// `type(object)`.
    func typeof(_ reference: PyRef?) -> PyType {
        guard let reference, let type = PyObject_Type(reference) else { return .object }
        // Borrowed from here on: the object keeps its type alive.
        Py_DecRef(type)
        return PyType(reference: type, name: PyRuntime.typeName(of: reference))
    }

    /// The type an object already is, for when it is one.
    func totype(_ reference: PyRef?) -> PyType {
        guard let reference else { return .object }
        let name = PyObject_GetAttrString(reference, "__name__")
        defer { name.map(Py_DecRef) }
        return PyType(reference: reference, name: name.flatMap { String($0) } ?? "type")
    }

    /// `repr(object)`.
    func repr(_ reference: PyRef?) throws(PythonError) -> String {
        guard let reference, let text = PyObject_Repr(reference) else {
            throw .TypeError("repr() needs an object")
        }
        defer { Py_DecRef(text) }
        return String(text) ?? ""
    }

    /// Wraps a borrowed reference in a retaining ``PyObject``.
    func retain(_ reference: PyRef?) -> PyObject? {
        reference.map(PyObject.init(retaining:))
    }

    func retain(_ reference: PyRef) -> PyObject {
        PyObject(retaining: reference)
    }

    /// Converts a Swift value and wraps the result.
    func retain<Value: PythonConvertible>(_ value: Value) -> PyObject? {
        try? value.toPython()
    }

    /// `iter(object)`.
    func iter(_ reference: PyRef?) throws(PythonError) -> PyRef {
        guard let reference, let iterator = PyObject_GetIter(reference) else {
            PyErr_Clear()
            throw .TypeError("object is not iterable")
        }
        return PyHold.take(iterator)
    }

    /// The next item, or a `StopIteration` when the iterator is spent.
    func next(_ reference: PyRef) throws(PythonError) -> PyRef {
        guard let item = PyIter_Next(reference) else {
            guard PyErr_Occurred() != nil else { throw PythonError.StopIteration("") }
            throw PyRuntime.raisedError()
        }
        return PyHold.take(item)
    }

    /// Calls `function`, converting each argument on the way in.
    @discardableResult
    func call(_ function: PyRef, args: (any PythonConvertible)?...) throws(PythonError) -> PyRef {
        try call(function, unpacking: args)
    }

    @discardableResult
    func call(
        _ function: PyRef,
        unpacking args: [(any PythonConvertible)?]
    ) throws(PythonError) -> PyRef {
        // Boxes, so every argument outlives the tuple that borrows it.
        var boxes: [PyObject] = []
        boxes.reserveCapacity(args.count)
        for argument in args {
            boxes.append(try argument?.toPython() ?? .none)
        }

        guard let tuple = PyTuple_New(boxes.count) else {
            throw .SystemError("could not allocate a call tuple")
        }
        defer { Py_DecRef(tuple) }
        for (index, box) in boxes.enumerated() {
            Py_IncRef(box.reference)
            PyTuple_SetItem(tuple, index, box.reference)
        }

        guard let result = PyObject_CallObject(function, tuple) else {
            throw PyRuntime.raisedError()
        }
        return PyHold.take(result)
    }

    /// Drops everything the user put in `__main__`, keeping its dunders.
    func clearMain() {
        guard let module = PyImport_AddModule("__main__"),
              let namespace = PyModule_GetDict(module),
              let names = PyDict_Keys(namespace) else { return }
        defer { Py_DecRef(names) }

        for index in 0..<PyList_Size(names) {
            guard let key = PyList_GetItem(names, index),
                  let name = String(key), !name.hasPrefix("__") else { continue }
            PyDict_DelItemString(namespace, name)
        }
        PyErr_Clear()
    }

    /// Sets `error` as the raised exception.
    static func raise(_ error: PythonError) {
        PyErr_SetString(PyRuntime.exceptionType(named: error.type), error.value)
    }
}

/// What the layer above plugs in, so this module needs to know nothing about
/// the host's own types. Registered once at startup.
@MainActor
public enum PyBridge {
    /// Extra conversions `cast` accepts, keyed by the type being cast *to*:
    /// a `Path` is accepted for a `str`, a `View` for an `AnyView`.
    public static var implicitCasts: [PyType: [PyType]] = [:]

    /// How to read a `String` out of one of those stand-in types.
    public static var stringConversions: [PyType: (PyRef) -> String] = [:]

    /// How to box a returned value that is not ``PythonConvertible``.
    public static var box: ((Any) -> PyObject?)?
}
