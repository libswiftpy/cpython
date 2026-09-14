import Cposixsubprocess
import PythonModules

public extension PythonModule {
    /// Native _posixsubprocess support compiled from CPython sources by SwiftPM.
    static var posixSubprocess: PythonModule {
        PythonModule(builtins: [
            Builtin("_posixsubprocess", unsafeBitCast(CposixsubprocessInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
