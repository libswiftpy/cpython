import CPython

/// A Python tuple as a Swift value, spelled the same as SwiftPy's. What a
/// binding taking `*args` reads its arguments out of.
@MainActor
public struct PyTuple: PythonConvertible {
    public var values: [PyObject]

    public init(values: [PyObject]) {
        self.values = values
    }

    public static var pyType: PyType { .builtin("tuple") }

    public static func fromPython(_ reference: PyRef) -> PyTuple {
        let count = PyTuple_Size(reference)
        guard count > 0 else { return PyTuple(values: []) }
        return PyTuple(values: (0..<count).compactMap { index in
            PyTuple_GetItem(reference, index).map(PyObject.init(retaining:))
        })
    }

    public func toPython() throws(PythonError) -> PyObject {
        guard let tuple = PyTuple_New(values.count) else {
            throw .SystemError("could not allocate a tuple")
        }
        for (index, value) in values.enumerated() {
            // PyTuple_SetItem steals the reference it is given.
            Py_IncRef(value.reference)
            PyTuple_SetItem(tuple, index, value.reference)
        }
        return PyObject(consuming: tuple)
    }
}
