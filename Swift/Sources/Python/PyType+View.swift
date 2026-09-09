import CPython

@MainActor
public extension PyType {
    /// The base a Python class subclasses to become presentable, spelled like
    /// SwiftPy's. It carries no value of its own; a subclass supplies `body`.
    ///
    /// No `__new__` binding: a created type's `tp_new` allocates the type it is
    /// called on, and a subclass inherits it.
    static let View: PyType = .make("View") { type in
        type.function("body(self) -> View") { _, _ in
            PyAPI.return {
                throw PythonError.NotImplementedError("def body(self) is not implemented")
            }
        }
    }
}
