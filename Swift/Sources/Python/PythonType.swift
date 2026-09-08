import CPython

/// A Python type object, the counterpart of SwiftPy's `PyType`.
///
/// Not isolated as a whole: it is a pointer and a name, so comparing two is
/// just data. Only what calls into CPython belongs on the main actor.
public struct PythonType: Equatable {
    /// Borrowed: the builtins dict keeps its types for the process lifetime.
    let reference: PythonRef

    public let name: String

    /// Looks a type up in `builtins`, which is where `int`, `str` and the rest
    /// live. The interpreter has to be running.
    @MainActor
    static func builtin(_ name: String) -> PythonType {
        guard let builtins = PyEval_GetBuiltins(),
              let type = PyDict_GetItemString(builtins, name) else {
            preconditionFailure("builtins.\(name) is missing; is the interpreter running?")
        }
        return PythonType(reference: type, name: name)
    }

    /// `isinstance(object, self)`.
    @MainActor
    public func isInstance(_ object: some PythonReferencing) -> Bool {
        PyObject_IsInstance(object.reference, reference) == 1
    }

    /// `type(object) is self`.
    @MainActor
    public func isExactType(of object: some PythonReferencing) -> Bool {
        guard let type = PyObject_Type(object.reference) else { return false }
        defer { Py_DecRef(type) }
        return type == reference
    }
}

@MainActor
public extension PythonType {
    static let bool = PythonType.builtin("bool")
    static let int = PythonType.builtin("int")
    static let float = PythonType.builtin("float")
    static let str = PythonType.builtin("str")
    static let bytes = PythonType.builtin("bytes")
    static let list = PythonType.builtin("list")
    static let dict = PythonType.builtin("dict")
    static let object = PythonType.builtin("object")
}
