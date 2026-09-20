import CPython
import Cthunks
import Foundation

/// Every binding, by the slot of the C thunk CPython calls for it.
///
/// A binding written inside a main-actor type is a main-actor closure, and
/// asserts as much when it is entered. CPython calls it from whichever thread
/// runs Python, so the thunk comes through here first, and here the call is
/// taken to main: the same hop ``PyAPI/return(_:)`` would make, one level up.
enum Bindings {
    /// Written on main while types are set up, read under the GIL.
    private nonisolated(unsafe) static var registered: [PyAPI.CFunction] = []

    /// The C entry point for `function`.
    static func entryPoint(for function: @escaping PyAPI.CFunction) -> PyCFunction {
        let slot = registered.count
        guard let thunk = swiftpy_thunk(Int32(slot)) else {
            preconditionFailure("more than \(SWIFTPY_THUNK_COUNT) bindings; raise the thunk count")
        }
        registered.append(function)
        // Opaque in the header, which is built without Python.h.
        return unsafeBitCast(thunk, to: PyCFunction.self)
    }

    fileprivate static func call(_ slot: Int32, _ receiver: PyRef?, _ arguments: PyRef?) -> PyRef? {
        let function = registered[Int(slot)]
        let receiver = GILBound(receiver)
        let arguments = GILBound(arguments)
        return onMainBinding { function(receiver.pointer, arguments.pointer) }
    }
}

// Public, or a release link strips what only the C side refers to.
@_cdecl("swiftpy_dispatch")
public func swiftpy_dispatch(
    _ slot: Int32, _ receiver: UnsafeMutableRawPointer?, _ arguments: UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? {
    let result = Bindings.call(
        slot,
        receiver?.assumingMemoryBound(to: CPython.PyObject.self),
        arguments?.assumingMemoryBound(to: CPython.PyObject.self)
    )
    return result.map { UnsafeMutableRawPointer($0) }
}
