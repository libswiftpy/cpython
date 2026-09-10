import Foundation
import PythonModules

public extension PythonModule {
    /// The pure-Python stdlib modules the package ships, staged by build.sh.
    /// Everything else the interpreter needs is frozen into libpython.
    static var stdlib: PythonModule {
        // The files sit in a subdirectory of the bundle: copying them into its
        // root would mean listing every module in Package.swift.
        let directory = Bundle.module.resourceURL?
            .appendingPathComponent("stdlib", isDirectory: true)
        return PythonModule(searchPaths: directory.map { [$0.path] } ?? [])
    }
}
