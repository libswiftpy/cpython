import CPython

/// A pointer the compiler will let cross into the main actor.
///
/// Unchecked because a pointer cannot be made `Sendable`: the stdlib already
/// states that conformance, so a second one -- even conditional -- is ignored.
///
/// What makes it sound is the interpreter's own rule. CPython only ever calls
/// back on the thread that holds the GIL, this package never hands the GIL
/// over, and that thread is the one the main actor runs on. A pointer that
/// arrives from CPython therefore cannot be seen from anywhere else.
struct GILBound<Pointee>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Pointee>?

    init(_ pointer: UnsafeMutablePointer<Pointee>?) {
        self.pointer = pointer
    }
}
