import CPython
import Foundation

/// A Python module, spelled the same as SwiftPy's `PyModule`.
///
/// The reference is borrowed: `sys.modules` keeps a module alive for the
/// process lifetime, so the handle needs no ownership of its own.
@MainActor
@dynamicMemberLookup
public struct PyModule: @MainActor PyReferencing {
    public let reference: PyRef

    public init?(_ reference: PyRef?) {
        guard let reference else { return nil }
        self.reference = reference
    }

    /// The module `name`, importing it the way `import name` does.
    public init?(_ name: String) {
        guard let module = PyImport_ImportModule(name) else {
            PyErr_Clear()
            return nil
        }
        // A successful import leaves the module in `sys.modules`, which holds
        // the reference this handle borrows.
        Py_DecRef(module)
        self.reference = module
    }

    /// A new, empty module, registered so Python can import it.
    public init?(creating name: String) {
        guard let module = PyImport_AddModule(name) else {
            PyErr_Clear()
            return nil
        }
        self.reference = module
    }

    // MARK: Attributes

    public subscript(dynamicMember name: String) -> PyObject? {
        get {
            guard let attribute = PyObject_GetAttrString(reference, name) else {
                PyErr_Clear()
                return nil
            }
            guard Py_IsNone(attribute) == 0 else {
                Py_DecRef(attribute)
                return nil
            }
            return PyObject(consuming: attribute)
        }
        nonmutating set { set(name, to: newValue?.reference) }
    }

    @_disfavoredOverload
    public subscript<Value: PythonConvertible>(dynamicMember name: String) -> Value? {
        get {
            guard let attribute = PyObject_GetAttrString(reference, name) else {
                PyErr_Clear()
                return nil
            }
            defer { Py_DecRef(attribute) }
            return Value(attribute)
        }
        nonmutating set {
            guard let object = try? newValue?.toPython() else {
                set(name, to: nil)
                return
            }
            set(name, to: object.reference)
        }
    }

    private func set(_ name: String, to value: PyRef?) {
        let value = value ?? Py_GetConstantBorrowed(UInt32(Py_CONSTANT_NONE))
        if PyObject_SetAttrString(reference, name, value) != 0 {
            PyErr_Clear()
        }
    }

    // MARK: Functions

    /// Binds a Swift function, taking SwiftPy's signature string.
    ///
    ///     module.def("add(a: int, b: int) -> int") { _, args in ... }
    ///
    /// The name goes on the function; the rest becomes a `__text_signature__`
    /// through the argument clinic's docstring convention. See
    /// ``clinicDocumentation(signature:docstring:receiver:)``.
    public func def(
        _ signature: String,
        docstring: String? = nil,
        function: PyAPI.CFunction
    ) {
        let name = String(signature.prefix { $0 != "(" })
            .trimmingCharacters(in: .whitespaces)
        let documentation = clinicDocumentation(
            signature: signature,
            docstring: docstring,
            receiver: "$module"
        )

        // CPython keeps referring to the method table for as long as the
        // function lives, so it is allocated once and never freed.
        let method = UnsafeMutablePointer<PyMethodDef>.allocate(capacity: 1)
        method.initialize(to: PyMethodDef(
            ml_name: strdup(name),
            ml_meth: function,
            ml_flags: Int32(METH_VARARGS),
            ml_doc: strdup(documentation)
        ))

        guard let bound = PyCFunction_NewEx(method, nil, nil) else {
            PyErr_Clear()
            return
        }
        defer { Py_DecRef(bound) }
        set(name, to: bound)
    }

    /// The async machinery is not ported yet, so this binds an ordinary
    /// function: what it returns is whatever the binding hands back.
    public func asyncDef(_ signature: String, docstring: String? = nil, function: PyAPI.CFunction) {
        def(signature, docstring: docstring, function: function)
    }
}

extension PyModule: PythonConvertible {
    public static var pyType: PyType { .module }

    public func toPython() throws(PythonError) -> PyObject {
        PyObject(retaining: reference)
    }

    public static func fromPython(_ reference: PyRef) -> PyModule {
        PyModule(reference)!
    }
}
