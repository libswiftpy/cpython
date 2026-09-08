import Czlib
import PythonModules

public extension PythonModule {
    /// `zlib`, compiled by SwiftPM and linked against the system libz.
    ///
    /// Also what `zipimport` needs to read a compressed zip: without it only
    /// stored entries can be imported.
    static var zlib: PythonModule {
        PythonModule(builtins: [
            Builtin("zlib", unsafeBitCast(CzlibInitializer(), to: PythonModuleInitializer.self))
        ])
    }
}
