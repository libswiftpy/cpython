import CPython
import Foundation

/// Bridges a Swift value to Python and back, spelled the same as SwiftPy's
/// protocol.
///
/// `toPython()` returns a new object rather than filling a caller's slot the
/// way pocketpy does: a CPython value is a heap object with a refcount, so
/// there is no slot to write into — and no `pushtmp`/`pop` to balance.
@MainActor
public protocol PythonConvertible {
    func toPython() throws(PythonError) -> PyObject

    static func fromPython(_ reference: PyRef) -> Self

    static var pyType: PyType { get }

    /// Converts, or `nil` when the object is not this type.
    ///
    /// A requirement rather than an extension member so that a collection can
    /// call it through `Element.self as? any PythonConvertible.Type`.
    init?(_ reference: PyRef?)

    /// Whether `reference` really carries a value of this type.
    ///
    /// Static, so a class-bound type can narrow it -- an initializer in an
    /// `AnyObject` extension cannot assign to `self`.
    static func isConvertible(_ reference: PyRef) -> Bool
}

public extension PythonConvertible {
    static func isConvertible(_ reference: PyRef) -> Bool {
        if pyType.isExactType(of: reference) || pyType.isInstance(reference) { return true }
        // A stand-in the host registered, e.g. a Path where a str is expected.
        return PyBridge.implicitCasts[pyType]?.contains { $0.isInstance(reference) } ?? false
    }

    /// Converts a Python object, or `nil` when it is not this type.
    init?(_ reference: PyRef?) {
        guard let reference, Self.isConvertible(reference) else { return nil }
        self = Self.fromPython(reference)
    }

    /// The same, for anything holding a reference.
    init?(_ value: (some PyReferencing)?) {
        self.init(value?.reference)
    }

    /// Writes `self` into `object`, mirroring SwiftPy's `toPython(_ reference:)`.
    ///
    /// pocketpy writes into a caller's slot; here the box is repointed at a new
    /// object instead, because a CPython object cannot change its type in place.
    /// Writes into an existing box. Does not throw, the way pocketpy's
    /// out-parameter form cannot: a value that will not convert leaves the box
    /// untouched.
    func toPython(_ object: PyObject) {
        guard let value = try? toPython() else { return }
        object.assign(value)
    }

    /// Converts, or throws a `TypeError` naming what was expected.
    static func cast(
        _ value: (some PyReferencing)?,
        _ offset: Int = 0
    ) throws(PythonError) -> Self {
        guard let reference = value?.reference else {
            throw .TypeError("Expected \(pyType.name) at position \(offset)")
        }

        if let value = Self(reference) { return value }

        if reference.isNone, Self.self is ExpressibleByNilLiteral.Type {
            return Self.fromPython(reference)
        }

        throw .TypeError(
            "Expected \(pyType.name) got \(reference.typeName) at position \(offset)"
        )
    }
}

extension String: PythonConvertible {
    public static var pyType: PyType { .str }

    public func toPython() throws(PythonError) -> PyObject {
        guard let object = PyUnicode_FromString(self) else {
            throw .SystemError("could not make a str")
        }
        return PyObject(consuming: object)
    }

    public static func fromPython(_ reference: PyRef) -> String {
        if let utf8 = PyUnicode_AsUTF8(reference) {
            return String(cString: utf8)
        }
        PyErr_Clear()
        // Keyed by the registered base, so a subclass instance matches too.
        if let convert = PyBridge.stringConversions.first(where: { $0.key.isInstance(reference) })?.value {
            return convert(reference)
        }
        return ""
    }
}

extension Bool: PythonConvertible {
    public static var pyType: PyType { .bool }

    public func toPython() throws(PythonError) -> PyObject {
        guard let object = PyBool_FromLong(self ? 1 : 0) else {
            throw .SystemError("could not make a bool")
        }
        return PyObject(consuming: object)
    }

    public static func fromPython(_ reference: PyRef) -> Bool {
        PyObject_IsTrue(reference) == 1
    }
}

extension Int: PythonConvertible {
    public static var pyType: PyType { .int }

    public func toPython() throws(PythonError) -> PyObject {
        guard let object = PyLong_FromLong(self) else {
            throw .SystemError("could not make an int")
        }
        return PyObject(consuming: object)
    }

    public static func fromPython(_ reference: PyRef) -> Int {
        let value = PyLong_AsLong(reference)
        if value == -1, PyErr_Occurred() != nil {
            PyErr_Clear()
            return 0
        }
        return value
    }

    /// `bool` is a subclass of `int` in Python, so the inherited check would
    /// read `True` as `1`. Swift keeps them apart, and so does this.
    public static func isConvertible(_ reference: PyRef) -> Bool {
        !PyType.bool.isExactType(of: reference) && pyType.isInstance(reference)
    }
}

extension Int64: PythonConvertible {
    public static var pyType: PyType { .int }

    public func toPython() throws(PythonError) -> PyObject {
        try Int(self).toPython()
    }

    public static func fromPython(_ reference: PyRef) -> Int64 {
        Int64(Int.fromPython(reference))
    }
}

extension Double: PythonConvertible {
    public static var pyType: PyType { .float }

    public func toPython() throws(PythonError) -> PyObject {
        guard let object = PyFloat_FromDouble(self) else {
            throw .SystemError("could not make a float")
        }
        return PyObject(consuming: object)
    }

    public static func fromPython(_ reference: PyRef) -> Double {
        let value = PyFloat_AsDouble(reference)
        if value == -1, PyErr_Occurred() != nil {
            PyErr_Clear()
            return 0
        }
        return value
    }

    /// An int satisfies a float, the widening SwiftPy's `canCast` also allows.
    public static func isConvertible(_ reference: PyRef) -> Bool {
        pyType.isInstance(reference) || PyType.int.isInstance(reference)
    }
}

