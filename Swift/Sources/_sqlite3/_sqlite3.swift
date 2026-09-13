import Csqlite3
import PythonModules

public extension PythonModule {
    /// Native _sqlite3 support compiled from CPython sources by SwiftPM.
    static var sqlite3: PythonModule {
        PythonModule(builtins: [
            Builtin("_sqlite3", unsafeBitCast(Csqlite3Initializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
