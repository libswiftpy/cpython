import CPIL
import Foundation
import PythonModules

public extension PythonModule {
    /// Pillow, as `PIL`: its C modules built in, the package from the bundle.
    static var pil: PythonModule {
        PythonModule(
            builtins: [
                Builtin("PIL._imaging", unsafeBitCast(CPILInitializer0(), to: PythonModuleInitializer.self)),
                Builtin("PIL._imagingft", unsafeBitCast(CPILInitializer1(), to: PythonModuleInitializer.self)),
                Builtin("PIL._webp", unsafeBitCast(CPILInitializer2(), to: PythonModuleInitializer.self)),
                Builtin("PIL._imagingmath", unsafeBitCast(CPILInitializer3(), to: PythonModuleInitializer.self)),
                Builtin("PIL._imagingmorph", unsafeBitCast(CPILInitializer4(), to: PythonModuleInitializer.self)),
            ],
            searchPaths: Bundle.module.url(forResource: "PIL", withExtension: "zip").map { [$0.path] } ?? []
        )
    }
}
