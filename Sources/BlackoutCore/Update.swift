import CryptoKit
import Foundation

public enum UpdateConfig {
    public static let releasesURL = URL(
        string: "https://api.github.com/repos/miketomkins/Blackout/releases?per_page=30")!
    public static let bundleIdentifier = "com.miketomkins.Blackout"
    /// Ed25519 public key that release ZIPs are signed with. The private key stays in the maintainer's login
    /// keychain (`swift run ReleaseTool`); an update whose signature doesn't verify against this key is refused.
    public static let signingPublicKey = "/ZZFA7ccBlrTT04Kz68SYc8ueSqNNnZjg9ZZ/Ay0lZ0="

    public static func publicKey() throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: signingPublicKey) else { throw UpdateError.badSignature }
        return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case unknownVersion(String)
    case network(String)
    case badResponse
    case checksumMismatch
    case badSignature
    case wrongBundle(String)
    case notNewer
    case notWritable(String)
    case install(String)

    public var errorDescription: String? {
        switch self {
        case .unknownVersion(let text): return "This copy of Blackout has no comparable version (\(text))."
        case .network(let detail): return "Couldn't reach GitHub: \(detail)"
        case .badResponse: return "GitHub sent a response Blackout couldn't read."
        case .checksumMismatch: return "The download doesn't match its published checksum."
        case .badSignature: return "The download isn't signed by Blackout's release key."
        case .wrongBundle(let detail): return "The download isn't a valid Blackout app: \(detail)"
        case .notNewer: return "The download isn't newer than the installed version."
        case .notWritable(let path): return "Blackout can't replace itself in \(path)."
        case .install(let detail): return "Installing failed: \(detail)"
        }
    }
}

/// A release version such as 1.2.0 or 1.0.0-beta.1, ordered by Semantic Versioning precedence.
public struct AppVersion: Comparable, CustomStringConvertible {
    public let core: [Int]
    public let prerelease: [String]

    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var pre: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            pre = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(
                String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty }) else { return nil }
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        core = numbers + Array(repeating: 0, count: 3 - numbers.count)
        prerelease = pre
    }

    public var description: String {
        core.map(String.init).joined(separator: ".")
            + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { a.core == b.core && a.prerelease == b.prerelease }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        // A pre-release sorts before its release: 1.0.0-beta.1 < 1.0.0.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case (let i?, let j?): return i < j
            case (.some, nil): return true
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// The parts of a GitHub release Blackout uses.
public struct Release: Decodable, Equatable {
    public struct Asset: Decodable, Equatable {
        public let name: String
        public let url: URL
        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
        }
        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }
    public let tag: String
    public let notes: String?
    public let draft: Bool
    public let prerelease: Bool
    public let page: URL
    public let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case notes = "body"
        case draft, prerelease, assets
        case page = "html_url"
    }
    public init(tag: String, notes: String?, draft: Bool, prerelease: Bool, page: URL, assets: [Asset]) {
        self.tag = tag
        self.notes = notes
        self.draft = draft
        self.prerelease = prerelease
        self.page = page
        self.assets = assets
    }
}

/// A newer release with everything needed to install it.
public struct UpdateCandidate: Equatable {
    public let release: Release
    public let version: AppVersion
    public let zip: Release.Asset
    public let checksum: Release.Asset
    public let signature: Release.Asset
}

public enum UpdatePolicy {
    public static func zipName(tag: String) -> String { "Blackout-\(tag)-macOS-arm64.zip" }

    /// The newest published release above `current` that carries a ZIP, its checksum and its signature.
    /// Drafts never count. Releases without a signature (made before signing existed) are skipped.
    public static func newest(in releases: [Release], newerThan current: AppVersion, includePrereleases: Bool = true)
        -> UpdateCandidate?
    {
        var best: UpdateCandidate?
        for release in releases where !release.draft && (includePrereleases || !release.prerelease) {
            guard let version = AppVersion(release.tag), version > current else { continue }
            let name = zipName(tag: release.tag)
            guard let zip = release.assets.first(where: { $0.name == name }),
                let checksum = release.assets.first(where: { $0.name == name + ".sha256" }),
                let signature = release.assets.first(where: { $0.name == name + ".sig" })
            else { continue }
            if best.map({ version > $0.version }) ?? true {
                best = UpdateCandidate(
                    release: release, version: version, zip: zip, checksum: checksum, signature: signature)
            }
        }
        return best
    }
}

public enum UpdateVerifier {
    /// Checks a downloaded ZIP against its `.sha256` file (`<hex>  <name>`) and its `.sig` file (base64 Ed25519
    /// signature over the ZIP's bytes). The signature is what proves the ZIP came from Blackout's release key.
    public static func verify(
        zip: Data, zipName: String, checksumFile: String, signatureFile: String,
        publicKey: Curve25519.Signing.PublicKey
    ) throws {
        let fields = checksumFile.split(whereSeparator: \.isWhitespace)
        guard let expected = fields.first?.lowercased(), expected.count == 64,
            fields.count == 1 || (fields.count == 2 && fields[1] == zipName)
        else { throw UpdateError.checksumMismatch }
        let actual = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError.checksumMismatch }
        guard let signature = Data(base64Encoded: signatureFile.trimmingCharacters(in: .whitespacesAndNewlines)),
            publicKey.isValidSignature(signature, for: zip)
        else { throw UpdateError.badSignature }
    }

    public static func signatureFile(for data: Data, key: Curve25519.Signing.PrivateKey) throws -> String {
        try key.signature(for: data).base64EncodedString() + "\n"
    }
}

/// Fetches a URL's bytes. Synchronous: call it off the main thread.
public protocol UpdateHTTP {
    func get(_ url: URL) throws -> Data
}

public final class URLSessionHTTP: UpdateHTTP {
    private let session: URLSession
    private let userAgent: String

    public init(appVersion: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
        userAgent = "Blackout/\(appVersion)"
    }

    public func get(_ url: URL) throws -> Data {
        guard url.scheme == "https" else { throw UpdateError.network("refusing a non-HTTPS address") }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(UpdateError.badResponse)
        session.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error {
                result = .failure(UpdateError.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(UpdateError.network("HTTP \(http.statusCode)"))
            } else if let data {
                result = .success(data)
            }
        }.resume()
        done.wait()
        return try result.get()
    }
}

public struct UpdateChecker {
    let http: UpdateHTTP
    public init(http: UpdateHTTP) { self.http = http }

    /// The newest release above `current`, or nil when this copy is up to date.
    public func check(current: String, includePrereleases: Bool = true) throws -> UpdateCandidate? {
        guard let installed = AppVersion(current) else { throw UpdateError.unknownVersion(current) }
        let listing = try http.get(UpdateConfig.releasesURL)
        guard let releases = try? JSONDecoder().decode([Release].self, from: listing) else {
            throw UpdateError.badResponse
        }
        return UpdatePolicy.newest(in: releases, newerThan: installed, includePrereleases: includePrereleases)
    }
}
