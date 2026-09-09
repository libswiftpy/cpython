import CPython
import Foundation

/// What a created type needs at destruction time. Kept aside because a
/// `@convention(c)` slot cannot capture anything.
@MainActor
private var destructors: [PyRef: @convention(c) (UnsafeMutableRawPointer?) -> Void] = [:]

/// Where a created type keeps its Swift value: right past the object header.
/// Fixed rather than per-type so a Python subclass, whose own payload CPython
/// lays out after ours, still finds it.
private let userdataOffset = MemoryLayout<CPython.PyObject>.size

@MainActor
public extension PyAPI {
    /// Creates a heap type, the counterpart of pocketpy's `py_newtype`.
    ///
    /// Instances carry one pointer of Swift userdata, which is what a binding
    /// stores its Swift value in. `base` may only be a type that adds no
    /// storage of its own -- the userdata sits at a fixed offset, so anything
    /// below it would land on the same bytes.
    func newtype(
        name: String,
        base: PyType = .object,
        module: PyModule? = nil,
        dtor: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = nil
    ) -> PyType? {
        let baseType = UnsafeMutableRawPointer(base.reference)
            .assumingMemoryBound(to: PyTypeObject.self)
        precondition(
            baseType.pointee.tp_basicsize <= userdataOffset,
            "\(name) cannot be based on \(base.name), which has storage of its own"
        )

        // CPython keeps pointing at the name and the slots for as long as the
        // type lives, so both are allocated once and never freed.
        let slots = UnsafeMutablePointer<PyType_Slot>.allocate(capacity: 4)
        slots[0] = PyType_Slot(slot: Py_tp_dealloc, pfunc: unsafeBitCast(deallocate, to: UnsafeMutableRawPointer.self))
        // Bound to a C function type first: taken bare, the imported function
        // is a thick Swift value and does not fit a slot.
        let genericNew: @convention(c) (
            UnsafeMutablePointer<PyTypeObject>?, PyRef?, PyRef?
        ) -> PyRef? = PyType_GenericNew
        slots[1] = PyType_Slot(slot: Py_tp_new, pfunc: unsafeBitCast(genericNew, to: UnsafeMutableRawPointer.self))
        slots[2] = PyType_Slot(slot: Py_tp_base, pfunc: UnsafeMutableRawPointer(base.reference))
        slots[3] = PyType_Slot(slot: 0, pfunc: nil)

        var specification = PyType_Spec(
            name: strdup(name),
            basicsize: Int32(userdataOffset + MemoryLayout<UnsafeMutableRawPointer>.size),
            itemsize: 0,
            flags: UInt32(UInt(Py_TPFLAGS_DEFAULT) | UInt(Py_TPFLAGS_BASETYPE)),
            slots: slots
        )

        guard let object = PyType_FromSpec(&specification) else {
            PyErr_Clear()
            return nil
        }

        if let dtor {
            destructors[object] = dtor
        }
        if let module {
            module[dynamicMember: name] = PyObject(retaining: object)
        }
        return PyType(reference: object, name: name)
    }

    /// A new instance of `type`, with its userdata zeroed.
    func newobject(type: PyType) -> PyObject? {
        guard let object = PyType_GenericAlloc(
            UnsafeMutableRawPointer(type.reference).assumingMemoryBound(to: PyTypeObject.self),
            0
        ) else {
            PyErr_Clear()
            return nil
        }
        return PyObject(consuming: object)
    }
}

@MainActor
public extension PyReferencing {
    /// The Swift value stored behind this object.
    var userdata: UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(reference).advanced(by: userdataOffset)
    }

    /// Reads the stored value, which only makes sense on an object of a type
    /// ``PyAPI/newtype(name:base:module:dtor:)`` made.
    func toUserdata<Value>(as type: Value.Type = Value.self) -> Value {
        userdata.assumingMemoryBound(to: Value.self).pointee
    }

    /// Writes the value the object carries.
    func storeUserdata<Value>(_ value: Value) {
        userdata.assumingMemoryBound(to: Value.self).initialize(to: value)
    }
}

// MARK: - Binding members

