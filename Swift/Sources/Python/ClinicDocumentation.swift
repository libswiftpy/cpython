import Foundation

/// Turns SwiftPy's signature string into what CPython reads a builtin's
/// signature out of: the argument clinic's marker at the head of the docstring.
///
/// It is the only way a builtin gets one: `builtin_function_or_method` has no
/// `__dict__` for annotations, and `inspect` refuses a text signature that
/// carries any, so only names and defaults survive.
///
///     add(a: int, b: int = 1) -> int   ->   add($module, a, b=1, /)
///                                           --
///
///                                           <docstring>
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
        .map(withoutAnnotation)

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

/// `name: type = default` as the clinic spells it: `name=default`.
private func withoutAnnotation(_ parameter: String) -> String {
    let halves = parameter.split(separator: "=", maxSplits: 1)
    let name = halves[0].split(separator: ":", maxSplits: 1)[0]
        .trimmingCharacters(in: .whitespaces)
    guard halves.count == 2 else { return name }
    return name + "=" + halves[1].trimmingCharacters(in: .whitespaces)
}
