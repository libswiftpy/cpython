import Foundation
import PythonModules

public extension PythonModule {
    /// The `encodings` package, which the interpreter imports while starting.
    static var encodings: PythonModule {
        PythonModule(searchPaths: Bundle.module.resourceURL.map { [$0.path] } ?? [])
    }
}
