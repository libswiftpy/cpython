import CPython

/// A Python type object, spelled the same as SwiftPy's `PyType`.
///
/// Not isolated as a whole: it is a pointer and a name, so comparing two is
/// just data. Only what calls into CPython belongs on the main actor.
public struct PyType: Hashable {
    /// Borrowed: the builtins dict keeps its types for the process lifetime.
    let reference: PyRef

    public let name: String

    init(reference: PyRef, name: String) {
        self.reference = reference
        self.name = name
    }

    /// Looks a type up in `builtins`, which is where `int`, `str` and the rest
    /// live. The interpreter has to be running.
    @MainActor
    static func builtin(_ name: String) -> PyType {
        guard let builtins = PyEval_GetBuiltins(),
              let type = PyDict_GetItemString(builtins, name) else {
            preconditionFailure("builtins.\(name) is missing; is the interpreter running?")
        }
        return PyType(reference: type, name: name)
    }

    /// A type read off a live object, e.g. `pathlib.PurePath`; `nil` when the
    /// object is not a type. The caller keeps the object alive.
    @MainActor
    public init?(_ object: some PyReferencing) {
        let reference = object.reference
        guard PyType_Check(reference) != 0,
              let name = PyType_GetName(UnsafeMutableRawPointer(reference).assumingMemoryBound(to: PyTypeObject.self)) else {
            PyErr_Clear()
            return nil
        }
        defer { Py_DecRef(name) }
        self.init(reference: reference, name: PyUnicode_AsUTF8(name).map { String(cString: $0) } ?? "?")
    }

    /// The type as an object, which is what putting it in a module, or writing
    /// onto it, takes.
    @MainActor
    public var object: PyObject { PyObject(retaining: reference) }

    /// `isinstance(object, self)`.
    @MainActor
    public func isInstance(_ object: some PyReferencing) -> Bool {
        PyObject_IsInstance(object.reference, reference) == 1
    }

    /// `type(object) is self`.
    @MainActor
    public func isExactType(of object: some PyReferencing) -> Bool {
        guard let type = PyObject_Type(object.reference) else { return false }
        defer { Py_DecRef(type) }
        return type == reference
    }
}

@MainActor
public extension PyType {
    static let bool = PyType.builtin("bool")
    static let int = PyType.builtin("int")
    static let float = PyType.builtin("float")
    static let str = PyType.builtin("str")
    static let bytes = PyType.builtin("bytes")
    static let list = PyType.builtin("list")
    static let dict = PyType.builtin("dict")
    static let object = PyType.builtin("object")

    /// `type(sys)`. Not a builtin name, so it is read off a real module.
    static let module: PyType = {
        guard let sys = PyImport_ImportModule("sys"),
              let type = PyObject_Type(sys) else {
            preconditionFailure("sys is missing; is the interpreter running?")
        }
        // Both are kept by the interpreter for the process lifetime.
        Py_DecRef(sys)
        Py_DecRef(type)
        return PyType(reference: type, name: "module")
    }()
}

@MainActor
public extension PyObject {
    /// A type as an object. Not failable, which is what a binding writing onto
    /// its own type relies on.
    convenience init(_ type: PyType) {
        self.init(retaining: type.reference)
    }
}

@MainActor
public extension PyObject {
    /// Builds an object by writing into it, the shape pocketpy's
    /// out-parameter initializers gave the bindings.
    convenience init(_ build: (PyObject) -> Void) {
        self.init(consuming: Py_GetConstant(UInt32(Py_CONSTANT_NONE)))
        build(self)
    }
}
