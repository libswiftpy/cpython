import Foundation
import PackagePlugin

/// Zips the modules listed in the target's modules.txt into a resource, with
/// bytecode compiled by the python that build.sh made. A `# source: <dir>` line
/// names where a package outside cpython keeps them; the stdlib is in `Lib`.
@main
struct StageStdlib: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let cpython = (context.package.dependencies.first { $0.package.id == "cpython" }?.package ?? context.package).directoryURL
        let manifest = target.directoryURL.appending(path: "modules.txt")
        let script = cpython.appending(path: "Swift/stage_stdlib.py")
        let source = try String(contentsOf: manifest, encoding: .utf8).split(separator: "\n")
            .first { $0.hasPrefix("# source: ") }?.dropFirst("# source: ".count)
        let lib = context.package.directoryURL.appending(path: source.map(String.init) ?? "Lib")
        let python = cpython.appending(path: "cross-build/\(hostArchitecture)-apple-darwin/python.exe")
        let output = context.pluginWorkDirectoryURL.appending(path: "\(target.name).zip")

        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw PluginError.missingPython(python.path)
        }

        return [.buildCommand(
            displayName: "Staging \(target.name)'s Python modules",
            executable: python,
            arguments: ["-I", "-B", script.path, lib.path, manifest.path, output.path],
            inputFiles: [manifest, script],
            outputFiles: [output]
        )]
    }

    private var hostArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    enum PluginError: Error, CustomStringConvertible {
        case missingPython(String)
        var description: String {
            switch self {
            case .missingPython(let path):
                "no host python at \(path); run Swift/build.sh first"
            }
        }
    }
}
