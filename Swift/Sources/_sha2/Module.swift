import Csha2
import PythonModules

public extension PythonModule {
    /// Native _sha2 support compiled from CPython sources by SwiftPM.
    static var sha2: PythonModule {
        PythonModule(builtins: [
            Builtin("_sha2", unsafeBitCast(Csha2Initializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
