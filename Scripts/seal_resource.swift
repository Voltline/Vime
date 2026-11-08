// Encrypts a bundled resource that stays out of the public repository.
// The sealed copy is committed under ci_scripts/; Xcode Cloud opens it in
// ci_post_clone with the key from its secret VIME_RESOURCE_KEY (base64,
// 32 bytes, AES-256-GCM).
//
//     swift Scripts/seal_resource.swift keygen
//     VIME_RESOURCE_KEY=… swift Scripts/seal_resource.swift seal <plain> <sealed>
//     VIME_RESOURCE_KEY=… swift Scripts/seal_resource.swift open <sealed> <plain>
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func key() -> SymmetricKey {
    guard let text = ProcessInfo.processInfo.environment["VIME_RESOURCE_KEY"],
          let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          data.count == 32 else { fail("VIME_RESOURCE_KEY must be a base64 32-byte key") }
    return SymmetricKey(data: data)
}

let arguments = CommandLine.arguments.dropFirst()
switch (arguments.first, arguments.count) {
case ("keygen", 1):
    print(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() })
case ("seal", 3), ("open", 3):
    let input = URL(fileURLWithPath: arguments[arguments.startIndex + 1])
    let output = URL(fileURLWithPath: arguments[arguments.startIndex + 2])
    guard let data = try? Data(contentsOf: input) else { fail("cannot read \(input.path)") }
    do {
        let result = arguments.first == "seal"
            ? try AES.GCM.seal(data, using: key()).combined!
            : try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key())
        try result.write(to: output, options: .atomic)
    } catch { fail("\(arguments.first!) failed: \(error)") }
default:
    fail("usage: seal_resource.swift keygen | seal <plain> <sealed> | open <sealed> <plain>")
}
