import Cunicodedata
import PythonModules

public extension PythonModule {
    /// Native unicodedata support compiled from CPython sources by SwiftPM.
    static var unicodedata: PythonModule {
        PythonModule(builtins: [
            Builtin("unicodedata", unsafeBitCast(CunicodedataInitializer0(), to: PythonModuleInitializer.self))
        ])
    }
}
