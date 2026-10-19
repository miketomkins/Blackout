import CryptoKit
import Foundation
import Security

/// Downloads, verifies and swaps in a new Blackout.app. Nothing touches the installed app until every check has
/// passed, and a failed swap puts the installed app back.
public struct UpdateInstaller {
    let http: UpdateHTTP
    let publicKey: Curve25519.Signing.PublicKey
    let codeSignatureIsValid: (URL) -> Bool
    let fileManager = FileManager.default

    public init(
        http: UpdateHTTP, publicKey: Curve25519.Signing.PublicKey,
        codeSignatureIsValid: @escaping (URL) -> Bool = UpdateInstaller.staticCodeIsValid
    ) {
        self.http = http
        self.publicKey = publicKey
        self.codeSignatureIsValid = codeSignatureIsValid
    }

    /// Whether the folder holding `app` lets this user replace it.
    public func canReplace(_ app: URL) -> Bool {
        fileManager.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Downloads and checks the update, then unpacks it next to `installed` (same volume, so the swap is a rename).
    /// Returns the staged app.
    public func prepare(_ update: UpdateCandidate, replacing installed: URL, current: AppVersion) throws -> URL {
        guard canReplace(installed) else { throw UpdateError.notWritable(installed.deletingLastPathComponent().path) }
        let zip = try http.get(update.zip.url)
        let checksum = String(decoding: try http.get(update.checksum.url), as: UTF8.self)
        let signature = String(decoding: try http.get(update.signature.url), as: UTF8.self)
        try UpdateVerifier.verify(
            zip: zip, zipName: update.zip.name, checksumFile: checksum, signatureFile: signature, publicKey: publicKey)

        let work: URL
        do {
            work = try fileManager.url(
                for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
            let archive = work.appendingPathComponent(update.zip.name)
            try zip.write(to: archive)
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, work.appendingPathComponent("unpacked").path])
        } catch let error as UpdateError { throw error } catch { throw UpdateError.install(error.localizedDescription) }

        let staged = work.appendingPathComponent("unpacked/Blackout.app")
        guard let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.wrongBundle("no Blackout.app inside the ZIP")
        }
        guard info["CFBundleIdentifier"] as? String == UpdateConfig.bundleIdentifier else {
            throw UpdateError.wrongBundle("unexpected bundle identifier")
        }
        // Release tags are "v" + the app's version, so the app inside must report exactly the tag's version.
        guard let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init),
            version == update.version
        else { throw UpdateError.wrongBundle("its version doesn't match release \(update.release.tag)") }
        guard version > current else { throw UpdateError.notNewer }
        guard codeSignatureIsValid(staged) else { throw UpdateError.wrongBundle("its code signature is invalid") }
        return staged
    }

    /// Replaces `installed` with `staged`. The previous app is moved aside first and put back if the move fails.
    /// Returns where the previous app was kept.
    @discardableResult public func swap(installed: URL, with staged: URL) throws -> URL {
        let backup = staged.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Blackout-previous.app")
        do {
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: installed, to: backup)
        } catch { throw UpdateError.install(error.localizedDescription) }
        do {
            try fileManager.moveItem(at: staged, to: installed)
        } catch {
            try? fileManager.moveItem(at: backup, to: installed)
            throw UpdateError.install(error.localizedDescription)
        }
        return backup
    }

    /// Whether the bundle's code signature (ad-hoc is fine) is intact, including sealed resources.
    public static func staticCodeIsValid(_ app: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.install("\(URL(fileURLWithPath: tool).lastPathComponent) failed")
        }
    }
}
