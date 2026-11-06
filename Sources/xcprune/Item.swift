import ArgumentParser
import CryptoKit
import Foundation

/// The kinds of things `xcprune` finds. The case order is the order of the scan output.
enum Category: String, CaseIterable, Codable, Sendable, ExpressibleByArgument {
    case xcode
    case runtime
    case simulator
    case deviceSupport = "device-support"
    case derivedData = "derived-data"
    case archive
    case cache
    case download

    var title: String {
        switch self {
        case .xcode: "Xcode apps"
        case .runtime: "Simulator runtimes"
        case .simulator: "Simulators"
        case .deviceSupport: "Device support files"
        case .derivedData: "DerivedData"
        case .archive: "Archives"
        case .cache: "Caches"
        case .download: "Downloaded installers"
        }
    }

    /// Simulators go before runtimes, so `simctl` does not delete a runtime that a simulator in the same run still uses.
    var removalRank: Int {
        switch self {
        case .simulator: 0
        case .runtime: 1
        default: 2
        }
    }
}

/// How to delete an item.
enum Removal: Codable, Sendable, Equatable {
    /// Move to the Trash, so the deletion can be undone.
    case trash(path: String)
    /// Delete the file or directory.
    case remove(path: String)
    /// Delete everything in the directory, but keep the directory.
    case removeContents(path: String)
    case simctlRuntime(identifier: String)
    case simctlDevice(udid: String)
    /// `simctl runtime dyld_shared_cache remove`, or delete the folder if `simctl` cannot.
    case simctlDyldCache(runtime: String, path: String)
}

struct Item: Codable, Sendable {
    /// A short hash of the category and the item's path or identifier, so it is the same in each scan.
    let id: String
    let category: Category
    let name: String
    var detail: String
    var sizeBytes: Int64?
    let path: String?
    var suggested = false
    var reason: String?
    let removal: Removal
    /// Facts that `tree` uses to group items, e.g. a runtime's `platform` and `build`.
    var info: [String: String] = [:]

    init(category: Category, key: String, name: String, detail: String, path: String?, sizeBytes: Int64? = nil, removal: Removal) {
        self.id = Item.makeID(category: category, key: key)
        self.category = category
        self.name = name
        self.detail = detail
        self.path = path
        self.sizeBytes = sizeBytes
        self.removal = removal
    }

    mutating func suggest(_ reason: String) {
        guard !suggested else { return }
        suggested = true
        self.reason = reason
    }

    static func makeID(category: Category, key: String) -> String {
        let digest = SHA256.hash(data: Data("\(category.rawValue):\(key)".utf8))
        return digest.prefix(3).map { String(format: "%02x", $0) }.joined()
    }
}

enum Format {
    static func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "?" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func total(_ items: [Item]) -> String {
        size(items.compactMap(\.sizeBytes).reduce(0, +))
    }

    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    static func day(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func date(_ iso8601: String?) -> Date? {
        iso8601.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    static func padRight(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : string + String(repeating: " ", count: width - string.count)
    }

    static func padLeft(_ string: String, _ width: Int) -> String {
        string.count >= width ? string : String(repeating: " ", count: width - string.count) + string
    }
}

/// Compares dotted version strings by their numbers, so 26.10 is newer than 26.9.
enum VersionOrder {
    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// Orders by version, then by build, e.g. 26.5 (23F77) before 26.5 (23F79).
    static func isOlder(version lhsVersion: String, build lhsBuild: String, than rhsVersion: String, build rhsBuild: String) -> Bool {
        if isOlder(lhsVersion, than: rhsVersion) { return true }
        if isOlder(rhsVersion, than: lhsVersion) { return false }
        return lhsBuild.compare(rhsBuild, options: .numeric) == .orderedAscending
    }
}

enum Report {
    /// One aligned line per item. The id is the first word, so `pick` can read it back.
    static func rows(_ items: [Item], showCategory: Bool = false) -> [String] {
        let sizeWidth = items.map { Format.size($0.sizeBytes).count }.max() ?? 0
        let nameWidth = min(items.map(\.name.count).max() ?? 0, 48)
        let categoryWidth = items.map(\.category.rawValue.count).max() ?? 0
        return items.map { item in
            var columns = [item.id, item.suggested ? "*" : " "]
            if showCategory {
                columns.append(Format.padRight(item.category.rawValue, categoryWidth))
            }
            columns.append(Format.padLeft(Format.size(item.sizeBytes), sizeWidth))
            columns.append(Format.padRight(item.name, nameWidth))
            var note = item.detail
            if item.suggested, let reason = item.reason {
                note += note.isEmpty ? "→ \(reason)" : "  → \(reason)"
            }
            columns.append(note)
            return columns.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }
    }

    static func printTable(_ items: [Item]) {
        for category in Category.allCases {
            let group = items.filter { $0.category == category }
            guard !group.isEmpty else { continue }
            print("\(category.title): \(group.count), \(Format.total(group))")
            for row in rows(group) {
                print("  " + row)
            }
            print()
        }
    }

    static func json(_ items: [Item]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(items), as: UTF8.self)
    }
}
