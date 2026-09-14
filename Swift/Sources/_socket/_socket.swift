import Csocket
import PythonModules

public extension PythonModule {
    /// Native _socket support compiled from CPython sources by SwiftPM.
    static var socket: PythonModule {
        PythonModule(builtins: [
            Builtin("_socket", unsafeBitCast(CsocketInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