extension Float: PythonConvertible {
    public static var pyType: PyType { .float }

    public func toPython() throws(PythonError) -> PyObject {
        try Double(self).toPython()
    }

    public static func fromPython(_ reference: PyRef) -> Float {
        Float(Double.fromPython(reference))
    }

    public static func isConvertible(_ reference: PyRef) -> Bool {
        Double.isConvertible(reference)
    }
}

extension Data: PythonConvertible {
    public static var pyType: PyType { .bytes }

    public func toPython() throws(PythonError) -> PyObject {
        let object = withUnsafeBytes { buffer in
            PyBytes_FromStringAndSize(
                buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                count
            )
        }
        guard let object else { throw .SystemError("could not make bytes") }
        return PyObject(consuming: object)
    }

    public static func fromPython(_ reference: PyRef) -> Data {
        var buffer: UnsafeMutablePointer<CChar>?
        var length = 0
        guard PyBytes_AsStringAndSize(reference, &buffer, &length) == 0,
              let buffer else {
            PyErr_Clear()
            return Data()
        }
        return Data(bytes: buffer, count: length)
    }
}

extension Optional: PythonConvertible where Wrapped: PythonConvertible {
    public static var pyType: PyType { Wrapped.pyType }

    /// Preserve the wrapped type's conversion rules, including int-to-float
    /// widening. The shared cast handles None for optional values.
    public static func isConvertible(_ reference: PyRef) -> Bool {
        Wrapped.isConvertible(reference)
    }

    public func toPython() throws(PythonError) -> PyObject {
        guard let self else { return .none }
        return try self.toPython()
    }

    public static func fromPython(_ reference: PyRef) -> Wrapped? {
        reference.isNone ? nil : Wrapped(reference)
    }
}

extension PyObject: PythonConvertible {
    public static var pyType: PyType { .object }

    public func toPython() throws(PythonError) -> PyObject { self }

    public static func fromPython(_ reference: PyRef) -> PyObject {
        PyObject(retaining: reference)
    }
}

// MARK: - Collections

extension Array: PythonConvertible {
    public static var pyType: PyType { .list }

    public func toPython() throws(PythonError) -> PyObject {
        guard let list = PyList_New(0) else {
            throw .SystemError("could not make a list")
        }
        let object = PyObject(consuming: list)

        for element in self {
            guard let element = element as? PythonConvertible else {
                throw .TypeError("\(Element.self) is not convertible to Python")
            }
            let item = try element.toPython()
            guard PyList_Append(list, item.reference) == 0 else {
                throw PyRuntime.raisedError()
            }
        }
        return object
    }

    public static func fromPython(_ reference: PyRef) -> [Element] {
        var items: [Element] = []

        guard let iterator = PyObject_GetIter(reference) else {
            PyErr_Clear()
            return items
        }
        defer { Py_DecRef(iterator) }

        while let item = PyIter_Next(iterator) {
            defer { Py_DecRef(item) }

            if Element.self == Any?.self, let element = item.asAny as? Element {
                items.append(element)
                continue
            }
            guard let type = Element.self as? any PythonConvertible.Type,
                  let element = type.init(item) as? Element else { continue }
            items.append(element)
        }
        // PyIter_Next returns nil both at the end and on failure.
        PyErr_Clear()
        return items
    }
}

extension Dictionary: PythonConvertible where Key: PythonConvertible {
    public static var pyType: PyType { .dict }

    public func toPython() throws(PythonError) -> PyObject {
        guard let dictionary = PyDict_New() else {
            throw .SystemError("could not make a dict")
        }
        let object = PyObject(consuming: dictionary)

        for (key, value) in self {
            guard let value = value as? PythonConvertible else {
                throw .TypeError("\(Value.self) is not convertible to Python")
            }
            let key = try key.toPython()
            let item = try value.toPython()
            guard PyDict_SetItem(dictionary, key.reference, item.reference) == 0 else {
                throw PyRuntime.raisedError()
            }
        }
        return object
    }

    public static func fromPython(_ reference: PyRef) -> [Key: Value] {
        var result: [Key: Value] = [:]

        // `items()` rather than PyDict_Next, so any mapping converts.
        guard let items = PyMapping_Items(reference),
              let iterator = PyObject_GetIter(items) else {
            PyErr_Clear()
            return result
        }
        defer {
            Py_DecRef(items)
            Py_DecRef(iterator)
        }

        while let pair = PyIter_Next(iterator) {
            defer { Py_DecRef(pair) }

            guard let keyReference = PySequence_GetItem(pair, 0),
                  let valueReference = PySequence_GetItem(pair, 1) else {
                PyErr_Clear()
                continue
            }
            defer {
                Py_DecRef(keyReference)
                Py_DecRef(valueReference)
            }

            guard let key = Key(keyReference) else { continue }

            if Value.self == Any.self, let value = valueReference.asAny as? Value {
                result[key] = value
                continue
            }
            guard let type = Value.self as? any PythonConvertible.Type,
                  let value = type.init(valueReference) as? Value else { continue }
            result[key] = value
        }
        PyErr_Clear()
        return result
    }
}

// MARK: - Reference -> Any?

@MainActor
public extension PyReferencing {
    /// The closest Swift value, or PyObject when nothing fits.
    var asAny: Any? {
        if reference.isNone { return nil }
        if let value = String(reference) { return value }
        if let value = Bool(reference) { return value }
        if let value = Int(reference) { return value }
        if let value = Double(reference) { return value }
        if let value = Data(reference) { return value }
        if let value = [Any?](reference) { return value }
        if let value = [String: Any](reference) { return value }
        return PyObject(retaining: reference)
    }
}
