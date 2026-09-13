import Cmd5
import PythonModules

public extension PythonModule {
    /// Native _md5 support compiled from CPython sources by SwiftPM.
    static var md5: PythonModule {
        PythonModule(builtins: [
            Builtin("_md5", unsafeBitCast(Cmd5Initializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
