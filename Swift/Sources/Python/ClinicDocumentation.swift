import Foundation

/// Turns SwiftPy's signature string into what CPython reads a builtin's
/// signature out of: the argument clinic's marker at the head of the docstring.
///
/// It is the only way a builtin gets one. `builtin_function_or_method` has no
/// `__dict__`, so `__annotations__` cannot be attached to it -- but the text
/// signature carries the annotations through, and `inspect` reads it.
///
///     add(a: int, b: int) -> int   ->   add($module, a: int, b: int, /)
///                                       --
///
///                                       <docstring>
func clinicDocumentation(
    signature: String,
    docstring: String?,
    receiver: String
) -> String {
    guard let open = signature.firstIndex(of: "("),
          let close = signature.lastIndex(of: ")"),
          open < close else {
        return docstring ?? signature
    }

    let name = signature[..<open].trimmingCharacters(in: .whitespaces)
    var parameters = signature[signature.index(after: open)..<close]
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    // The clinic names the receiver, and a METH_VARARGS binding takes
    // everything positionally.
    if parameters.first?.hasPrefix("self") == true {
        parameters[0] = "$self"
    } else {
        parameters.insert(receiver, at: 0)
    }

    return """
        \(name)(\(parameters.joined(separator: ", ")), /)
        --

        \(docstring ?? "")
        """
}
