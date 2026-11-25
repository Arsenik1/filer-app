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
    let raster: CGImage
    private let data: Data
    private let source: CGImageSource
    private let sourceType: String

    init(data: Data) throws {
        let supportedTypes = [UTType.png, .jpeg, .tiff].map(\.identifier)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source) as String?,
              supportedTypes.contains(sourceType),
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let raster = Self.orientedRaster(from: source) else {
            throw ClipboardImageError.unreadableImage
        }
        self.data = data
        self.source = source
        self.sourceType = sourceType
        self.raster = raster
    }

    private static func orientedRaster(from source: CGImageSource) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
        if orientation != 1,
           let width = properties?[kCGImagePropertyPixelWidth] as? Int,
           let height = properties?[kCGImagePropertyPixelHeight] as? Int {
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            ] as CFDictionary
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func encoded(as format: ImageFileFormat, strokes: [ImageStroke] = []) throws -> Data {
        let targetType = format.type.identifier
        if strokes.isEmpty && targetType == sourceType {
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
        if strokes.isEmpty {
            CGImageDestinationAddImageFromSource(destination, source, 0, options)
        } else {
            let markedImage = try render(strokes: strokes, format: format)
            CGImageDestinationAddImage(destination, markedImage, options)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardImageError.encodingFailed(format)
        }
        return result as Data
    }

    private func render(strokes: [ImageStroke], format: ImageFileFormat) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: raster.width, height: raster.height, bitsPerComponent: 8,
                  bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw ClipboardImageError.encodingFailed(format) }

        let bounds = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)
        if format != .png {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(bounds)
        }
        context.draw(raster, in: bounds)
        for stroke in strokes {
            stroke.draw(in: context)
        }
        guard let image = context.makeImage() else { throw ClipboardImageError.encodingFailed(format) }
        return image
    }
}
