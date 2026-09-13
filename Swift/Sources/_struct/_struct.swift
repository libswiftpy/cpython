import Cstruct
import PythonModules

public extension PythonModule {
    /// Native _struct support compiled from CPython sources by SwiftPM.
    static var `struct`: PythonModule {
        PythonModule(builtins: [
            Builtin("_struct", unsafeBitCast(CstructInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
