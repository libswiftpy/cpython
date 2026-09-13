import Foundation
import PackagePlugin

/// Zips the stdlib listed in the target's modules.txt into a resource, with
/// bytecode compiled by the python that build.sh made.
@main
struct StageStdlib: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let package = context.package.directoryURL
        let manifest = target.directoryURL.appending(path: "modules.txt")
        let script = package.appending(path: "Swift/stage_stdlib.py")
        let lib = package.appending(path: "Lib")
        let python = package.appending(path: "cross-build/\(hostArchitecture)-apple-darwin/python.exe")
        let output = context.pluginWorkDirectoryURL.appending(path: "stdlib.zip")

        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw PluginError.missingPython(python.path)
        }

        return [.buildCommand(
            displayName: "Staging the Python stdlib",
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
