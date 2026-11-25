import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
enum ClipboardImageTests {
    @MainActor
    static func main() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        let png = try fixture(as: .png)
        let jpeg = try fixture(as: .jpeg)
        let tiff = try fixture(as: .tiff)

        try check(ClipboardImageSource.detect(in: board) == nil, "Empty clipboard stays in text mode")
        try check(board.setString("plain text", forType: .string), "Could not put text on clipboard")
        try check(ClipboardImageSource.detect(in: board) == nil, "Plain text stays in text mode")
        try check(board.string(forType: .string) == "plain text", "Detection changed clipboard text")

        _ = board.clearContents()
        try check(board.setData(png, forType: .png), "Could not put PNG on clipboard")
        try check(board.setString("image link", forType: .string), "Could not put link on clipboard")
        let pngImage = try load(from: board, expecting: .png)
        try check(try pngImage.encoded(as: .png) == png, "PNG should not be re-encoded")
        try checkEncoding(try pngImage.encoded(as: .jpg), is: .jpeg)
        try checkEncoding(try pngImage.encoded(as: .jpeg), is: .jpeg)

        _ = board.clearContents()
        let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
        try check(board.setData(jpeg, forType: jpegType), "Could not put JPEG on clipboard")
        let jpegImage = try load(from: board, expecting: .jpg)
        try check(try jpegImage.encoded(as: .jpg) == jpeg, "JPG should not be re-encoded")
        try check(try jpegImage.encoded(as: .jpeg) == jpeg, "JPEG alias should not re-encode")
        try checkEncoding(try jpegImage.encoded(as: .png), is: .png)

        _ = board.clearContents()
        try check(board.setData(tiff, forType: .tiff), "Could not put TIFF on clipboard")
        let tiffImage = try load(from: board, expecting: .png)
        try checkEncoding(try tiffImage.encoded(as: .png), is: .png)
        try checkEncoding(try tiffImage.encoded(as: .jpg), is: .jpeg)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("filer-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Picture.JPEG")
        try jpeg.write(to: file)

        _ = board.clearContents()
        try check(board.writeObjects([file as NSURL]), "Could not copy image file URL")
        let fileFormat = await ClipboardImageSource.referencedFileFormat(in: board)
        try check(fileFormat == .jpg, "Opening should detect the JPEG file type from metadata")
        let fileImage = try load(from: board, expecting: .jpeg)
        try check(try fileImage.encoded(as: .jpeg) == jpeg, "Copied file should retain its bytes")

        _ = board.clearContents()
        let textFile = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: textFile)
        try check(board.writeObjects([textFile as NSURL]), "Could not copy text file URL")
        let textFileFormat = await ClipboardImageSource.referencedFileFormat(in: board)
        try check(textFileFormat == nil, "Opening should not treat a text file as an image")
        try check(ClipboardImageSource.detect(in: board) == nil, "Text file is not a pasteable image")

        _ = board.clearContents()
        try check(board.setData(Data([0, 1, 2]), forType: .png), "Could not set invalid image data")
        do {
            _ = try load(from: board, expecting: .png)
            throw Failure("Invalid image bytes should not load")
        } catch ClipboardImageError.unreadableImage {}

        try checkMarkedImage()
        print("Clipboard image tests passed")
    }

    private static func load(
        from board: NSPasteboard, expecting format: ImageFileFormat
    ) throws -> ClipboardImage {
        guard let source = ClipboardImageSource.detect(in: board) else {
            throw Failure("Image source missing for \(format.rawValue)")
        }
        try check(source.preferredFormat == format, "Expected \(format.rawValue) as default format")
        return try source.load(from: board)
    }

    private static func checkEncoding(_ data: Data, is type: UTType) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("Encoded \(type.identifier) could not be decoded")
        }
        try check(CGImageSourceGetType(source) as String? == type.identifier, "Wrong output format")
        try check(image.width == 4 && image.height == 3, "Output dimensions changed")
    }

    private static func checkMarkedImage() throws {
        let png = try fixture(as: .png, width: 64, height: 48, transparent: true)
        let image = try ClipboardImage(data: png)
        let stroke = ImageStroke(
            points: [CGPoint(x: 15.75, y: 12.5)],
            width: ImageStroke.defaultWidth
        )
        let marked = try decode(image.encoded(as: .png, strokes: [stroke]))
        try check(marked.width == 64 && marked.height == 48, "Markup changed the resolution")
        let center = try pixel(in: marked, x: 15, y: 35)
        let edge = try pixel(in: marked, x: 13, y: 35)
        let otherSide = try pixel(in: marked, x: 15, y: 12)
        try check(center == [255, 0, 0, 255], "The mark is not red at the expected position")
        try check(edge[3] > 0 && edge[3] < 255, "The brush edge was not antialiased")
        try check(otherSide[3] == 0, "Markup flipped the image or removed its transparency")

        let line = ImageStroke(
            points: [CGPoint(x: 16, y: 12), CGPoint(x: 26, y: 12), CGPoint(x: 40, y: 12)],
            width: 14
        )
        let jpeg = try image.encoded(as: .jpg, strokes: [line])
        let jpegImage = try decode(jpeg)
        try check(jpegImage.width == 64 && jpegImage.height == 48, "JPEG was resized")
        let jpegInk = try pixel(in: jpegImage, x: 34, y: 35)
        try check(jpegInk[0] > 220 && jpegInk[1] < 40 && jpegInk[2] < 40, "JPEG lost the brush stroke")

        let rotated = try ClipboardImage(data: fixture(
            as: .jpeg, width: 64, height: 48, orientation: 6
        ))
        try check(rotated.raster.width == 48 && rotated.raster.height == 64, "EXIF rotation ignored")
        let rotatedExport = try decode(rotated.encoded(as: .png, strokes: [stroke]))
        try check(
            rotatedExport.width == 48 && rotatedExport.height == 64,
            "Marked image should retain displayed orientation"
        )
    }

    private static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure("Image could not be decoded")
        }
        return image
    }

    private static func pixel(in image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        guard let sample = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ), let bytes = context.data?.assumingMemoryBound(to: UInt8.self)
        else { throw Failure("Could not sample the image") }
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeBufferPointer(start: bytes, count: 4))
    }

    private static func fixture(
        as type: UTType, width: Int = 4, height: Int = 3, transparent: Bool = false,
        orientation: Int = 1
    ) throws -> Data {
        let bytes = NSMutableData()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
            let destination = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil)
        else { throw Failure("Could not prepare the fixture") }

        if !transparent {
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let image = context.makeImage() else { throw Failure("Could not create the fixture image") }
        CGImageDestinationAddImage(
            destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        try check(CGImageDestinationFinalize(destination), "Could not encode the fixture")
        return bytes as Data
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?

        init(_ message: String) { errorDescription = message }
    }
}
