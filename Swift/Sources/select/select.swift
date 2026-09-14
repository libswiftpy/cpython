import Cselect
import PythonModules

public extension PythonModule {
    /// Native select support compiled from CPython sources by SwiftPM.
    static var select: PythonModule {
        PythonModule(builtins: [
            Builtin("select", unsafeBitCast(CselectInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
