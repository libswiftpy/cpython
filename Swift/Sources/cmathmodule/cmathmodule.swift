import Ccmath
import PythonModules

public extension PythonModule {
    /// Native cmath support compiled from CPython sources by SwiftPM.
    static var cmath: PythonModule {
        PythonModule(builtins: [
            Builtin("cmath", unsafeBitCast(CcmathInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
