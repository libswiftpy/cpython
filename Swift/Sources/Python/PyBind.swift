/// The binding namespace, spelled like SwiftPy's. Only the state lives here:
/// the argument marshalling is shared code, written against ``PyArguments``.
@MainActor
public enum PyBind {
    /// Cleared before an overload is tried and set once its arguments cast, so
    /// a failure can tell "wrong overload" from "wrong call".
    public static var overloadArgumentsMatched = true
}
