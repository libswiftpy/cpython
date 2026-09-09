import CPython
import Foundation

/// A Swift class exposed to Python, spelled the same as SwiftPy's.
@MainActor
public protocol PythonBindable: AnyObject, PythonConvertible {
    var _pythonCache: PythonBindingCache { get set }
}

/// Where a bound object remembers its Python half, so one Swift object stays
/// one Python object.
///
/// Borrowed on purpose. The Python object owns the Swift one, so a reference
/// back the other way would be a cycle neither side could break; the type's
/// destructor clears this just before it lets go.
public struct PythonBindingCache {
    public var reference: PyRef?
    public init() {}
}

@MainActor
public extension PythonBindable {
    func toPython() throws(PythonError) -> PyObject {
        if let cached = _pythonCache.reference {
            return PyObject(retaining: cached)
        }
        guard let object = cpy.newobject(type: Self.pyType) else {
            throw .SystemError("could not allocate a \(Self.pyType.name)")
        }
        storeInPython(object)
        return object
    }

    /// Hands `self` to `object`, which from here on keeps it alive.
    func storeInPython(_ object: PyObject) {
        object.storeUserdata(Unmanaged.passRetained(self).toOpaque())
        _pythonCache.reference = object.reference
    }

    static func fromPython(_ reference: PyRef) -> Self {
        let pointer = reference.userdata.load(as: UnsafeMutableRawPointer.self)
        return Unmanaged<Self>.fromOpaque(pointer).takeUnretainedValue()
    }

    /// An instance Python made on its own carries no Swift value yet, and
    /// reading one out of it would dereference nothing.
    static func isConvertible(_ reference: PyRef) -> Bool {
        pyType.isInstance(reference)
            && reference.userdata.load(as: UnsafeMutableRawPointer?.self) != nil
    }
}

@MainActor
public extension PyType {
    /// Creates a type for a ``PythonBindable``, spelled like SwiftPy's.
    ///
    /// Only a base without storage of its own works; see
    /// ``PyAPI/newtype(name:base:module:dtor:)``.
    static func make(
        _ name: String,
        base: PyType = .object,
        module: PyModule? = nil,
        bind: @MainActor (PyType) -> Void
    ) -> PyType {
        guard let type = cpy.newtype(
            name: name,
            base: base,
            module: module,
            dtor: releaseBoundObject
        ) else {
            preconditionFailure("could not create the type \(name)")
        }
        bind(type)
        return type
    }
}

/// Lets go of the Swift object a Python instance was keeping alive, and clears
/// the way back before it does.
private func releaseBoundObject(_ userdata: UnsafeMutableRawPointer?) {
    let crossing = GILBound(userdata?.assumingMemoryBound(to: UInt8.self))

    MainActor.assumeIsolated {
        guard let raw = crossing.pointer.map({ UnsafeMutableRawPointer($0) }),
              let stored = raw.load(as: UnsafeMutableRawPointer?.self) else {
            return
        }
        let object = Unmanaged<AnyObject>.fromOpaque(stored).takeRetainedValue()
        if let bindable = object as? any PythonBindable {
            bindable._pythonCache.reference = nil
        }
    }
}
