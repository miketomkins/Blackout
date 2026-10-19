import BlackoutCore
import CryptoKit
import Foundation

// Maintainer tool for signing release ZIPs. The Ed25519 private key lives in the login keychain, read and written
// through /usr/bin/security; it is never written to disk or the repository.
let service = "com.miketomkins.Blackout.release-signing"
let account = "ed25519"

func fail(_ message: String) -> Never {
    fputs("ReleaseTool: \(message)\n", stderr)
    exit(1)
}

@discardableResult func security(_ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { fail("couldn't run security: \(error.localizedDescription)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
}

func storedKey() -> Curve25519.Signing.PrivateKey {
    let found = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard found.status == 0 else { fail("no signing key in the login keychain. Run: swift run ReleaseTool keygen") }
    guard let raw = Data(base64Encoded: found.output),
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("the keychain item \(service) isn't a valid key") }
    return key
}

func read(_ path: String) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    return data
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "keygen":
    guard security(["find-generic-password", "-s", service, "-a", account]).status != 0 else {
        fail("a signing key already exists in the keychain; refusing to replace it")
    }
    let key = Curve25519.Signing.PrivateKey()
    let added = security([
        "add-generic-password", "-s", service, "-a", account, "-l", "Blackout release signing key",
        "-T", "/usr/bin/security", "-w", key.rawRepresentation.base64EncodedString(),
    ])
    guard added.status == 0 else { fail("couldn't save the key to the keychain") }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public-key":
    print(storedKey().publicKey.rawRepresentation.base64EncodedString())
case "sign" where args.count == 2:
    let signature = try UpdateVerifier.signatureFile(for: read(args[1]), key: storedKey())
    guard FileManager.default.createFile(atPath: args[1] + ".sig", contents: Data(signature.utf8)) else {
        fail("can't write \(args[1]).sig")
    }
    print("Wrote \(args[1]).sig")
case "verify" where args.count == 2:
    // Verifies exactly as the app will: the published checksum, then the signature against the app's built-in key.
    let zip = args[1]
    do {
        try UpdateVerifier.verify(
            zip: read(zip), zipName: URL(fileURLWithPath: zip).lastPathComponent,
            checksumFile: String(decoding: read(zip + ".sha256"), as: UTF8.self),
            signatureFile: String(decoding: read(zip + ".sig"), as: UTF8.self), publicKey: UpdateConfig.publicKey())
    } catch { fail(error.localizedDescription) }
    print("OK: checksum and signature verify against the app's release key")
default:
    print(
        """
        Usage: swift run ReleaseTool <command>
          keygen        Create the release signing key in the login keychain and print its public key
          public-key    Print the public key of the stored signing key
          sign ZIP      Write ZIP.sig, an Ed25519 signature over ZIP
          verify ZIP    Check ZIP against ZIP.sha256 and ZIP.sig with the key built into the app
        """)
    exit(args.isEmpty ? 0 : 2)
}
