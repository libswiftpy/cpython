import Foundation
import PythonModules

public extension PythonModule {
    /// `_apple_support`, which iOS builds import at startup to route stdout
    /// and stderr into the system log.
    static var appleSupport: PythonModule {
        PythonModule(searchPaths: Bundle.module.resourceURL.map { [$0.path] } ?? [])
    }
}
