import ArgumentParser
import Foundation
import Shared

@main
struct OTAPublish: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ota-publish",
        abstract: "Publish an ad-hoc iOS build to S3 and emit a presigned itms-services OTA install link.",
        discussion: """
        Uploads (or re-signs) an .ipa stored in a private S3 bucket and produces a short-lived,
        self-authenticating OTA install flow: a presigned IPA URL embedded in a manifest.plist,
        wrapped by an install.html landing page (since GitHub markdown strips itms-services://).

        AWS credentials are taken from the ambient environment (the standard AWS credential chain:
        AWS_* env vars, AWS_PROFILE, or instance/OIDC role). This tool does not talk to GitHub.

        Prints a JSON object {"landingUrl": ..., "expiresAt": ...} to stdout.
        """,
        version: toolsVersion
    )

    enum Mode: String, ExpressibleByArgument, CaseIterable {
        case initial
        case refresh
    }

    @Option(help: "S3 bucket name (must be dot-free for a valid OTA HTTPS cert).")
    var bucket: String

    @Option(help: "AWS region of the bucket.")
    var region: String

    @Option(help: "Project namespace; top-level S3 key prefix so multiple repos can share one bucket.")
    var project: String

    @Option(help: "Pull request number.")
    var pr: Int

    @Option(name: .customLong("run-id"), help: "Workflow run id (scopes the build so runs never overwrite).")
    var runId: String

    @Option(help: "Presigned URL TTL in seconds (max 604800).")
    var ttl: Int = 43200

    @Option(help: "initial: upload the IPA then sign. refresh: re-sign an already-uploaded build.")
    var mode: Mode

    @Option(help: "Path to the .ipa (required for --mode initial).")
    var ipa: String?

    func run() async throws {
        let prefix = "\(project)/pr-\(pr)/run-\(runId)"
        let s3Base = "s3://\(bucket)/\(prefix)"
        let work = try makeWorkDir()

        let meta: BuildMetadata
        switch mode {
        case .initial:
            guard let ipaPath = ipa else { throw OTAError.missingIPA }
            let ipaName = URL(fileURLWithPath: ipaPath).lastPathComponent
            let extracted = try await extractMetadata(ipaPath: ipaPath)
            meta = BuildMetadata(
                ipaName: ipaName,
                bundleId: extracted.bundleId,
                bundleVersion: extracted.bundleVersion,
                title: extracted.title
            )
            try await Shell.run("aws", arguments: ["s3", "cp", ipaPath, "\(s3Base)/\(ipaName)", "--region", region])
            let metaLocal = (work as NSString).appendingPathComponent("metadata.json")
            try meta.write(to: metaLocal)
            try await Shell.run("aws", arguments: ["s3", "cp", metaLocal, "\(s3Base)/metadata.json", "--region", region])
        case .refresh:
            let metaLocal = (work as NSString).appendingPathComponent("metadata.json")
            try await Shell.run("aws", arguments: ["s3", "cp", "\(s3Base)/metadata.json", metaLocal, "--region", region])
            meta = try BuildMetadata(contentsOf: metaLocal)
        }

        // 1. Presign the durable IPA.
        let ipaUrl = try await presign(key: "\(prefix)/\(meta.ipaName)")

        // 2. Render + upload + presign the manifest that embeds the IPA URL.
        let manifestLocal = (work as NSString).appendingPathComponent("manifest.plist")
        try renderManifest(meta: meta, ipaUrl: ipaUrl).write(to: URL(fileURLWithPath: manifestLocal))
        try await Shell.run("aws", arguments: [
            "s3", "cp", manifestLocal, "\(s3Base)/manifest.plist",
            "--content-type", "text/xml", "--region", region,
        ])
        let manifestUrl = try await presign(key: "\(prefix)/manifest.plist")

        // 3. Render + upload + presign the install landing page that wraps the itms-services link.
        let expiresAt = Date().addingTimeInterval(TimeInterval(ttl))
        let htmlLocal = (work as NSString).appendingPathComponent("install.html")
        try renderInstallHTML(meta: meta, manifestUrl: manifestUrl, expiresAt: expiresAt)
            .write(toFile: htmlLocal, atomically: true, encoding: .utf8)
        try await Shell.run("aws", arguments: [
            "s3", "cp", htmlLocal, "\(s3Base)/install.html",
            "--content-type", "text/html", "--region", region,
        ])
        let landingUrl = try await presign(key: "\(prefix)/install.html")

        // 4. Emit machine-readable result for the workflow.
        let result: [String: String] = [
            "landingUrl": landingUrl,
            "expiresAt": ISO8601DateFormatter().string(from: expiresAt),
        ]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}

private extension OTAPublish {
    func presign(key: String) async throws -> String {
        try await Shell.run("aws", arguments: [
            "s3", "presign", "s3://\(bucket)/\(key)",
            "--expires-in", String(ttl), "--region", region,
        ])
    }

