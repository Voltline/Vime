// Compiles Rime schemas and dictionaries on the build machine, so the
// keyboard only maps the prebuilt files.
//
//     swift run --package-path Dependencies/VimeRime vime-rime-build <source dir> <output dir>
import CRime
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: vime-rime-build <source dir> <output dir>\n".utf8))
    exit(2)
}
let user = FileManager.default.temporaryDirectory.appendingPathComponent("vime-rime-build-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: user) }
guard vime_rime_build(arguments[1], user.path, arguments[2]) else {
    FileHandle.standardError.write(Data("error: build failed\n".utf8))
    exit(1)
}
