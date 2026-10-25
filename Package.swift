// swift-tools-version: 6.4
import Foundation
import PackageDescription

// The interpreter staged by Swift/build.sh. Absolute, because SwiftPM makes no
// promise about the working directory of compiler and linker invocations.
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let distribution = URL(fileURLWithPath: packageDirectory)
    .appendingPathComponent("Swift/.cpython-dist")

// What libpython itself needs. These mirror the `Libs.private` line of
// Misc/python-embed.pc; Swift/build.sh prints the flags configure actually
// decided on, so compare the two if linking ever fails on a new platform.
// (LINKFORSHARED's `-stack_size` is left out: the linker rejects it for the
// test bundle. Add it to your own executable if you need deep recursion.)
let systemLibraries: [LinkerSetting] = [
    // By path, not -lpython: the products directory holds this package's own
    // libPython.a, which -lpython finds first on a case-insensitive disk.
    .unsafeFlags(
        ["\(distribution.path)/lib/libpython.a",
         "-liconv", "-ldl", "-framework", "CoreFoundation"],
        .when(platforms: [.macOS])
    ),
    // No -L/-lpython for iOS: SwiftPM cannot tell a simulator destination from
    // a device one, and rejects build-setting references like $(PLATFORM_NAME)
    // in target flags, so it cannot pick between the two staged slices. The
    // app supplies that with per-SDK LIBRARY_SEARCH_PATHS and -lpython in
    // OTHER_LDFLAGS; the rest of the flags do not vary, so they live here.
    // See Swift/README.md.
    .unsafeFlags(
        ["-liconv", "-ldl", "-lpthread", "-framework", "CoreFoundation"],
        .when(platforms: [.iOS, .visionOS])
    ),
    .unsafeFlags(
        ["-ldl", "-lm", "-lutil", "-Xlinker", "-export-dynamic"],
        .when(platforms: [.linux, .android])
    ),
]

// CPython's headers, for each platform's staged build.
let pythonHeaders: [CSetting] = [
    .unsafeFlags([
        "-I\(distribution.path)/include/python",
        "-I\(distribution.path)/include/python/internal",
    ], .when(platforms: [.macOS])),
    .unsafeFlags([
        "-I\(packageDirectory)/Swift/.cpython-dist-iphoneos/include/python",
        "-I\(packageDirectory)/Swift/.cpython-dist-iphoneos/include/python/internal",
    ], .when(platforms: [.iOS])),
    .unsafeFlags([
        "-I\(packageDirectory)/Swift/.cpython-dist-xros/include/python",
        "-I\(packageDirectory)/Swift/.cpython-dist-xros/include/python/internal",
    ], .when(platforms: [.visionOS])),
]

// A stdlib C module compiles the way CPython compiles a builtin: against both
// the public headers and Include/internal.
let moduleSettings: [CSetting] = [.define("Py_BUILD_CORE_BUILTIN")] + pythonHeaders

