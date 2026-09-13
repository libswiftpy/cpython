import Foundation
import PythonModules

public extension PythonModule {
    /// The pure-Python stdlib modules the package ships, zipped by the
    /// StageStdlib plugin from modules.txt. Everything else the interpreter
    /// needs is frozen into libpython.
    static var stdlib: PythonModule {
        let archive = Bundle.module.url(forResource: "stdlib", withExtension: "zip")
        return PythonModule(searchPaths: archive.map { [$0.path] } ?? [])
    }
}
