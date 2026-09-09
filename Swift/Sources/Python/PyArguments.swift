import CPython

/// The pair of values a C binding is handed, behind one name.
///
/// The pair is the backend's: CPython passes `(self, args)`, pocketpy
/// `(argc, argv)`. Binding code that is meant to be shared names their types
/// through ``RawFirst`` and ``RawSecond`` and never reads them directly, so the
/// same source compiles against either.
///
/// Indexing follows pocketpy's, which is what the bindings were written
/// against: a method's receiver is argument 0.
@MainActor
public struct PyArguments {
    public typealias RawFirst = PyRef?
    public typealias RawSecond = PyRef?

    /// Nil for a module-level function, where CPython's `self` is the module.
    @usableFromInline let receiver: PyRef?

    /// The `METH_VARARGS` tuple.
    @usableFromInline let arguments: PyRef?

    @inlinable
    public init(method first: RawFirst, _ second: RawSecond) {
        receiver = first
        arguments = second
    }

    @inlinable
    public init(function first: RawFirst, _ second: RawSecond) {
        receiver = nil
        arguments = second
    }

    @inlinable
    public var count: Int {
        (receiver == nil ? 0 : 1) + (arguments.map { PyTuple_Size($0) } ?? 0)
    }

    /// The argument at `index`, or nil past the end. Borrowed, the way
    /// pocketpy's `argv[i]` is.
    @inlinable
    public subscript(index: Int) -> PyRef? {
        guard index >= 0, index < count else { return nil }
        guard let receiver else { return PyTuple_GetItem(arguments, index) }
        return index == 0 ? receiver : PyTuple_GetItem(arguments, index - 1)
    }
}

/// What a binding answers with. CPython returns the result itself, pocketpy
/// reports success.
public typealias PyReturn = PyRef?

public extension PythonConvertible {
    /// The argument at `offset`, converted or refused.
    @inlinable
    static func cast(
        _ arguments: PyArguments,
        _ offset: Int = 0
    ) throws(PythonError) -> Self {
        try cast(arguments[offset], offset)
    }
}