let package = Package(
    name: "cpython",
    // 15.4 / 18.4 / 2.4 are what isolated `deinit` needs.
    platforms: [.macOS("15.4"), .iOS("18.4"), .visionOS("2.4")],
    products: [
        .library(name: "Python", targets: ["Python"]),
        .executable(name: "pyrun", targets: ["pyrun"]),
        .executable(name: "pybench", targets: ["pybench"]),
    ],
    // Off by default: MLX adds about 18 MB, and nothing of it is linked
    // without the trait. Swift/build-mlx.sh stages what it needs.
    traits: [
        .trait(name: "mlx", description: "Build in Apple's MLX as mlx.core, with mlx.nn and mlx.optimizers."),
    ],
    targets: [
        // The C API itself, imported through a module map.
        .systemLibrary(name: "CPython", path: "Swift/Sources/CPython"),

        // How a module describes itself. Its own target so that module targets
        // depend on this rather than on the interpreter wrapper — which also
        // lets `Python` depend on the modules it needs to start.
        .target(
            name: "PythonModules",
            dependencies: ["CPython"],
            path: "Swift/Sources/PythonModules"
        ),

        // The stdlib the interpreter cannot start without, one target per
        // module, named after the module it carries. SwiftPM packs each into
        // its own resource bundle, which Xcode embeds in the app — the only
        // place a sandboxed app can read them from. Staged by Swift/build.sh.
        .target(
            name: "encodings",
            dependencies: ["PythonModules"],
            path: "Swift/Sources/encodings",
            resources: [.copy("encodings")]
        ),
        .target(
            name: "_apple_support",
            dependencies: ["PythonModules"],
            path: "Swift/Sources/_apple_support",
            resources: [.copy("_apple_support.py")]
        ),

        // The rest of the pure-Python stdlib the package ships, as one zip on
        // sys.path: zipimport loads the bytecode in it without a compile.
        // The plugin builds it from Swift/Sources/stdlib/modules.txt.
        .target(
            name: "stdlib",
            dependencies: ["PythonModules"],
            path: "Swift/Sources/stdlib",
            exclude: ["modules.txt"],
            plugins: [.plugin(name: "StageStdlib")]
        ),
        .plugin(
            name: "StageStdlib",
            capability: .buildTool(),
            path: "Plugins/StageStdlib"
        ),

        // One C entry point per binding, so a Swift closure can be handed to
        // CPython as a function pointer of its own. See Bindings.swift.
        .target(
            name: "Cthunks",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_swiftpy/thunks/thunks.c"],
            publicHeadersPath: "_swiftpy/thunks",
            cSettings: moduleSettings
        ),

        // A thin Swift face on top of it.
        .target(
            name: "Python",
            dependencies: ["CPython", "Cthunks", "PythonModules", "encodings", "_apple_support", "stdlib", "zlibmodule", "math", "_random", "_sha2", "_lsprof",
                           "_struct", "binascii", "_csv", "array", "cmathmodule", "_md5", "_sha1", "_sha3", "_blake2", "_sqlite3", "unicodedata", "pyexpat",
                           "select", "_socket", .target(name: "_posixsubprocess", condition: .when(platforms: [.macOS])), "PIL"],
            path: "Swift/Sources/Python",
            linkerSettings: systemLibraries
        ),

        // zlib: C only, so the compiled half and the Swift declaration are
        // two targets. zipimport needs it to read a compressed zip.
        .target(
            name: "Czlib",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["zlibmodule.c", "_swiftpy/zlib/shim.c"],
            publicHeadersPath: "_swiftpy/zlib",
            cSettings: moduleSettings,
            linkerSettings: [.linkedLibrary("z")]
        ),
        // Not `zlib`: Xcode would take that for the SDK's zlib module that
        // zlibmodule.c includes, and warn that Czlib is missing a dependency.
        .target(
            name: "zlibmodule",
            dependencies: ["PythonModules", "Czlib"],
            path: "Swift/Sources/zlibmodule"
        ),

        // Native dependencies of the bundled random module.
        .target(
            name: "Cmath",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["mathmodule.c", "mathintegermodule.c", "_swiftpy/math/shim.c"],
            publicHeadersPath: "_swiftpy/math",
            cSettings: moduleSettings
        ),
        .target(
            name: "math",
            dependencies: ["PythonModules", "Cmath"],
            path: "Swift/Sources/math"
        ),

        .target(
            name: "Crandom",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_randommodule.c", "_swiftpy/_random/shim.c"],
            publicHeadersPath: "_swiftpy/_random",
            cSettings: moduleSettings
        ),
        .target(
            name: "_random",
            dependencies: ["PythonModules", "Crandom"],
            path: "Swift/Sources/_random"
        ),

        .target(
            name: "Csha2",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["sha2module.c", "_hacl/Hacl_Hash_SHA2.c", "_swiftpy/_sha2/shim.c"],
            publicHeadersPath: "_swiftpy/_sha2",
            cSettings: moduleSettings + [.headerSearchPath("_hacl"), .headerSearchPath("_hacl/include")]
        ),
        .target(
            name: "_sha2",
            dependencies: ["PythonModules", "Csha2"],
            path: "Swift/Sources/_sha2"
        ),

        // Native dependency of cProfile and profiling.tracing.
        .target(
            name: "Clsprof",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_lsprof.c", "rotatingtree.c", "_swiftpy/_lsprof/shim.c"],
            publicHeadersPath: "_swiftpy/_lsprof",
            cSettings: moduleSettings
        ),
        .target(
            name: "_lsprof",
            dependencies: ["PythonModules", "Clsprof"],
            path: "Swift/Sources/_lsprof"
        ),

        // Optional C modules, each with its size once linked (code + data,
        // arm64) so the trade-off stays visible; drop one together with the
        // Python modules that import it. Small ones behind common imports
        // first: _struct 80 KB, binascii 90, _csv 60, array 110, cmath 60.
        .target(
            name: "Cstruct",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_struct.c", "_swiftpy/_struct/shim.c"],
            publicHeadersPath: "_swiftpy/_struct",
            cSettings: moduleSettings
        ),
        .target(
            name: "_struct",
            dependencies: ["PythonModules", "Cstruct"],
            path: "Swift/Sources/_struct"
        ),

        .target(
            name: "Cbinascii",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["binascii.c", "_swiftpy/binascii/shim.c"],
            publicHeadersPath: "_swiftpy/binascii",
            cSettings: moduleSettings
        ),
        .target(
            name: "binascii",
            dependencies: ["PythonModules", "Cbinascii"],
            path: "Swift/Sources/binascii"
        ),

        .target(
            name: "Ccsv",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_csv.c", "_swiftpy/_csv/shim.c"],
            publicHeadersPath: "_swiftpy/_csv",
            cSettings: moduleSettings
        ),
        .target(
            name: "_csv",
            dependencies: ["PythonModules", "Ccsv"],
            path: "Swift/Sources/_csv"
        ),

        .target(
            name: "Carray",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["arraymodule.c", "_swiftpy/array/shim.c"],
            publicHeadersPath: "_swiftpy/array",
            cSettings: moduleSettings
        ),
        .target(
            name: "array",
            dependencies: ["PythonModules", "Carray"],
            path: "Swift/Sources/array"
        ),

        .target(
            name: "Ccmath",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["cmathmodule.c", "_swiftpy/cmath/shim.c"],
            publicHeadersPath: "_swiftpy/cmath",
            cSettings: moduleSettings
        ),
        // Not `cmath`: that and the math module's `Cmath` collide on a
        // case-insensitive file system.
        .target(
            name: "cmathmodule",
            dependencies: ["PythonModules", "Ccmath"],
            path: "Swift/Sources/cmathmodule"
        ),

        // The rest of hashlib, so md5/sha1/sha3/blake2 work and not only sha2:
        // _md5 40 KB, _sha1 30, _sha3 120, _blake2 310.
        .target(
            name: "Cmd5",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["md5module.c", "_hacl/Hacl_Hash_MD5.c", "_swiftpy/_md5/shim.c"],
            publicHeadersPath: "_swiftpy/_md5",
            cSettings: moduleSettings + [.headerSearchPath("_hacl"), .headerSearchPath("_hacl/include")]
        ),
        .target(
            name: "_md5",
            dependencies: ["PythonModules", "Cmd5"],
            path: "Swift/Sources/_md5"
        ),

        .target(
            name: "Csha1",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["sha1module.c", "_hacl/Hacl_Hash_SHA1.c", "_swiftpy/_sha1/shim.c"],
            publicHeadersPath: "_swiftpy/_sha1",
            cSettings: moduleSettings + [.headerSearchPath("_hacl"), .headerSearchPath("_hacl/include")]
        ),
        .target(
            name: "_sha1",
            dependencies: ["PythonModules", "Csha1"],
            path: "Swift/Sources/_sha1"
        ),

        .target(
            name: "Csha3",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["sha3module.c", "_hacl/Hacl_Hash_SHA3.c", "_swiftpy/_sha3/shim.c"],
            publicHeadersPath: "_swiftpy/_sha3",
            cSettings: moduleSettings + [.headerSearchPath("_hacl"), .headerSearchPath("_hacl/include")]
        ),
        .target(
            name: "_sha3",
            dependencies: ["PythonModules", "Csha3"],
            path: "Swift/Sources/_sha3"
        ),

        .target(
            name: "Cblake2",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["blake2module.c", "_hacl/Hacl_Hash_Blake2s.c", "_hacl/Hacl_Hash_Blake2b.c", "_hacl/Lib_Memzero0.c", "_swiftpy/_blake2/shim.c"],
            publicHeadersPath: "_swiftpy/_blake2",
            cSettings: moduleSettings + [.headerSearchPath("_hacl"), .headerSearchPath("_hacl/include")]
        ),
        .target(
            name: "_blake2",
            dependencies: ["PythonModules", "Cblake2"],
            path: "Swift/Sources/_blake2"
        ),

        // sqlite3 against the system libsqlite3, so the module is 220 KB.
        .target(
            name: "Csqlite3",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_sqlite/blob.c", "_sqlite/connection.c", "_sqlite/cursor.c", "_sqlite/microprotocols.c", "_sqlite/module.c", "_sqlite/prepare_protocol.c", "_sqlite/row.c", "_sqlite/statement.c", "_sqlite/util.c", "_swiftpy/_sqlite3/shim.c"],
            publicHeadersPath: "_swiftpy/_sqlite3",
            cSettings: moduleSettings + [.headerSearchPath("_sqlite")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "_sqlite3",
            dependencies: ["PythonModules", "Csqlite3"],
            path: "Swift/Sources/_sqlite3"
        ),

        // unicodedata carries the Unicode database: 740 KB, the largest here.
        .target(
            name: "Cunicodedata",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["unicodedata.c", "_swiftpy/unicodedata/shim.c"],
            publicHeadersPath: "_swiftpy/unicodedata",
            cSettings: moduleSettings
        ),
        .target(
            name: "unicodedata",
            dependencies: ["PythonModules", "Cunicodedata"],
            path: "Swift/Sources/unicodedata"
        ),

        // pyexpat bundles expat, 520 KB; xml.etree, xml.dom and plistlib parse
        // through it.
        .target(
            name: "Cpyexpat",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["pyexpat.c", "expat/xmlparse.c", "expat/xmlrole.c", "expat/xmltok.c", "_swiftpy/pyexpat/shim.c"],
            publicHeadersPath: "_swiftpy/pyexpat",
            cSettings: moduleSettings + [.headerSearchPath("expat")]
        ),
        .target(
            name: "pyexpat",
            dependencies: ["PythonModules", "Cpyexpat"],
            path: "Swift/Sources/pyexpat"
        ),

        // asyncio imports socket and selectors at module level: select 60 KB,
        // _socket 150. Only subprocess needs _posixsubprocess (30 KB), and only
        // where it can fork, so that one is macOS-only.
        .target(
            name: "Cselect",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["selectmodule.c", "_swiftpy/select/shim.c"],
            publicHeadersPath: "_swiftpy/select",
            cSettings: moduleSettings
        ),
        .target(
            name: "select",
            dependencies: ["PythonModules", "Cselect"],
            path: "Swift/Sources/select"
        ),

        .target(
            name: "Csocket",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["socketmodule.c", "_swiftpy/_socket/shim.c"],
            publicHeadersPath: "_swiftpy/_socket",
            cSettings: moduleSettings
        ),
        .target(
            name: "_socket",
            dependencies: ["PythonModules", "Csocket"],
            path: "Swift/Sources/_socket"
        ),

        .target(
            name: "Cposixsubprocess",
            dependencies: ["CPython"],
            path: "Modules",
            sources: ["_swiftpy/_posixsubprocess/shim.c"],
            publicHeadersPath: "_swiftpy/_posixsubprocess",
            cSettings: moduleSettings
        ),
        .target(
            name: "_posixsubprocess",
            dependencies: ["PythonModules", "Cposixsubprocess"],
            path: "Swift/Sources/_posixsubprocess"
        ),

        // Pillow, from the sources Swift/stage-pillow.sh stages in Modules/_pillow,
        // linked once (about 3 MB): JPEG, PNG through zlib, FreeType fonts, WebP.
        .target(
            name: "Cjpeg",
            path: "Modules/_pillow/jpeg",
            sources: [
                "src/jcapimin.c", "src/wrapper/jcapistd-8.c", "src/wrapper/jcapistd-12.c",
                "src/wrapper/jcapistd-16.c", "src/wrapper/jccoefct-8.c",
                "src/wrapper/jccoefct-12.c", "src/wrapper/jccolor-8.c", "src/wrapper/jccolor-12.c",
                "src/wrapper/jccolor-16.c", "src/wrapper/jcdctmgr-8.c",
                "src/wrapper/jcdctmgr-12.c", "src/wrapper/jcdiffct-8.c",
                "src/wrapper/jcdiffct-12.c", "src/wrapper/jcdiffct-16.c", "src/jchuff.c",
                "src/jcicc.c", "src/jcinit.c", "src/jclhuff.c", "src/wrapper/jclossls-8.c",
                "src/wrapper/jclossls-12.c", "src/wrapper/jclossls-16.c",
                "src/wrapper/jcmainct-8.c", "src/wrapper/jcmainct-12.c",
                "src/wrapper/jcmainct-16.c", "src/jcmarker.c", "src/jcmaster.c", "src/jcomapi.c",
                "src/jcparam.c", "src/jcphuff.c", "src/wrapper/jcprepct-8.c",
                "src/wrapper/jcprepct-12.c", "src/wrapper/jcprepct-16.c",
                "src/wrapper/jcsample-8.c", "src/wrapper/jcsample-12.c",
                "src/wrapper/jcsample-16.c", "src/jctrans.c", "src/jdapimin.c",
                "src/wrapper/jdapistd-8.c", "src/wrapper/jdapistd-12.c",
                "src/wrapper/jdapistd-16.c", "src/jdatadst.c", "src/jdatasrc.c",
                "src/wrapper/jdcoefct-8.c", "src/wrapper/jdcoefct-12.c", "src/wrapper/jdcolor-8.c",
                "src/wrapper/jdcolor-12.c", "src/wrapper/jdcolor-16.c", "src/wrapper/jddctmgr-8.c",
                "src/wrapper/jddctmgr-12.c", "src/wrapper/jddiffct-8.c",
                "src/wrapper/jddiffct-12.c", "src/wrapper/jddiffct-16.c", "src/jdhuff.c",
                "src/jdicc.c", "src/jdinput.c", "src/jdlhuff.c", "src/wrapper/jdlossls-8.c",
                "src/wrapper/jdlossls-12.c", "src/wrapper/jdlossls-16.c",
                "src/wrapper/jdmainct-8.c", "src/wrapper/jdmainct-12.c",
                "src/wrapper/jdmainct-16.c", "src/jdmarker.c", "src/jdmaster.c",
                "src/wrapper/jdmerge-8.c", "src/wrapper/jdmerge-12.c", "src/jdphuff.c",
                "src/wrapper/jdpostct-8.c", "src/wrapper/jdpostct-12.c",
                "src/wrapper/jdpostct-16.c", "src/wrapper/jdsample-8.c",
                "src/wrapper/jdsample-12.c", "src/wrapper/jdsample-16.c", "src/jdtrans.c",
                "src/jerror.c", "src/jfdctflt.c", "src/wrapper/jfdctfst-8.c",
                "src/wrapper/jfdctfst-12.c", "src/wrapper/jfdctint-8.c",
                "src/wrapper/jfdctint-12.c", "src/wrapper/jidctflt-8.c",
                "src/wrapper/jidctflt-12.c", "src/wrapper/jidctfst-8.c",
                "src/wrapper/jidctfst-12.c", "src/wrapper/jidctint-8.c",
                "src/wrapper/jidctint-12.c", "src/wrapper/jidctred-8.c",
                "src/wrapper/jidctred-12.c", "src/jmemmgr.c", "src/jmemnobs.c", "src/jpeg_nbits.c",
                "src/wrapper/jquant1-8.c", "src/wrapper/jquant1-12.c", "src/wrapper/jquant2-8.c",
                "src/wrapper/jquant2-12.c", "src/wrapper/jutils-8.c", "src/wrapper/jutils-12.c",
                "src/wrapper/jutils-16.c", "src/jaricom.c", "src/jcarith.c", "src/jdarith.c",
            ],
            publicHeadersPath: "include"
        ),
        .target(
            name: "Cfreetype",
            path: "Modules/_pillow/freetype",
            sources: [
                "src/autofit/autofit.c", "src/base/ftbase.c", "src/base/ftbbox.c",
                "src/base/ftbdf.c", "src/base/ftbitmap.c", "src/base/ftcid.c",
                "src/base/ftfstype.c", "src/base/ftgasp.c", "src/base/ftglyph.c",
                "src/base/ftgxval.c", "src/base/ftinit.c", "src/base/ftmm.c", "src/base/ftotval.c",
                "src/base/ftpatent.c", "src/base/ftpfr.c", "src/base/ftstroke.c",
                "src/base/ftsynth.c", "src/base/fttype1.c", "src/base/ftwinfnt.c", "src/bdf/bdf.c",
                "src/bzip2/ftbzip2.c", "src/cache/ftcache.c", "src/cff/cff.c",
                "src/cid/type1cid.c", "src/gzip/ftgzip.c", "src/hvf/hvf.c", "src/lzw/ftlzw.c",
                "src/pcf/pcf.c", "src/pfr/pfr.c", "src/psaux/psaux.c", "src/pshinter/pshinter.c",
                "src/psnames/psnames.c", "src/raster/raster.c", "src/sdf/sdf.c", "src/sfnt/sfnt.c",
                "src/smooth/smooth.c", "src/svg/svg.c", "src/truetype/truetype.c",
                "src/type1/type1.c", "src/type42/type42.c", "src/winfonts/winfnt.c",
                "src/base/ftsystem.c", "src/base/ftdebug.c",
            ],
            publicHeadersPath: "include",
            cSettings: [.define("FT2_BUILD_LIBRARY")]
        ),
        .target(
            name: "Cwebp",
            path: "Modules/_pillow/webp",
            sources: ["src/dec", "src/dsp", "src/enc", "src/utils", "src/demux", "src/mux", "sharpyuv"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath(".")]
        ),
        .target(
            name: "CPIL",
            dependencies: ["CPython", "Cjpeg", "Cfreetype", "Cwebp"],
            path: "Modules",
            sources: [
                "_pillow/Pillow/src/_imaging.c", "_pillow/Pillow/src/decode.c", "_pillow/Pillow/src/encode.c",
                "_pillow/Pillow/src/map.c", "_pillow/Pillow/src/display.c", "_pillow/Pillow/src/outline.c",
                "_pillow/Pillow/src/path.c", "_pillow/Pillow/src/libImaging", "_pillow/Pillow/src/_imagingft.c",
                "_pillow/Pillow/src/_webp.c", "_pillow/Pillow/src/_imagingmath.c",
                "_pillow/Pillow/src/_imagingmorph.c", "_swiftpy/PIL/shim.c",
            ],
            publicHeadersPath: "_swiftpy/PIL",
            cSettings: pythonHeaders + [
                .define("HAVE_LIBJPEG"), .define("HAVE_LIBZ"), .define("PILLOW_VERSION", to: "\"13.0.0\""),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "PIL",
            dependencies: ["PythonModules", "CPIL"],
            path: "Swift/Sources/PIL",
            exclude: ["modules.txt"],
            resources: [.copy("PIL.zip")]
        ),

        .executableTarget(name: "pyrun", dependencies: ["Python"], path: "Swift/Sources/pyrun"),
        .executableTarget(name: "pybench", dependencies: ["Python"], path: "Swift/Sources/pybench"),
        .testTarget(name: "PythonTests", dependencies: ["Python"], path: "Swift/Tests/PythonTests"),
    ]
)

// MLX, behind the mlx trait. One static library per SDK in an xcframework, so
// SwiftPM picks the simulator or device slice itself, unlike libpython's.
let mlxDistribution = "\(packageDirectory)/Swift/.mlx-dist/MLXCore.xcframework"
if FileManager.default.fileExists(atPath: mlxDistribution) {
    // Resource targets can't vary by platform, so each Metal platform's
    // kernels get one of their own; a simulator slice has no Metal.
    let kernels = [("macos", Platform.macOS), ("ios", .iOS), ("xros", .visionOS)].map { os, platform in
        let path = "Swift/Sources/mlx_metal_\(os)"
        let staged = FileManager.default.fileExists(atPath: "\(packageDirectory)/\(path)/default.metallib")
        return (
            Target.target(name: "mlx_metal_\(os)", path: path, resources: staged ? [.copy("default.metallib")] : []),
            Target.Dependency.target(name: "mlx_metal_\(os)", condition: .when(platforms: [platform]))
        )
    }
    package.targets += kernels.map(\.0) + [
        .binaryTarget(name: "MLXCore", path: "Swift/.mlx-dist/MLXCore.xcframework"),
        .target(
            name: "Cmlxcore",
            dependencies: ["CPython", "MLXCore"],
            path: "Modules",
            sources: ["_swiftpy/mlx/shim.c"],
            publicHeadersPath: "_swiftpy/mlx",
            cSettings: moduleSettings,
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Foundation"),
            ]
        ),
        .target(
            name: "mlx",
            dependencies: ["PythonModules", "Cmlxcore"] + kernels.map(\.1),
            path: "Swift/Sources/mlx",
            exclude: ["modules.txt"],
            resources: [.copy("mlx.zip")]
        ),
    ]
    package.targets.first { $0.name == "Python" }?.dependencies
        .append(.target(name: "mlx", condition: .when(traits: ["mlx"])))
}
