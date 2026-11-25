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

    private static func fixture(as type: UTType) throws -> Data {
        let bytes = NSMutableData()
        guard let context = CGContext(
            data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
            let destination = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil)
        else { throw Failure("Could not prepare the fixture") }

        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        guard let image = context.makeImage() else { throw Failure("Could not create the fixture image") }
        CGImageDestinationAddImage(destination, image, nil)
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
