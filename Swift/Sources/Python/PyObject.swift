import CPython
import Foundation

/// A borrowed reference, spelled the same as SwiftPy's `PyRef`.
///
/// Borrowed on purpose: reading a value out of Python needs no ownership, and
/// a binding gets its arguments as raw pointers.
public typealias PyRef = UnsafeMutablePointer<CPython.PyObject>

/// Anything that can be read as a Python object.
public protocol PyReferencing {
    var reference: PyRef { get }
}

extension UnsafeMutablePointer: PyReferencing where Pointee == CPython.PyObject {
    @inlinable public var reference: PyRef { self }
}

@MainActor
public extension PyReferencing {
    /// Whether this is Python's `None`.
    var isNone: Bool { Py_IsNone(reference) != 0 }

    /// `type(self).__name__`.
    var typeName: String { PyRuntime.typeName(of: reference) }
}

/// A Python object, kept alive for as long as this wrapper is.
///
/// Main-actor isolated, the way SwiftPy's is: the interpreter only ever runs
/// on the thread that holds the GIL, so a box for one of its objects belongs
/// there too.
@MainActor
@dynamicMemberLookup
public final class PyObject: @MainActor PyReferencing, Sendable {
    public private(set) var reference: PyRef

    /// Takes ownership of a new reference.
    init(consuming reference: PyRef) {
        self.reference = reference
    }

    /// Takes a reference to something owned elsewhere.
    @MainActor
    public init(retaining reference: PyRef) {
        Py_IncRef(reference)
        self.reference = reference
    }

    /// Python's `None`.
    @MainActor
    public static var none: PyObject {
        // A constant, but still handed over as a new reference.
        PyObject(consuming: Py_GetConstant(UInt32(Py_CONSTANT_NONE)))
    }

    /// Points this box at what `other` holds, releasing what it held before.
    ///
    /// Only the box moves: the object it used to hold is untouched, so anyone
    /// else referring to it still sees the old value.
    @MainActor
    public func assign(_ other: PyObject) {
        guard other.reference != reference else { return }
        // Retain first: the two could be the last references to each other.
        Py_IncRef(other.reference)
        Py_DecRef(reference)
        reference = other.reference
    }

    /// Reads or writes a Python attribute. Reading gives `nil` when it is
    /// missing or `None`; writing `nil` sets it to `None`.
    ///
    ///     let sys = try cpy.module("sys")
    ///     sys.stdout = sys.__stdout__
    @MainActor
    public subscript(dynamicMember name: String) -> PyObject? {
        get { attribute(named: name) }
        set { setAttribute(named: name, to: newValue?.reference) }
    }

    /// Reads or writes an attribute as a Swift type.
    ///
    ///     let version: String? = sys.version
    ///     sys.count = 3
    ///
    /// Disfavoured for the same reason as the typed call: without a Swift type
    /// to aim at, the attribute should come back as a `PyObject`.
    @MainActor
    @_disfavoredOverload
    public subscript<Value: PythonConvertible>(dynamicMember name: String) -> Value? {
        get {
            guard let attribute = attribute(named: name) else { return nil }
            return Value(attribute)
        }
        set {
            guard let newValue else {
                setAttribute(named: name, to: nil)
                return
            }
            // Hold the new object across the call: reading `.reference` out of a
            // temporary would leave a pointer to something already released.
            guard let object = try? newValue.toPython() else { return }
            setAttribute(named: name, to: object.reference)
        }
    }

    // MARK: Calls

    /// Calls the object, returning the result or `nil` when it returned `None`.
    ///
    /// Discardable, so a call whose result is not wanted needs no `_ =`. There
    /// is deliberately no `-> Void` overload: `let x = call()` would bind `()`
    /// just as happily, which makes every unannotated call ambiguous.
    @discardableResult
    @MainActor
    public func callAsFunction(
        _ arguments: (any PythonConvertible)?...
    ) throws(PythonError) -> PyObject? {
        let result = try call(arguments)
        return result.isNone ? nil : result
    }

    /// Calls the object and bridges the result to a Swift type.
    ///
    ///     let root: Double = try math.sqrt(2.0)
    ///
    /// Disfavoured so that an unannotated call resolves to the overload above:
    /// `PyObject` is itself convertible, so both would otherwise match.
    @discardableResult
    @MainActor
    @_disfavoredOverload
    public func callAsFunction<Result: PythonConvertible>(
        _ arguments: (any PythonConvertible)?...
    ) throws(PythonError) -> Result {
        let result = try call(arguments)
        return try .cast(result.reference)
    }

    @MainActor
    private func call(_ arguments: [(any PythonConvertible)?]) throws(PythonError) -> PyObject {
        guard let tuple = PyTuple_New(arguments.count) else {
            throw .SystemError("could not allocate an argument tuple")
        }
        defer { Py_DecRef(tuple) }

        for (index, argument) in arguments.enumerated() {
            let object: PyObject
            if let argument {
                object = try argument.toPython()
            } else {
                object = .none
            }
            // The tuple steals what it is given, and the box keeps its own.
            Py_IncRef(object.reference)
            PyTuple_SetItem(tuple, index, object.reference)
        }

        guard let result = PyObject_Call(reference, tuple, nil) else {
            throw PyRuntime.raisedError()
        }
        return PyObject(consuming: result)
    }

    @MainActor
    private func attribute(named name: String) -> PyObject? {
        guard let attribute = PyObject_GetAttrString(reference, name) else {
            // A missing attribute leaves the exception set, which would then
            // surface at whatever calls into CPython next.
            PyErr_Clear()
            return nil
        }

        guard Py_IsNone(attribute) == 0 else {
            Py_DecRef(attribute)
            return nil
        }
        return PyObject(consuming: attribute)
    }

    @MainActor
    private func setAttribute(named name: String, to value: PyRef?) {
        let value = value ?? Py_GetConstantBorrowed(UInt32(Py_CONSTANT_NONE))
        if PyObject_SetAttrString(reference, name, value) != 0 {
            PyErr_Clear()
        }
    }

    // Isolated, because the last reference can be dropped anywhere — an actor
    // holding a code object releases it on its own thread — and a decref there
    // has no thread state and would abort the process.
    @MainActor deinit {
        Py_DecRef(reference)
    }
}
