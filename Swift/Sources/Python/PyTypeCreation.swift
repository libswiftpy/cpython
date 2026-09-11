import CPython
import Foundation

/// What a created type needs at destruction time. Kept aside because a
/// `@convention(c)` slot cannot capture anything.
@MainActor
private var destructors: [PyRef: @convention(c) (UnsafeMutableRawPointer?) -> Void] = [:]

/// Every type ``PyAPI/newtype(name:base:module:dtor:)`` made, so one can be
/// recognised when it turns up as somebody's base.
@MainActor
private var createdTypes: Set<PyRef> = []

/// Where a created type keeps its Swift value: right past the object header.
/// Fixed rather than per-type so a Python subclass, whose own payload CPython
/// lays out after ours, still finds it.
private let userdataOffset = MemoryLayout<CPython.PyObject>.size

@MainActor
public extension PyAPI {
    /// Creates a heap type, the counterpart of pocketpy's `py_newtype`.
    ///
    /// Instances carry `storage` bytes of Swift userdata, which is what a
    /// binding keeps its Swift value in: a pointer for a class, the value
    /// itself for a struct. Only the size varies -- the offset is fixed, so a
    /// subclass still finds it.
    ///
    /// `base` is either a type with no storage of its own, or another created
    /// type -- those share the one userdata slot, which is right: an object has
    /// one Swift value, whichever class in the chain put it there. Anything
    /// else would land on the same bytes.
    func newtype(
        name: String,
        base: PyType = .object,
        module: PyModule? = nil,
        storage: Int = MemoryLayout<UnsafeMutableRawPointer>.size,
        dtor: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = nil
    ) -> PyType? {
        let baseType = UnsafeMutableRawPointer(base.reference)
            .assumingMemoryBound(to: PyTypeObject.self)
        precondition(
            createdTypes.contains(base.reference)
                || baseType.pointee.tp_basicsize <= userdataOffset,
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

        // A subclass must be at least as large as the base it shares the slot
        // with, whatever it asked for itself.
        let size = max(Int(baseType.pointee.tp_basicsize), userdataOffset + storage)

        // The dotted name is how a spec names its module: a bare one draws a
        // DeprecationWarning at creation. A type made without a module is a
        // builtin, the way pocketpy's are.
        let moduleName = module.flatMap { $0.__name__ as String? } ?? "builtins"
        var specification = PyType_Spec(
            name: strdup(moduleName + "." + name),
            basicsize: Int32(size),
            itemsize: 0,
            flags: UInt32(UInt(Py_TPFLAGS_DEFAULT) | UInt(Py_TPFLAGS_BASETYPE)),
            slots: slots
        )

        guard let object = PyType_FromSpec(&specification) else {
            PyErr_Clear()
            return nil
        }

        createdTypes.insert(object)
        if let dtor {
            destructors[object] = dtor
        }
        if let module {
            module[dynamicMember: name] = PyObject(retaining: object)
        }
        return PyType(reference: object, name: name)
    }

    /// A new instance of `type` carrying `value` in its userdata. The
    /// counterpart of pocketpy's `newobject(_:type:out:slots:)`.
    func newobject<Value>(_ value: Value, type: PyType) -> PyObject? {
        guard let object = newobject(type: type) else { return nil }
        object.userdata.assumingMemoryBound(to: Value.self).initialize(to: value)
        return object
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

        // Python treats __new__ as an implicit staticmethod: it is called with
        // the class, and a method descriptor for this type would refuse one.
        if name == "__new__" {
            staticmethod(signature, docstring, function: block)
            return
        }

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

        // Set on the type, the def is a method and binds self; the raw
        // descriptor it forwards to then binds it again from the arguments.
        if let wrapper = signatureWrapper(signature, docstring: docstring, around: descriptor) {
            defer { Py_DecRef(wrapper) }
            set(name, to: wrapper)
            return
        }
        set(name, to: descriptor)
    }

    /// Binds a dunder, e.g. `__repr__`.
    func magic(_ name: String, function: PyAPI.CFunction) {
        self.function("\(name)(self)", block: function)
    }

    /// Binds a property. Both halves are ordinary bindings, so they reach the
    /// descriptor through trampolines: a getset getter is handed `(self,
    /// closure)` and a setter `(self, value, closure)`, neither of which is the
    /// `(self, args)` a binding reads.
    func property(
        _ name: String,
        _ docstring: String? = nil,
        getter: PyAPI.CFunction,
        setter: PyAPI.CFunction? = nil
    ) {
        let definition = getSetTable(
            name: name,
            documentation: docstring,
            getter: getter,
            setter: setter
        )
        guard let descriptor = PyDescr_NewGetSet(
            UnsafeMutableRawPointer(reference).assumingMemoryBound(to: PyTypeObject.self),
            definition
        ) else {
            PyErr_Clear()
            return
        }
        defer { Py_DecRef(descriptor) }
        set(name, to: descriptor)
    }

    /// Binds a static method: a plain function in the type's dict, wrapped so
    /// Python does not hand it a receiver.
    func staticmethod(
        _ signature: String,
        _ docstring: String? = nil,
        function: PyAPI.CFunction
    ) {
        let name = String(signature.prefix { $0 != "(" })
            .trimmingCharacters(in: .whitespaces)

        // The type is the function's __self__, so inspect drops the `$type`
        // slot; the binding itself never reads it.
        guard let callable = PyCFunction_NewEx(
            methodTable(
                name: name,
                documentation: clinicDocumentation(
                    signature: signature,
                    docstring: docstring,
                    receiver: "$type"
                ),
                function: function
            ),
            reference,
            nil
        ) else {
            PyErr_Clear()
            return
        }
        defer { Py_DecRef(callable) }

        let function = signatureWrapper(signature, docstring: docstring, around: callable) ?? {
            Py_IncRef(callable)
            return callable
        }()
        defer { Py_DecRef(function) }

        // Without this the function would still bind a receiver when it is
        // reached through an instance.
        guard let wrapped = PyStaticMethod_New(function) else {
            PyErr_Clear()
            return
        }
        defer { Py_DecRef(wrapped) }
        set(name, to: wrapped)
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

/// A Python `def` with the binding's own signature, forwarding to `raw`, for
/// a signature with defaults or star parameters -- CPython's `METH_VARARGS`
/// hands over positionals only, so keywords and defaults have to be bound by
/// Python itself. Nil, and nothing to release, when the signature needs none
/// of that. See `_wrap` in PythonCell.swift.
@MainActor
func signatureWrapper(_ signature: String, docstring: String?, around raw: PyRef) -> PyRef? {
    let head = signature.components(separatedBy: "->").first ?? signature
    guard head.contains("=") || head.contains("*") else { return nil }

    guard let wrap = try? PyRuntime.helper("_wrap") else { return nil }
    defer { Py_DecRef(wrap) }

    guard let arguments = PyTuple_New(3),
          let text = PyUnicode_FromString(signature) else {
        PyErr_Clear()
        return nil
    }
    defer { Py_DecRef(arguments) }
    // PyTuple_SetItem steals each reference.
    PyTuple_SetItem(arguments, 0, text)
    Py_IncRef(raw)
    PyTuple_SetItem(arguments, 1, raw)
    PyTuple_SetItem(arguments, 2, docstring.flatMap { PyUnicode_FromString($0) }
        ?? Py_GetConstant(UInt32(Py_CONSTANT_NONE)))

    guard let function = PyObject_Call(wrap, arguments, nil) else {
        // A signature the def syntax refuses is a bug in the binding; say so
        // rather than binding something that ignores its keywords.
        PyErr_Print()
        return nil
    }
    return function
}

/// Allocated once per binding and never freed: CPython keeps referring to it
/// for as long as the descriptor lives.
private struct PropertyBinding {
    let getter: PyAPI.CFunction
    let setter: PyAPI.CFunction?
}

/// Reshapes a getset call into the `(self, args)` a binding reads. The pair it
/// forwards to travels in the descriptor's own `closure` field, which is the
/// only place a `@convention(c)` slot can pick anything up.
private let propertyGetter: @convention(c) (
    PyRef?, UnsafeMutableRawPointer?
) -> PyRef? = { object, closure in
    guard let closure else { return nil }
    return closure.assumingMemoryBound(to: PropertyBinding.self).pointee.getter(object, nil)
}

private let propertySetter: @convention(c) (
    PyRef?, PyRef?, UnsafeMutableRawPointer?
) -> Int32 = { object, value, closure in
    guard let closure,
          let setter = closure.assumingMemoryBound(to: PropertyBinding.self).pointee.setter
    else { return -1 }

    // A deletion arrives as a nil value, which no binding takes.
    guard let value, let arguments = PyTuple_New(1) else {
        MainActor.assumeIsolated {
            PyAPI.raise(.TypeError("cannot delete this attribute"))
        }
        return -1
    }
    defer { Py_DecRef(arguments) }

    // PyTuple_SetItem steals the reference it is given.
    Py_IncRef(value)
    PyTuple_SetItem(arguments, 0, value)

    guard let result = setter(object, arguments) else { return -1 }
    Py_DecRef(result)
    return 0
}

/// Allocated once per binding and never freed, the way the method table is.
private func getSetTable(
    name: String,
    documentation: String?,
    getter: @escaping PyAPI.CFunction,
    setter: PyAPI.CFunction?
) -> UnsafeMutablePointer<PyGetSetDef> {
    let binding = UnsafeMutablePointer<PropertyBinding>.allocate(capacity: 1)
    binding.initialize(to: PropertyBinding(getter: getter, setter: setter))

    let definition = UnsafeMutablePointer<PyGetSetDef>.allocate(capacity: 1)
    definition.initialize(to: PyGetSetDef(
        name: strdup(name),
        get: propertyGetter,
        set: setter == nil ? nil : propertySetter,
        doc: documentation.map { strdup($0) },
        closure: UnsafeMutableRawPointer(binding)
    ))
    return definition
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
