import CPython

/// Keeps owned references alive for a little while, so a call can hand back a
/// raw ``PyRef`` the way pocketpy's `retval` register does.
///
/// pocketpy's borrowing rules are what SwiftPy's bindings were written
/// against: what a call returns stays valid until the next few calls. A ring
/// gives that here; anything that must outlive it goes through `py.retain`.
@MainActor
enum PyHold {
    private static let capacity = 64
    private static var slots = [PyRef?](repeating: nil, count: capacity)
    private static var next = 0

    /// Takes ownership of `reference` and returns it as a borrowed pointer.
    static func take(_ reference: PyRef) -> PyRef {
        if let evicted = slots[next] {
            Py_DecRef(evicted)
        }
        slots[next] = reference
        next = (next + 1) % capacity
        return reference
    }
}
