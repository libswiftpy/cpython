import CPython

/// `PythonError.type` is a name here, where pocketpy makes it a `PyType`. The
/// bindings compare it against these spellings, so they exist as constants.
public extension String {
    static let AssertionError = "AssertionError"
    static let KeyError = "KeyError"
    static let RuntimeError = "RuntimeError"
    static let StopIteration = "StopIteration"
    static let TypeError = "TypeError"
    static let ValueError = "ValueError"
}
