import Cbinascii
import PythonModules

public extension PythonModule {
    /// Native binascii support compiled from CPython sources by SwiftPM.
    static var binascii: PythonModule {
        PythonModule(builtins: [
            Builtin("binascii", unsafeBitCast(CbinasciiInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
