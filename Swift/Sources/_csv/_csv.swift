import Ccsv
import PythonModules

public extension PythonModule {
    /// Native _csv support compiled from CPython sources by SwiftPM.
    static var csv: PythonModule {
        PythonModule(builtins: [
            Builtin("_csv", unsafeBitCast(CcsvInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
