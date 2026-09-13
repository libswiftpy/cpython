import Cpyexpat
import PythonModules

public extension PythonModule {
    /// Native pyexpat support compiled from CPython sources by SwiftPM.
    static var pyexpat: PythonModule {
        PythonModule(builtins: [
            Builtin("pyexpat", unsafeBitCast(CpyexpatInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