@MainActor
public extension PyType {
    /// Binds a method, taking SwiftPy's signature string. See ``PyModule/def``
    /// for why only the name is read out of it.
    func function(
        _ signature: String,
        _ docstring: String? = nil,
        block: PyAPI.CFunction
    ) {
        let name = String(signature.prefix { $0 != "(" })
            .trimmingCharacters(in: .whitespaces)

        // A descriptor rather than a plain function: that is what binds `self`
        // when the method is reached through an instance.
        guard let descriptor = PyDescr_NewMethod(
            UnsafeMutableRawPointer(reference).assumingMemoryBound(to: PyTypeObject.self),
            methodTable(
                name: name,
                documentation: clinicDocumentation(
                    signature: signature,
                    docstring: docstring,
                    receiver: "$self"
                ),
                function: block
            )
        ) else {
            PyErr_Clear()
            return
        }
        defer { Py_DecRef(descriptor) }
        set(name, to: descriptor)
    }

    /// Binds a dunder, e.g. `__repr__`.
    func magic(_ name: String, function: PyAPI.CFunction) {
        self.function("\(name)(self)", block: function)
    }

    private func set(_ name: String, to value: PyRef) {
        if PyObject_SetAttrString(reference, name, value) != 0 {
            PyErr_Clear()
            return
        }
        // Writing into a type's dict does not on its own invalidate the
        // attribute caches that would otherwise keep serving the old value.
        PyType_Modified(UnsafeMutableRawPointer(reference).assumingMemoryBound(to: PyTypeObject.self))
    }
}

/// Allocated once per binding and never freed: CPython keeps referring to it
/// for as long as the descriptor lives.
private func methodTable(
    name: String,
    documentation: String,
    function: @escaping PyAPI.CFunction
) -> UnsafeMutablePointer<PyMethodDef> {
    let method = UnsafeMutablePointer<PyMethodDef>.allocate(capacity: 1)
    method.initialize(to: PyMethodDef(
        ml_name: strdup(name),
        ml_meth: function,
        ml_flags: Int32(METH_VARARGS),
        ml_doc: strdup(documentation)
    ))
    return method
}

/// The destructor registered for `type` or, when Python subclassed it, for
/// the ancestor that was created from Swift.
///
/// `tp_base` is the base that decides an instance's layout, and a created type
/// always is that for its subclasses -- it is the one that added storage, and
/// CPython refuses a second base that wants its own. Walking it is pointer
/// chasing: no allocation, which is what a destructor can afford.
@MainActor
private func destructor(
    of type: UnsafeMutablePointer<PyTypeObject>?
) -> (@convention(c) (UnsafeMutableRawPointer?) -> Void)? {
    var current = type
    while let candidate = current {
        let object = UnsafeMutableRawPointer(candidate)
            .assumingMemoryBound(to: CPython.PyObject.self)
        if let dtor = destructors[object] {
            return dtor
        }
        current = candidate.pointee.tp_base
    }
    return nil
}

/// `tp_dealloc` for every created type: hand the Swift value to that type's
/// destructor, then free the object the way a heap type must.
private let deallocate: @convention(c) (PyRef?) -> Void = { object in
    guard let object else { return }
    let type = object.pointee.ob_type
    let crossing = GILBound(type)
    let payload = GILBound(
        UnsafeMutableRawPointer(object)
            .advanced(by: userdataOffset)
            .assumingMemoryBound(to: UInt8.self)
    )

    // assumeIsolated is the guard rail, not ceremony: a decref from another
    // thread traps here instead of corrupting the interpreter.
    MainActor.assumeIsolated {
        destructor(of: crossing.pointer)?(UnsafeMutableRawPointer(payload.pointer))
    }

    if let type,
       let free = PyType_GetSlot(type, Py_tp_free) {
        unsafeBitCast(free, to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)(
            UnsafeMutableRawPointer(object)
        )
    }
    // A heap type is kept alive by its instances.
    Py_DecRef(type.map { UnsafeMutableRawPointer($0).assumingMemoryBound(to: CPython.PyObject.self) })
}
