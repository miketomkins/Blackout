import BlackoutCore
import CryptoKit
import Foundation

func updateChecks() {
    func v(_ text: String) -> AppVersion { AppVersion(text)! }
    check(v("1.2.0") == v("v1.2") && v("1.2") == v("1.2.0+build.7"), "versions parse with v prefix, padding and build")
    check(
        [nil, nil, nil, nil, nil] == ["dev", "1.2.x", "1.2.3.4", "1.2.0-", "-1.0"].map { AppVersion($0)?.description },
        "malformed versions are rejected")
    check(v("1.10.0") > v("1.9.0") && v("2.0.0") > v("1.99.99"), "versions compare numerically, not as text")
    check(v("1.0.0-beta.1") < v("1.0.0") && v("1.0.0") < v("1.0.1-beta.1"), "a pre-release sorts before its release")
    check(
        v("1.0.0-alpha") < v("1.0.0-alpha.1") && v("1.0.0-alpha.1") < v("1.0.0-beta")
            && v("1.0.0-beta.2") < v("1.0.0-beta.11") && v("1.0.0-beta.11") < v("1.0.0-rc.1"),
        "pre-release identifiers follow SemVer precedence")
    check(v("1.0.0-beta.1").description == "1.0.0-beta.1" && v("v1.2").description == "1.2.0", "versions print")

    let base = URL(string: "https://example.invalid/")!
    func release(_ tag: String, draft: Bool = false, prerelease: Bool = false, signed: Bool = true) -> Release {
        let zip = UpdatePolicy.zipName(tag: tag)
        let names = [zip, zip + ".sha256"] + (signed ? [zip + ".sig"] : [])
        return Release(
            tag: tag, notes: "Notes for \(tag)", draft: draft, prerelease: prerelease,
            page: base.appendingPathComponent(tag),
            assets: names.map { Release.Asset(name: $0, url: base.appendingPathComponent($0)) })
    }
    let releases = [
        release("v1.0.0-beta.1", prerelease: true, signed: false), release("v1.2.0", prerelease: true, signed: false),
        release("v1.3.0", prerelease: true), release("v1.4.0", draft: true), release("v1.3.1", signed: false),
    ]
    let found = UpdatePolicy.newest(in: releases, newerThan: v("1.2.0"))
    check(
        found?.release.tag == "v1.3.0" && found?.zip.name == "Blackout-v1.3.0-macOS-arm64.zip"
            && found?.signature.name == "Blackout-v1.3.0-macOS-arm64.zip.sig",
        "the newest signed, published release wins; drafts and unsigned releases are skipped")
    check(UpdatePolicy.newest(in: releases, newerThan: v("1.3.0")) == nil, "an equal version is up to date")
    check(UpdatePolicy.newest(in: releases, newerThan: v("2.0.0")) == nil, "a newer installed version is up to date")
    check(
        UpdatePolicy.newest(in: releases, newerThan: v("1.2.0"), includePrereleases: false) == nil,
        "pre-releases can be excluded")
    check(
        UpdatePolicy.newest(
            in: [release("v1.3.0"), release("v1.5.0-beta.1"), release("v1.4.0")], newerThan: v("1.2.0"))?
            .release.tag == "v1.5.0-beta.1",
        "pre-releases count as updates by default")
    check(
        UpdatePolicy.newest(in: [release("nightly"), release("v1.3")], newerThan: v("1.2.0"))?.release.tag == "v1.3",
        "tags that aren't versions are ignored")

    let json = """
        [{"tag_name":"v1.3.0","body":"Hello","draft":false,"prerelease":true,
          "html_url":"https://github.com/miketomkins/Blackout/releases/tag/v1.3.0","id":1,
          "assets":[{"name":"Blackout-v1.3.0-macOS-arm64.zip","size":5,
          "browser_download_url":"https://github.com/miketomkins/Blackout/releases/download/v1.3.0/Blackout-v1.3.0-macOS-arm64.zip"}]}]
        """
    let decoded = try? JSONDecoder().decode([Release].self, from: Data(json.utf8))
    check(
        decoded?.first?.tag == "v1.3.0" && decoded?.first?.prerelease == true && decoded?.first?.notes == "Hello"
            && decoded?.first?.assets.first?.url.lastPathComponent == "Blackout-v1.3.0-macOS-arm64.zip",
        "GitHub's release JSON decodes")

    let key = Curve25519.Signing.PrivateKey()
    let zip = Data("pretend zip".utf8)
    let name = "Blackout-v1.3.0-macOS-arm64.zip"
    let sum = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
    let signature = try! UpdateVerifier.signatureFile(for: zip, key: key)
    func verify(_ data: Data, sums: String, sig: String, with publicKey: Curve25519.Signing.PublicKey? = nil)
        -> UpdateError?
    {
        do {
            try UpdateVerifier.verify(
                zip: data, zipName: name, checksumFile: sums, signatureFile: sig,
                publicKey: publicKey ?? key.publicKey)
            return nil
        } catch { return error as? UpdateError }
    }
    check(verify(zip, sums: "\(sum)  \(name)\n", sig: signature) == nil, "a signed ZIP with its checksum verifies")
    check(verify(zip, sums: sum.uppercased(), sig: signature) == nil, "a bare uppercase checksum also verifies")
    check(
        verify(Data("tampered zip".utf8), sums: "\(sum)  \(name)", sig: signature) == .checksumMismatch,
        "a changed ZIP fails the checksum")
    check(
        verify(zip, sums: "\(sum)  other.zip", sig: signature) == .checksumMismatch, "a checksum for another file fails"
    )
    check(verify(zip, sums: "abc  \(name)", sig: signature) == .checksumMismatch, "a malformed checksum fails")
    let otherKey = Curve25519.Signing.PrivateKey()
    check(
        verify(zip, sums: sum, sig: try! UpdateVerifier.signatureFile(for: zip, key: otherKey)) == .badSignature,
        "a ZIP signed by another key is refused even with a matching checksum")
    check(verify(zip, sums: sum, sig: "not base64!") == .badSignature, "a malformed signature is refused")
    check((try? UpdateConfig.publicKey()) != nil, "the app's built-in release key is a valid Ed25519 key")
}
