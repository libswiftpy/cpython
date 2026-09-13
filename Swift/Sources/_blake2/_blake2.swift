import Cblake2
import PythonModules

public extension PythonModule {
    /// Native _blake2 support compiled from CPython sources by SwiftPM.
    static var blake2: PythonModule {
        PythonModule(builtins: [
            Builtin("_blake2", unsafeBitCast(Cblake2Initializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
