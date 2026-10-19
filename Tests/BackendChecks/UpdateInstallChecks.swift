import BlackoutCore
import CryptoKit
import Foundation

/// Serves canned bytes per URL; a missing URL is a network failure.
final class SimulatedHTTP: UpdateHTTP {
    var responses: [URL: Data] = [:]
    var requests: [URL] = []
    func get(_ url: URL) throws -> Data {
        requests.append(url)
        guard let data = responses[url] else { throw UpdateError.network("simulated offline") }
        return data
    }
}

private func shell(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw UpdateError.install("\(tool) failed") }
}

/// End-to-end install checks against the real app bundle that build.sh made, in a temporary folder. Nothing outside
/// that folder is touched, and nothing is downloaded.
func updateInstallChecks() throws {
    let built = URL(fileURLWithPath: "build/Blackout.app")
    guard let builtInfo = NSDictionary(contentsOf: built.appendingPathComponent("Contents/Info.plist")),
        let builtVersion = (builtInfo["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    else {
        check(false, "update install checks need build/Blackout.app: run build.sh (test.sh does) first")
        return
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("blackout-update-checks-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let key = Curve25519.Signing.PrivateKey()
    let tag = "v\(builtVersion)"
    let older = AppVersion("0.9.0")!

    /// A release whose ZIP holds `app`; returns the candidate and fills `http`.
    func publish(_ app: URL, http: SimulatedHTTP, signWith signer: Curve25519.Signing.PrivateKey? = nil) throws
        -> UpdateCandidate
    {
        let name = UpdatePolicy.zipName(tag: tag)
        let folder = root.appendingPathComponent("release-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let zipURL = folder.appendingPathComponent(name)
        try shell(
            "/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", app.path, zipURL.path])
        let zip = try Data(contentsOf: zipURL)
        let sum = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let base = URL(string: "https://example.invalid/\(UUID().uuidString)/")!
        let assets = [name, name + ".sha256", name + ".sig"].map {
            Release.Asset(name: $0, url: base.appendingPathComponent($0))
        }
        http.responses[assets[0].url] = zip
        http.responses[assets[1].url] = Data("\(sum)  \(name)\n".utf8)
        http.responses[assets[2].url] = Data(try UpdateVerifier.signatureFile(for: zip, key: signer ?? key).utf8)
        let release = Release(
            tag: tag, notes: nil, draft: false, prerelease: true, page: base, assets: assets)
        return UpdatePolicy.newest(in: [release], newerThan: older)!
    }
    /// A fresh "installed" app: a copy of the built app plus a marker file, so a swap is visible.
    func installedApp() throws -> URL {
        let folder = root.appendingPathComponent("Applications-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appendingPathComponent("Blackout.app")
        try fm.copyItem(at: built, to: app)
        try Data("old".utf8).write(to: app.appendingPathComponent("Contents/old-marker"))
        return app
    }
    func variant(_ edit: (URL) throws -> Void) throws -> URL {
        let folder = root.appendingPathComponent("variant-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appendingPathComponent("Blackout.app")
        try fm.copyItem(at: built, to: app)
        try edit(app)
        return app
    }
    func failure(_ operation: () throws -> Void) -> UpdateError? {
        do {
            try operation()
            return nil
        } catch { return error as? UpdateError }
    }
    func untouched(_ app: URL) -> Bool { fm.fileExists(atPath: app.appendingPathComponent("Contents/old-marker").path) }

    // Happy path: download, verify, stage, swap.
    let http = SimulatedHTTP()
    let update = try publish(built, http: http)
    let installer = UpdateInstaller(http: http, publicKey: key.publicKey)
    let installed = try installedApp()
    check(installer.canReplace(installed), "a user-writable folder can be updated in place")
    let staged = try installer.prepare(update, replacing: installed, current: older)
    check(
        UpdateInstaller.staticCodeIsValid(staged) && untouched(installed) && http.requests.count == 3,
        "prepare downloads three files and stages a valid app without touching the installed one")
    let backup = try installer.swap(installed: installed, with: staged)
    check(
        !untouched(installed) && fm.fileExists(atPath: backup.appendingPathComponent("Contents/old-marker").path)
            && UpdateInstaller.staticCodeIsValid(installed),
        "swap installs the new app and keeps the previous one aside")

    // Every failure leaves the installed app as it was.
    let tamperedHTTP = SimulatedHTTP()
    let tampered = try publish(built, http: tamperedHTTP)
    var zip = tamperedHTTP.responses[tampered.zip.url]!
    zip[zip.count / 2] ^= 0xFF
    tamperedHTTP.responses[tampered.zip.url] = zip
    var app = try installedApp()
    check(
        failure {
            _ = try UpdateInstaller(http: tamperedHTTP, publicKey: key.publicKey).prepare(
                tampered, replacing: app, current: older)
        }
            == .checksumMismatch && untouched(app),
        "a corrupted download is refused")

    let forgedHTTP = SimulatedHTTP()
    let forged = try publish(built, http: forgedHTTP, signWith: Curve25519.Signing.PrivateKey())
    app = try installedApp()
    check(
        failure {
            _ = try UpdateInstaller(http: forgedHTTP, publicKey: key.publicKey).prepare(
                forged, replacing: app, current: older)
        }
            == .badSignature && untouched(app),
        "a ZIP signed by another key is refused, even with a matching checksum")

    let offline = SimulatedHTTP()
    app = try installedApp()
    if case .network = failure({
        _ = try UpdateInstaller(http: offline, publicKey: key.publicKey).prepare(update, replacing: app, current: older)
    }) {
        check(untouched(app), "a network failure leaves the installed app alone")
    } else {
        check(false, "a network failure is reported as a network error")
    }

    let brokenSeal = try variant { app in
        let icon = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        var bytes = try Data(contentsOf: icon)
        bytes[0] ^= 0xFF
        try bytes.write(to: icon)
    }
    let brokenHTTP = SimulatedHTTP()
    let broken = try publish(brokenSeal, http: brokenHTTP)
    app = try installedApp()
    check(
        failure {
            _ = try UpdateInstaller(http: brokenHTTP, publicKey: key.publicKey).prepare(
                broken, replacing: app, current: older)
        }
            == .wrongBundle("its code signature is invalid") && untouched(app),
        "an app whose code signature doesn't verify is refused")

    let impostor = try variant { app in
        try shell(
            "/usr/libexec/PlistBuddy",
            ["-c", "Set :CFBundleIdentifier com.example.Other", app.appendingPathComponent("Contents/Info.plist").path])
        try shell("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
    }
    let impostorHTTP = SimulatedHTTP()
    let impostorUpdate = try publish(impostor, http: impostorHTTP)
    app = try installedApp()
    check(
        failure {
            _ = try UpdateInstaller(http: impostorHTTP, publicKey: key.publicKey).prepare(
                impostorUpdate, replacing: app, current: older)
        }
            == .wrongBundle("unexpected bundle identifier") && untouched(app),
        "an app with another bundle identifier is refused")

    let mislabeled = try variant { app in
        try shell(
            "/usr/libexec/PlistBuddy",
            ["-c", "Set :CFBundleShortVersionString 99.0.0", app.appendingPathComponent("Contents/Info.plist").path])
        try shell("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
    }
    let mislabeledHTTP = SimulatedHTTP()
    let mislabeledUpdate = try publish(mislabeled, http: mislabeledHTTP)
    app = try installedApp()
    if case .wrongBundle = failure({
        _ = try UpdateInstaller(http: mislabeledHTTP, publicKey: key.publicKey).prepare(
            mislabeledUpdate, replacing: app, current: older)
    }) {
        check(untouched(app), "an app whose version doesn't match its release tag is refused")
    } else {
        check(false, "an app whose version doesn't match its release tag is refused")
    }

    app = try installedApp()
    check(
        failure { _ = try installer.prepare(update, replacing: app, current: builtVersion) } == .notNewer
            && untouched(app),
        "a release equal to the installed version isn't installed")

    app = try installedApp()
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.deletingLastPathComponent().path)
    let readOnly = failure { _ = try installer.prepare(update, replacing: app, current: older) }
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.deletingLastPathComponent().path)
    if case .notWritable = readOnly {
        check(untouched(app), "a folder the user can't write to is reported before downloading")
    } else {
        check(false, "a folder the user can't write to is reported before downloading")
    }

    app = try installedApp()
    let missing = app.deletingLastPathComponent().appendingPathComponent("nothing-here/Blackout.app")
    if case .install = failure({ try installer.swap(installed: app, with: missing) }) {
        check(untouched(app), "a failed swap puts the installed app back")
    } else {
        check(false, "a failed swap is reported")
    }

    // The checker reads GitHub's release list through the same HTTP layer.
    let listing = SimulatedHTTP()
    listing.responses[UpdateConfig.releasesURL] = Data(
        """
        [{"tag_name":"\(tag)","body":"Notes","draft":false,"prerelease":true,"html_url":"https://example.invalid/r",
          "assets":[\(update.release.assets.map { "{\"name\":\"\($0.name)\",\"browser_download_url\":\"\($0.url.absoluteString)\"}" }.joined(separator: ","))]}]
        """.utf8)
    check(
        (try? UpdateChecker(http: listing).check(current: "0.9.0"))?.release.tag == tag
            && (try? UpdateChecker(http: listing).check(current: builtVersion.description)) == .some(nil),
        "the checker finds a newer release and reports up to date at the same version")
    check(
        failure { _ = try UpdateChecker(http: SimulatedHTTP()).check(current: "0.9.0") }
            == .network("simulated offline"),
        "an offline check reports the network error")
    listing.responses[UpdateConfig.releasesURL] = Data("<html>rate limited</html>".utf8)
    check(
        failure { _ = try UpdateChecker(http: listing).check(current: "0.9.0") } == .badResponse,
        "a garbled reply is reported")
    check(
        failure { _ = try UpdateChecker(http: listing).check(current: "dev") } == .unknownVersion("dev"),
        "a dev build can't compare")
}
