import ArgumentParser
import CoreGraphics
import CoreText
import Foundation
import GitKit
import ImageIO
import Shared
import UniformTypeIdentifiers

@main
struct TagIcons: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Overlay version/commit/custom text onto app icons.",
        discussion: "Designed for use as an Xcode Run Script build phase. Renders text onto icons using CoreGraphics."
    )

    @Argument(help: "Mode: commit, version, custom, or cleanup.")
    var mode: String

    @Argument(help: "Path to the icons directory (.appiconset or directory containing icon PNGs).")
    var iconsPath: String

    @Argument(help: "Custom text (required when mode is 'custom').")
    var customText: String?

    @Option(help: "Path to Info.plist (reads from INFOPLIST_FILE env var if not provided).")
    var plistFile: String?

    func run() async throws {
        let git = Git()
        let icons = try discoverIcons()

        if mode == "cleanup" {
            for icon in icons {
                try git.run(.raw("checkout \"\(icon)\""))
            }
            print("Restored \(icons.count) icons.")
            return
        }

        let text = try await resolveText()

        for icon in icons {
            guard FileManager.default.fileExists(atPath: icon) else { continue }
            try renderOverlay(text: text, onIconAt: icon)
        }

        print("Tagged \(icons.count) icons with '\(text)'.")
    }

    private func resolveText() async throws -> String {
        switch mode {
        case "commit":
            let git = Git()
            return try git.run(.raw("rev-parse --short HEAD"))
        case "version":
            let plist = plistFile ?? ProcessInfo.processInfo.environment["INFOPLIST_FILE"] ?? ""
            guard !plist.isEmpty else {
                throw TagIconsError.missingPlist
            }
            let shortVersion = try await Plist.read(key: "CFBundleShortVersionString", from: plist)
            let buildVersion = try await Plist.read(key: "CFBundleVersion", from: plist)
            return "\(shortVersion)+\(buildVersion)"
        case "custom":
            guard let customText, !customText.isEmpty else {
                throw TagIconsError.missingCustomText
            }
            return customText
        default:
            throw TagIconsError.invalidMode(mode)
        }
    }

    private func discoverIcons() throws -> [String] {
        let resolvedPath = (iconsPath as NSString).expandingTildeInPath
        if resolvedPath.hasSuffix(".appiconset") {
            let contentsJson = "\(resolvedPath)/Contents.json"
            guard FileManager.default.fileExists(atPath: contentsJson) else {
                throw TagIconsError.noIconsFound
            }
            let data = try Data(contentsOf: URL(fileURLWithPath: contentsJson))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = json["images"] as? [[String: Any]] else {
                throw TagIconsError.noIconsFound
            }
            return images.compactMap { $0["filename"] as? String }
                .map { "\(resolvedPath)/\($0)" }
        } else {
            let contents = try FileManager.default.contentsOfDirectory(atPath: resolvedPath)
            return contents.filter { $0.hasSuffix(".png") }.map { "\(resolvedPath)/\($0)" }
        }
    }

    private func renderOverlay(text: String, onIconAt path: String) throws {
        guard let dataProvider = CGDataProvider(filename: path),
              let image = CGImage(pngDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw TagIconsError.couldNotLoadImage(path)
        }

        let width = image.width
        let height = image.height

        guard width == height else {
            print("Skipping non-square icon: \(path)")
            return
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw TagIconsError.couldNotCreateContext
        }

        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: rect)

        // Draw semi-transparent banner at the bottom
        let bannerHeight = CGFloat(height) * 0.3
        let bannerRect = CGRect(x: 0, y: 0, width: CGFloat(width), height: bannerHeight)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.6)
        context.fill(bannerRect)

        // Draw text using Core Text
        let fontSize = bannerHeight * 0.5
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): font,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ]
        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributedString)
        let textBounds = CTLineGetBoundsWithOptions(line, [])

        let textX = (CGFloat(width) - textBounds.width) / 2
        let textY = (bannerHeight - textBounds.height) / 2

        context.textPosition = CGPoint(x: textX, y: textY)
        CTLineDraw(line, context)

        // Write the result back
        guard let resultImage = context.makeImage() else {
            throw TagIconsError.couldNotRenderImage
        }

        let url = URL(fileURLWithPath: path) as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
            throw TagIconsError.couldNotWriteImage(path)
        }
        CGImageDestinationAddImage(destination, resultImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TagIconsError.couldNotWriteImage(path)
        }
    }
}

enum TagIconsError: LocalizedError {
    case invalidMode(String)
    case missingPlist
    case missingCustomText
    case noIconsFound
    case couldNotLoadImage(String)
    case couldNotCreateContext
    case couldNotRenderImage
    case couldNotWriteImage(String)

    var errorDescription: String? {
        switch self {
        case .invalidMode(let mode):
            return "Invalid mode '\(mode)'. Use commit, version, custom, or cleanup."
        case .missingPlist:
            return "No Info.plist path provided. Set --plist-file or INFOPLIST_FILE env var."
        case .missingCustomText:
            return "Custom mode requires text as the third argument."
        case .noIconsFound:
            return "No icons found at the specified path."
        case .couldNotLoadImage(let path):
            return "Could not load image: \(path)"
        case .couldNotCreateContext:
            return "Could not create graphics context."
        case .couldNotRenderImage:
            return "Could not render the tagged image."
        case .couldNotWriteImage(let path):
            return "Could not write image: \(path)"
        }
    }
}
