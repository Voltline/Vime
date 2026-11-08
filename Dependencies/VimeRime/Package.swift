// swift-tools-version: 6.0
import PackageDescription

// librime with its dependencies, copied by Scripts/vendor_rime.py.
let vendor = "vendor"
let package = Package(
    name: "VimeRime",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "VimeRime", targets: ["CRime"]),
        .executable(name: "vime-rime-build", targets: ["vime-rime-build"]),
    ],
    targets: [
        .target(
            name: "CRime",
            exclude: ["\(vendor)/opencc/opencc/opencc_config_schema.inc"],
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-w"])],
            cxxSettings: [
                .headerSearchPath("\(vendor)/boost"),
                .headerSearchPath("\(vendor)/librime/src"),
                .headerSearchPath("\(vendor)/librime/include"),
                .headerSearchPath("\(vendor)/yaml-cpp/include"),
                .headerSearchPath("\(vendor)/leveldb"),
                .headerSearchPath("\(vendor)/leveldb/include"),
                .headerSearchPath("\(vendor)/marisa/include"),
                .headerSearchPath("\(vendor)/marisa/lib"),
                .headerSearchPath("\(vendor)/opencc"),
                .headerSearchPath("\(vendor)/opencc/opencc"),
                .headerSearchPath("\(vendor)/opencc/deps/rapidjson-1.1.0"),
                .define("BOOST_DLL_USE_STD_FS"),
                .define("RIME_EXTRA_MODULES", to: ""),
                .define("RIME_VERSION", to: "\"vime\""),
                .define("YAML_CPP_STATIC_DEFINE"),
                .define("LEVELDB_PLATFORM_POSIX"),
                .define("Opencc_BUILT_AS_STATIC"),
                .define("OPENCC_VERSION", to: "\"vime\""),
                .define("PKGDATADIR", to: "\"\""),
                .define("LOCALEDIR", to: "\"\""),
                .define("PACKAGE_NAME", to: "\"opencc\""),
                .define("OPENCC_SEGMENTATION_PLUGIN_DIR", to: "\"\""),
                .define("NDEBUG"),
                .unsafeFlags(["-w"]),
            ]),
        .executableTarget(name: "vime-rime-build", dependencies: ["CRime"]),
        .testTarget(name: "CRimeTests", dependencies: ["CRime"]),
    ],
    cxxLanguageStandard: .cxx17
)
