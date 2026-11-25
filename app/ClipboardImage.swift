import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageFileFormat: String, CaseIterable {
    case png = ".png"
    case jpg = ".jpg"
    case jpeg = ".jpeg"

    var type: UTType { self == .png ? .png : .jpeg }
}

enum ClipboardImageError: LocalizedError {
    case unreadableImage
    case encodingFailed(ImageFileFormat)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "The clipboard image could not be read."
        case .encodingFailed(let format):
            return "The image could not be saved as \(format.rawValue)."
        }
    }
}

enum ClipboardImageSource {
    case pasteboardData(NSPasteboard.PasteboardType, format: ImageFileFormat)
    case file(URL, format: ImageFileFormat)

    var preferredFormat: ImageFileFormat {
        switch self {
        case .pasteboardData(_, let format), .file(_, let format):
            return format
        }
    }

    static func bitmap(in pasteboard: NSPasteboard) -> ClipboardImageSource? {
        // These types can be checked without accessing image data.
        let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        if let type = pasteboard.availableType(from: [.png, jpegType]) {
            return .pasteboardData(type, format: type == .png ? .png : .jpg)
        }

        // macOS often provides TIFF bitmap data even for screenshots and copied PNGs.
        if pasteboard.types?.contains(.tiff) == true {
            return .pasteboardData(.tiff, format: .png)
        }

        return nil
    }

    static func referencedFileFormat(in pasteboard: NSPasteboard) async -> ImageFileFormat? {
        // Opening the panel should not request clipboard access just to classify a file.
        let metadata = try? await pasteboard.detectedMetadata(for: [\.contentType])
        switch metadata?.contentType {
        case .png: return .png
        case .jpeg: return .jpg
        default: return nil
        }
    }

    static func detect(in pasteboard: NSPasteboard) -> ClipboardImageSource? {
        if let bitmap = bitmap(in: pasteboard) { return bitmap }

        if pasteboard.types?.contains(.fileURL) == true,
           let urls = pasteboard.readObjects(
               forClasses: [NSURL.self],
               options: [.urlReadingFileURLsOnly: true]
           ) as? [URL] {
            for url in urls where !url.hasDirectoryPath {
                if let format = ImageFileFormat(rawValue: ".\(url.pathExtension.lowercased())") {
                    return .file(url, format: format)
                }
            }
        }

        return nil
    }

    func load(from pasteboard: NSPasteboard) throws -> ClipboardImage {
        let data: Data?
        switch self {
        case .pasteboardData(let type, _):
            data = pasteboard.data(forType: type)
        case .file(let url, _):
            data = try? Data(contentsOf: url)
        }

        guard let data else { throw ClipboardImageError.unreadableImage }
        return try ClipboardImage(data: data)
    }
}

struct ClipboardImage {
    let preview: NSImage
    private let data: Data
    private let source: CGImageSource
    private let sourceType: String

    init(data: Data) throws {
        let supportedTypes = [UTType.png, .jpeg, .tiff].map(\.identifier)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source) as String?,
              supportedTypes.contains(sourceType),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let preview = NSImage(data: data), preview.isValid else {
            throw ClipboardImageError.unreadableImage
        }
        self.data = data
        self.source = source
        self.sourceType = sourceType
        self.preview = preview
    }

    func encoded(as format: ImageFileFormat) throws -> Data {
        let targetType = format.type.identifier
        if targetType == sourceType {
            return data
        }

        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            result, targetType as CFString, 1, nil
        ) else {
            throw ClipboardImageError.encodingFailed(format)
        }

        let options = format == .png
            ? nil : [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImageFromSource(destination, source, 0, options)
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardImageError.encodingFailed(format)
        }
        return result as Data
    }
}
