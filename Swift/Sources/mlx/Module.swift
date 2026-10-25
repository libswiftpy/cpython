import Cmlxcore
import Foundation
import PythonModules

public extension PythonModule {
    /// Apple's MLX: `mlx.core` built in, `mlx.nn` and the rest from the bundle.
    static var mlx: PythonModule {
        PythonModule(
            builtins: [
                Builtin("mlx.core", unsafeBitCast(CmlxcoreInitializer0(), to: PythonModuleInitializer.self)),
            ],
            searchPaths: Bundle.module.resourceURL.map { [$0.path] } ?? []
        )
    }
}
