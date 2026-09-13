import Csha1
import PythonModules

public extension PythonModule {
    /// Native _sha1 support compiled from CPython sources by SwiftPM.
    static var sha1: PythonModule {
        PythonModule(builtins: [
            Builtin("_sha1", unsafeBitCast(Csha1Initializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
