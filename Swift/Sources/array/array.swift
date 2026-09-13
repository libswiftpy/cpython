import Carray
import PythonModules

public extension PythonModule {
    /// Native array support compiled from CPython sources by SwiftPM.
    static var array: PythonModule {
        PythonModule(builtins: [
            Builtin("array", unsafeBitCast(CarrayInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
