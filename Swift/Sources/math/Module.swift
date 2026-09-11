import Cmath
import PythonModules

public extension PythonModule {
    /// Native math support compiled from CPython sources by SwiftPM.
    static var math: PythonModule {
        PythonModule(builtins: [
            Builtin("math", unsafeBitCast(CmathInitializer0(), to: PythonModuleInitializer.self)),
            Builtin("_math_integer", unsafeBitCast(CmathInitializer1(), to: PythonModuleInitializer.self))
        ])
    }
}
