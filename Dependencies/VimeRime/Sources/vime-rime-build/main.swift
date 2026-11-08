// Compiles Rime schemas and dictionaries on the build machine, so the
// keyboard only maps the prebuilt files.
//
//     swift run --package-path Dependencies/VimeRime vime-rime-build <source dir> <output dir>
//     swift run --package-path Dependencies/VimeRime vime-rime-build --opencc <text dict> <ocd2 file>
import CRime
import Foundation

let arguments = CommandLine.arguments
func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}
if arguments.count == 4, arguments[1] == "--opencc" {
    guard vime_opencc_build_dictionary(arguments[2], arguments[3]) else { fail("error: OpenCC dictionary failed", code: 1) }
    exit(0)
}
guard arguments.count == 3 else {
    fail("usage: vime-rime-build <source dir> <output dir>\n       vime-rime-build --opencc <text dict> <ocd2 file>", code: 2)
}
let user = FileManager.default.temporaryDirectory.appendingPathComponent("vime-rime-build-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: user) }
guard vime_rime_build(arguments[1], user.path, arguments[2]) else { fail("error: build failed", code: 1) }
