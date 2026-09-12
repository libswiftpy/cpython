import Clsprof
import PythonModules

public extension PythonModule {
    /// Native profiling support compiled from CPython sources by SwiftPM.
    static var lsprof: PythonModule {
        PythonModule(builtins: [
            Builtin("_lsprof", unsafeBitCast(ClsprofInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
