import CPython

/// The C function CPython calls to create a module — `PyMODINIT_FUNC`.
public typealias PythonModuleInitializer = @convention(c) () -> UnsafeMutablePointer<PyObject>?

/// A stdlib module supplied by the package rather than by libpython.
///
/// A module usually has two halves: C code, compiled by SwiftPM into the
/// binary and registered in the inittab, and Python code, shipped as a
/// resource bundle whose directory joins `sys.path`. Either half may be empty.
///
/// Modules are values so that each one can be declared where it lives:
///
///     try Python.initialize(modules: [.json])
public struct PythonModule: Sendable {
    /// Built into the binary; registered before the interpreter starts,
    /// because the inittab is read during initialization.
    public let builtins: [Builtin]

    /// Directories added to `sys.path` once the interpreter is running.
    public let searchPaths: [String]

    public init(builtins: [Builtin] = [], searchPaths: [String] = []) {
        self.builtins = builtins
        self.searchPaths = searchPaths
    }

    public struct Builtin: Sendable {
        public let name: String
        public let initializer: PythonModuleInitializer

        public init(_ name: String, _ initializer: @escaping PythonModuleInitializer) {
            self.name = name
            self.initializer = initializer
        }
    }
}
