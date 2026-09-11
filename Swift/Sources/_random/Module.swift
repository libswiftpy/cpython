import Crandom
import PythonModules

public extension PythonModule {
    /// Native _random support compiled from CPython sources by SwiftPM.
    static var random: PythonModule {
        PythonModule(builtins: [
            Builtin("_random", unsafeBitCast(CrandomInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
