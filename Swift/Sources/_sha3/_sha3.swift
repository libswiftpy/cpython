import Csha3
import PythonModules

public extension PythonModule {
    /// Native _sha3 support compiled from CPython sources by SwiftPM.
    static var sha3: PythonModule {
        PythonModule(builtins: [
            Builtin("_sha3", unsafeBitCast(Csha3Initializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