    func makeWorkDir() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("ota-publish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Extract bundle id / version / display title from an .ipa's app Info.plist.
    func extractMetadata(ipaPath: String) async throws -> (bundleId: String, bundleVersion: String, title: String) {
        let dir = try makeWorkDir()
        try await Shell.run("unzip", arguments: ["-o", ipaPath, "Payload/*.app/Info.plist", "-d", dir])
        guard let infoPlist = appInfoPlist(under: dir),
              let info = NSDictionary(contentsOfFile: infoPlist) else {
            throw OTAError.infoPlistNotFound
        }
        guard let bundleId = info["CFBundleIdentifier"] as? String else {
            throw OTAError.missingKey("CFBundleIdentifier")
        }
        let bundleVersion = (info["CFBundleVersion"] as? String)
            ?? (info["CFBundleShortVersionString"] as? String) ?? "1"
        let title = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String) ?? bundleId
        return (bundleId, bundleVersion, title)
    }

    /// Find the app-level Info.plist (Payload/<App>.app/Info.plist), ignoring nested frameworks.
    func appInfoPlist(under dir: String) -> String? {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return nil }
        var best: String?
        for case let rel as String in e where rel.hasSuffix(".app/Info.plist") {
            // Prefer the shallowest match (the app bundle, not an embedded framework).
            if best == nil || rel.components(separatedBy: "/").count < best!.components(separatedBy: "/").count {
                best = rel
            }
        }
        return best.map { (dir as NSString).appendingPathComponent($0) }
    }

    func renderManifest(meta: BuildMetadata, ipaUrl: String) throws -> Data {
        let manifest: [String: Any] = [
            "items": [[
                "assets": [[
                    "kind": "software-package",
                    "url": ipaUrl,
                ]],
                "metadata": [
                    "bundle-identifier": meta.bundleId,
                    "bundle-version": meta.bundleVersion,
                    "kind": "software",
                    "title": meta.title,
                ],
            ]],
        ]
        return try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
    }

    func renderInstallHTML(meta: BuildMetadata, manifestUrl: String, expiresAt: Date) -> String {
        let encodedManifest = manifestUrl.addingPercentEncoding(withAllowedCharacters: .urlUnreserved) ?? manifestUrl
        let itms = "itms-services://?action=download-manifest&amp;url=\(encodedManifest)"
        let title = meta.title.htmlEscaped
        let expiry = DateFormatter.humanUTC.string(from: expiresAt)
        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Install \(title)</title>
          <style>
            body { font-family: -apple-system, system-ui, sans-serif; margin: 0; padding: 2rem; text-align: center; }
            .btn { display: inline-block; margin: 1.5rem 0; padding: 0.9rem 2rem; font-size: 1.25rem;
                   background: #007aff; color: #fff; border-radius: 12px; text-decoration: none; }
            .meta { color: #666; font-size: 0.9rem; }
          </style>
        </head>
        <body>
          <h1>\(title)</h1>
          <p>Open this page in Safari on a registered device, then tap Install.</p>
          <a class="btn" href="\(itms)">Install \(title)</a>
          <p class="meta">Build \(meta.bundleVersion) &middot; link expires \(expiry)</p>
        </body>
        </html>
        """
    }
}

struct BuildMetadata {
    let ipaName: String
    let bundleId: String
    let bundleVersion: String
    let title: String

    func write(to path: String) throws {
        let dict: [String: String] = [
            "ipaName": ipaName,
            "bundleId": bundleId,
            "bundleVersion": bundleVersion,
            "title": title,
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }

    init(ipaName: String, bundleId: String, bundleVersion: String, title: String) {
        self.ipaName = ipaName
        self.bundleId = bundleId
        self.bundleVersion = bundleVersion
        self.title = title
    }

    init(contentsOf path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let ipaName = dict["ipaName"], let bundleId = dict["bundleId"],
              let bundleVersion = dict["bundleVersion"], let title = dict["title"] else {
            throw OTAError.badMetadata(path)
        }
        self.ipaName = ipaName
        self.bundleId = bundleId
        self.bundleVersion = bundleVersion
        self.title = title
    }
}

enum OTAError: LocalizedError {
    case missingIPA
    case infoPlistNotFound
    case missingKey(String)
    case badMetadata(String)

    var errorDescription: String? {
        switch self {
        case .missingIPA:
            return "--ipa is required for --mode initial."
        case .infoPlistNotFound:
            return "Could not find the app Info.plist inside the .ipa."
        case .missingKey(let key):
            return "Missing required Info.plist key: \(key)."
        case .badMetadata(let path):
            return "Could not parse build metadata at \(path)."
        }
    }
}

private extension CharacterSet {
    /// RFC 3986 unreserved characters — everything else is percent-encoded so the
    /// presigned URL's own query characters survive being nested in itms-services' url= param.
    static let urlUnreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension DateFormatter {
    static let humanUTC: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
