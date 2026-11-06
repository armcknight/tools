import Foundation
import Shared

enum Remover {
    enum Outcome {
        case removed
        /// The item needs administrator rights. The command deletes it with `sudo`.
        case needsAdmin(command: String)
        case failed(String)
    }

    static func remove(_ item: Item) async -> Outcome {
        let fileManager = FileManager.default
        switch item.removal {
        case .trash(let path):
            return attempt(adminCommand: "sudo rm -rf \(shellQuote(path))") {
                try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
        case .remove(let path):
            return attempt(adminCommand: "sudo rm -rf \(shellQuote(path))") {
                try fileManager.removeItem(atPath: path)
            }
        case .removeContents(let path):
            return attempt(adminCommand: "sudo rm -rf \(shellQuote(path))/*") {
                for child in try fileManager.contentsOfDirectory(atPath: path) {
                    try fileManager.removeItem(atPath: path + "/" + child)
                }
            }
        case .simctlRuntime(let identifier):
            return await simctl(["runtime", "delete", identifier])
        case .simctlDevice(let udid):
            return await simctl(["delete", udid])
        case .simctlDyldCache(let runtime, let path):
            // The cache belongs to root. simctl asks CoreSimulator to remove it, so no sudo is needed when that works.
            if case .removed = await simctl(["runtime", "dyld_shared_cache", "remove", runtime]),
               !fileManager.fileExists(atPath: path) {
                return .removed
            }
            return attempt(adminCommand: "sudo rm -rf \(shellQuote(path))") {
                try fileManager.removeItem(atPath: path)
            }
        }
    }

    private static func attempt(adminCommand: String, _ body: () throws -> Void) -> Outcome {
        do {
            try body()
            return .removed
        } catch {
            return isPermissionError(error) ? .needsAdmin(command: adminCommand) : .failed(error.localizedDescription)
        }
    }

    private static func simctl(_ arguments: [String]) async -> Outcome {
        do {
            try await Shell.run("xcrun", arguments: ["simctl"] + arguments)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) {
            return true
        }
        let posix = error.domain == NSPOSIXErrorDomain ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
        if let posix, posix.domain == NSPOSIXErrorDomain, [Int(EACCES), Int(EPERM)].contains(posix.code) {
            return true
        }
        return false
    }

    static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
