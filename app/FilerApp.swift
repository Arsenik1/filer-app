import AppKit
import Carbon
import Foundation
import QuartzCore

private let appName = "Filer"
private let statusTitle = "F"
private let hotkeyDescription = "Ctrl + Option + Cmd + F"
private let outputDirectoryName = "Filer"
private let defaultFileBaseName = "file"
private let defaultFileExtension = ".md"
private let textPanelSize = NSSize(width: 640, height: 480)
private let imagePanelSize = NSSize(width: 900, height: 620)
private let customExtensionChoice = "Custom…"
private let textExtensionChoices = [
    ".md",
    ".txt",
    ".json",
    ".sql",
    ".js",
    ".html",
    ".css",
    ".py",
    ".ts",
    customExtensionChoice,
]
private let successSoundName = "Blow"

#if FILER_DEBUG
private let debugBuild = true
#else
private let debugBuild = false
#endif

private enum FilerError: LocalizedError {
    case clipboardDoesNotContainText
    case clipboardWriteFailed
    case invalidFileName

    var errorDescription: String? {
        switch self {
        case .clipboardDoesNotContainText:
            return "Clipboard does not contain plain text."
        case .clipboardWriteFailed:
            return "The file could not be copied to the clipboard."
        case .invalidFileName:
            return "Enter a file name without path separators."
        }
    }
}

private final class FilerTextView: NSTextView {
    var onEscape: (() -> Void)?
    var onPasteImage: (() -> Bool)?

    override func paste(_ sender: Any?) {
        if onPasteImage?() != true {
            super.paste(sender)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers == [.command] else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.keyCode {
        case UInt16(kVK_ANSI_A):
            selectAll(nil)
            return true
        case UInt16(kVK_ANSI_C):
            copy(nil)
            return true
        case UInt16(kVK_ANSI_V):
            paste(nil)
            return true
        case UInt16(kVK_ANSI_X):
            cut(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

private final class FilerImagePasteView: NSView {
    var onPaste: (() -> Void)?
    var onEscape: (() -> Void)?
    var onStrokesChanged: (() -> Void)?
    var penWidth = ImageStroke.defaultWidth
    var penEnabled = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private(set) var strokes: [ImageStroke] = []
    private var raster: CGImage?
    private var isDrawing = false
    private let placeholder = NSTextField(labelWithString: "Press ⌘V to paste an image")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Clipboard image preview")

        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var imageRect: NSRect {
        guard let raster, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(
            1 / (window?.backingScaleFactor ?? 1),
            bounds.width / CGFloat(raster.width),
            bounds.height / CGFloat(raster.height)
        )
        let width = CGFloat(raster.width) * scale
        let height = CGFloat(raster.height) * scale
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                      width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        guard let raster else {
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
                .stroke()
            return
        }

        let rect = imageRect
        guard !rect.isEmpty else { return }
        context.draw(raster, in: rect)
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        let scale = rect.width / CGFloat(raster.width)
        context.scaleBy(x: scale, y: scale)
        for stroke in strokes { stroke.draw(in: context) }
        context.restoreGState()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = imageRect
        if penEnabled, !rect.isEmpty { addCursorRect(rect, cursor: .crosshair) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        guard penEnabled, imageRect.contains(location), let point = imagePoint(at: location)
        else { return }

        strokes.append(ImageStroke(points: [point], width: penWidth))
        isDrawing = true
        needsDisplay = true
        onStrokesChanged?()
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard isDrawing, let point = imagePoint(at: location), let lastStroke = strokes.indices.last,
              strokes[lastStroke].points.last != point else { return }
        strokes[lastStroke].points.append(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        isDrawing = false
    }

    private func imagePoint(at location: NSPoint) -> CGPoint? {
        let rect = imageRect
        guard !rect.isEmpty, let raster else { return nil }
        let pixelsPerPoint = CGFloat(raster.width) / rect.width
        return CGPoint(x: (location.x - rect.minX) * pixelsPerPoint,
                       y: (location.y - rect.minY) * pixelsPerPoint)
    }

    func display(_ raster: CGImage?) {
        self.raster = raster
        placeholder.isHidden = raster != nil
        strokes.removeAll()
        isDrawing = false
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onStrokesChanged?()
    }

    func undoStroke() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        isDrawing = false
        needsDisplay = true
        onStrokesChanged?()
    }

    @objc func paste(_ sender: Any?) {
        onPaste?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder === self, event.keyCode == UInt16(kVK_ANSI_V),
           modifiers == [.command] {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class FilerPopupBackgroundView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        let cornerRadius: CGFloat = 20
        // Apply the same shape to the AppKit material and window shadow.
        maskImage = Self.roundedMask(radius: cornerRadius)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        updateBorderColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        return mask
    }

    private func updateBorderColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = isDark ? NSColor.white : NSColor.black
        layer?.borderColor = color.withAlphaComponent(0.14).cgColor
    }
}

private final class FilerPanel: NSPanel {
    weak var copyButton: NSButton?
    weak var imagePasteView: FilerImagePasteView?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handlePanelShortcut(event) || super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if !handlePanelShortcut(event) {
            super.sendEvent(event)
        }
    }

    private func handlePanelShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown, modifiers.contains(.command) else { return false }

        if event.keyCode == UInt16(kVK_ANSI_Z), modifiers == [.command],
           let imagePasteView, !imagePasteView.isHiddenOrHasHiddenAncestor {
            if !event.isARepeat {
                imagePasteView.undoStroke()
            }
            return true
        }

        guard event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter),
              let copyButton else { return false }

        if !event.isARepeat {
            copyButton.performClick(nil)
        }
        return true
    }
}

@main
private final class FilerApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let fileManager = FileManager.default

    private var hotKeyRef: EventHotKeyRef?
    private var statusItem: NSStatusItem?
    private var editorPanel: NSPanel?
    private var editorTextView: FilerTextView?
    private var textScrollView: NSScrollView?
    private var imagePasteView: FilerImagePasteView?
    private var markupToolbar: NSStackView?
    private var editorBottomConstraint: NSLayoutConstraint?
    private var penWidthLabel: NSTextField?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var copyButton: NSButton?
    private var fileNameField: NSTextField?
    private var extensionPopupButton: NSPopUpButton?
    private var customExtensionRow: NSStackView?
    private var customExtensionField: NSTextField?
    private var customExtensionHint: NSTextField?
    private var pathLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var successOverlay: NSVisualEffectView?
    private var successIconView: NSImageView?
    private var successDismissWorkItem: DispatchWorkItem?
    private var activeFeedbackSound: NSSound?
    private var selectedFileBaseName = defaultFileBaseName
    private var selectedTextExtension = defaultFileExtension
    private var selectedImageFormat: ImageFileFormat = .png
    private var isImageMode = false
    private var imageFormatWasManuallySelected = false
    private var pastedImage: ClipboardImage?
    private var imageDetectionTask: Task<Void, Never>?

    private var selectedExtensionChoice: String {
        isImageMode ? selectedImageFormat.rawValue : selectedTextExtension
    }

    private var usesCustomExtension: Bool { selectedExtensionChoice == customExtensionChoice }

    private var customExtensionInput: String {
        customExtensionField?.currentEditor()?.string ?? customExtensionField?.stringValue ?? ""
    }

    private var selectedFileExtension: String? {
        guard usesCustomExtension else { return selectedExtensionChoice }
        let input = customExtensionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = input.hasPrefix(".") ? String(input.dropFirst()) : input
        let disallowed = CharacterSet(charactersIn: "/\\:").union(.controlCharacters)
        guard suffix.contains(where: { !$0.isWhitespace && $0 != "." }),
              suffix.rangeOfCharacter(from: disallowed) == nil else { return nil }
        return ".\(suffix)"
    }

    private var outputFileName: String {
        "\(selectedFileBaseName)\(selectedFileExtension ?? "")"
    }

    private var outputURL: URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(outputDirectoryName, isDirectory: true)
            .appendingPathComponent(outputFileName, isDirectory: false)
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = FilerApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        setupEditorPanel()
        registerHotkey()
        updateStatus("Ready: \(hotkeyDescription)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)

        let openItem = NSMenuItem(
            title: "Open Filer",
            action: #selector(showEditorFromMenu),
            keyEquivalent: ""
        )
        let quitItem = NSMenuItem(
            title: "Quit Filer",
            action: #selector(quitApp),
            keyEquivalent: "q"
        )

        appMenu.addItem(openItem)
        appMenu.addItem(.separator())
        appMenu.addItem(quitItem)
        appMenu.items.forEach { $0.target = self }

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Undo",
            action: NSSelectorFromString("undo:"),
            keyEquivalent: "z"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Redo",
            action: NSSelectorFromString("redo:"),
            keyEquivalent: "Z"
        ))
        editMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(
            title: "Cut",
            action: NSSelectorFromString("cut:"),
            keyEquivalent: "x"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Copy",
            action: NSSelectorFromString("copy:"),
            keyEquivalent: "c"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Paste",
            action: NSSelectorFromString("paste:"),
            keyEquivalent: "v"
        ))
        editMenu.addItem(NSMenuItem(
            title: "Select All",
            action: NSSelectorFromString("selectAll:"),
            keyEquivalent: "a"
        ))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        button.title = statusTitle
        button.toolTip = "Open Filer (\(hotkeyDescription))"
        button.target = self
        button.action = #selector(showEditorFromStatusBar)
        button.sendAction(on: [.leftMouseUp])

        statusItem = item
    }

    private func setupEditorPanel() {
        let frame = NSRect(origin: .zero, size: textPanelSize)
        let panel = FilerPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self

        let rootView = FilerPopupBackgroundView()
        panel.contentView = rootView

        let titleLabel = NSTextField(labelWithString: "Create \(outputFileName)")
        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .semibold)

        let subtitleLabel = NSTextField(
            labelWithString: "Paste text below, then copy it as a Finder file."
        )
        subtitleLabel.textColor = .secondaryLabelColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = FilerTextView(frame: .zero)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.textContainer?.widthTracksTextView = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        scrollView.documentView = textView

        let editorArea = NSView()
        let imagePasteView = FilerImagePasteView()
        imagePasteView.isHidden = true
        panel.imagePasteView = imagePasteView
        for editor in [scrollView, imagePasteView] as [NSView] {
            editor.translatesAutoresizingMaskIntoConstraints = false
            editorArea.addSubview(editor)
            NSLayoutConstraint.activate([
                editor.topAnchor.constraint(equalTo: editorArea.topAnchor),
                editor.leadingAnchor.constraint(equalTo: editorArea.leadingAnchor),
                editor.trailingAnchor.constraint(equalTo: editorArea.trailingAnchor),
                editor.bottomAnchor.constraint(equalTo: editorArea.bottomAnchor),
            ])
        }

        let pasteButton = NSButton(
            title: "Paste Clipboard",
            target: self,
            action: #selector(pasteClipboard)
        )
        pasteButton.bezelStyle = .rounded

        let clearButton = NSButton(
            title: "Clear",
            target: self,
            action: #selector(clearEditor)
        )
        clearButton.bezelStyle = .rounded

        let copyButton = NSButton(
            title: "Copy as \(outputFileName)",
            target: self,
            action: #selector(copyAsFile)
        )
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = [.command]
        panel.copyButton = copyButton

        let fileNameField = NSTextField(string: defaultFileBaseName)
        fileNameField.isEditable = true
        fileNameField.isSelectable = true
        fileNameField.isBordered = true
        fileNameField.bezelStyle = .roundedBezel
        fileNameField.placeholderString = "File name"
        fileNameField.toolTip = "Enter the file name"
        fileNameField.delegate = self
        fileNameField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let extensionPopupButton = NSPopUpButton(frame: .zero, pullsDown: false)
        extensionPopupButton.addItems(withTitles: textExtensionChoices)
        extensionPopupButton.selectItem(withTitle: defaultFileExtension)
        extensionPopupButton.target = self
        extensionPopupButton.action = #selector(fileExtensionChanged(_:))
        extensionPopupButton.toolTip = "Choose the file extension"

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")!,
            target: self,
            action: #selector(closeEditor)
        )
        closeButton.isBordered = false
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close"

        let spacer = NSView()
        let buttonStack = NSStackView(
            views: [pasteButton, clearButton, spacer, fileNameField, extensionPopupButton, copyButton]
        )
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.distribution = .fill
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let customExtensionField = NSTextField(string: "")
        customExtensionField.bezelStyle = .roundedBezel
        customExtensionField.placeholderString = "e.g. log or .tar.gz"
        customExtensionField.setAccessibilityLabel("Custom file extension")
        customExtensionField.delegate = self
        customExtensionField.widthAnchor.constraint(equalToConstant: 144).isActive = true

        let customExtensionHint = NSTextField(labelWithString: "")
        customExtensionHint.textColor = .secondaryLabelColor
        let customExtensionRow = NSStackView(views: [
            NSTextField(labelWithString: "Extension"), customExtensionField, customExtensionHint,
        ])
        customExtensionRow.orientation = .horizontal
        customExtensionRow.alignment = .centerY
        customExtensionRow.spacing = 8
        customExtensionRow.isHidden = true

        let penButton = NSButton(
            title: "Red Pen", target: self, action: #selector(togglePen(_:))
        )
        penButton.setButtonType(.pushOnPushOff)
        penButton.bezelStyle = .rounded
        penButton.state = .on

        let penWidth = NSSlider(
            value: Double(ImageStroke.defaultWidth),
            minValue: Double(ImageStroke.widths.lowerBound),
            maxValue: Double(ImageStroke.widths.upperBound),
            target: self,
            action: #selector(penWidthChanged(_:))
        )
        penWidth.isContinuous = true
        penWidth.setAccessibilityLabel("Pen width in pixels")
        penWidth.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let penWidthLabel = NSTextField(labelWithString: "\(ImageStroke.defaultWidth) px")
        penWidthLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        penWidthLabel.widthAnchor.constraint(equalToConstant: 42).isActive = true

        let undoButton = NSButton(
            title: "Undo Stroke", target: self, action: #selector(undoImageStroke)
        )
        undoButton.bezelStyle = .rounded
        undoButton.toolTip = "Undo the last stroke (⌘Z)"
        undoButton.isEnabled = false

        let markupToolbar = NSStackView(views: [penButton, penWidth, penWidthLabel, undoButton])
        markupToolbar.orientation = .horizontal
        markupToolbar.alignment = .centerY
        markupToolbar.spacing = 8
        markupToolbar.isHidden = true
        let editorBottomConstraint = editorArea.bottomAnchor.constraint(
            equalTo: buttonStack.topAnchor, constant: -12
        )

        let pathLabel = NSTextField(labelWithString: "Creates and replaces: \(outputURL.path)")
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.toolTip = outputURL.path

        let statusLabel = NSTextField(
            labelWithString: "Paste text and click Copy as \(outputFileName)."
        )
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        let successOverlay = NSVisualEffectView()
        successOverlay.material = .hudWindow
        successOverlay.blendingMode = .withinWindow
        successOverlay.state = .active
        successOverlay.wantsLayer = true
        successOverlay.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        successOverlay.isHidden = true
        successOverlay.alphaValue = 0

        let successIconView = NSImageView()
        successIconView.image = NSImage(
            systemSymbolName: "checkmark.circle.fill",
            accessibilityDescription: "Copied"
        )
        successIconView.contentTintColor = .systemGreen
        successIconView.imageScaling = .scaleProportionallyUpOrDown
        successIconView.wantsLayer = true
        successIconView.translatesAutoresizingMaskIntoConstraints = false
        successOverlay.addSubview(successIconView)

        let panelViews = [
            titleLabel, subtitleLabel, editorArea, markupToolbar, customExtensionRow, buttonStack,
            pathLabel, statusLabel, closeButton, successOverlay,
        ]
        panelViews.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview($0)
        }

        var constraints: [NSLayoutConstraint] = [
            titleLabel.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -64),

            closeButton.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),

            editorArea.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            editorArea.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            editorArea.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            editorBottomConstraint,

            markupToolbar.leadingAnchor.constraint(equalTo: editorArea.leadingAnchor),
            markupToolbar.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),
            markupToolbar.heightAnchor.constraint(equalToConstant: 28),

            customExtensionRow.leadingAnchor.constraint(equalTo: editorArea.leadingAnchor),
            customExtensionRow.bottomAnchor.constraint(equalTo: markupToolbar.bottomAnchor),
            customExtensionRow.heightAnchor.constraint(equalTo: markupToolbar.heightAnchor),

            buttonStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            buttonStack.heightAnchor.constraint(equalToConstant: 32),

            successOverlay.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            successOverlay.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            successOverlay.topAnchor.constraint(equalTo: rootView.topAnchor),
            successOverlay.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            successIconView.centerXAnchor.constraint(equalTo: successOverlay.centerXAnchor),
            successIconView.centerYAnchor.constraint(equalTo: successOverlay.centerYAnchor),
            successIconView.widthAnchor.constraint(equalToConstant: 96),
            successIconView.heightAnchor.constraint(equalToConstant: 96),
        ]

        if debugBuild {
            constraints += [
                pathLabel.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 12),
                pathLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
                pathLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),

                statusLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 3),
                statusLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
                statusLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
                statusLabel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            ]
        } else {
            constraints.append(buttonStack.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16))
        }

        NSLayoutConstraint.activate(constraints)

        textView.onEscape = { [weak self] in
            self?.closeEditor()
        }
        textView.onPasteImage = { [weak self] in
            self?.pasteImageIfAvailable() ?? false
        }
        imagePasteView.onPaste = { [weak self] in
            self?.pasteClipboard()
        }
        imagePasteView.onEscape = textView.onEscape
        imagePasteView.onStrokesChanged = { [weak imagePasteView, weak undoButton] in
            undoButton?.isEnabled = imagePasteView?.strokes.isEmpty == false
        }

        self.editorPanel = panel
        self.editorTextView = textView
        self.textScrollView = scrollView
        self.imagePasteView = imagePasteView
        self.markupToolbar = markupToolbar
        self.editorBottomConstraint = editorBottomConstraint
        self.penWidthLabel = penWidthLabel
        self.titleLabel = titleLabel
        self.subtitleLabel = subtitleLabel
        self.copyButton = copyButton
        self.fileNameField = fileNameField
        self.extensionPopupButton = extensionPopupButton
        self.customExtensionRow = customExtensionRow
        self.customExtensionField = customExtensionField
        self.customExtensionHint = customExtensionHint
        self.pathLabel = pathLabel
        self.statusLabel = statusLabel
        self.successOverlay = successOverlay
        self.successIconView = successIconView
        pathLabel.isHidden = !debugBuild
        statusLabel.isHidden = !debugBuild
    }

    @objc private func showEditorFromStatusBar() {
        showEditor(source: "status bar")
    }

    @objc private func showEditorFromMenu() {
        showEditor(source: "menu")
    }

    private func toggleEditor(source: String) {
        guard let editorPanel else { return }

        if editorPanel.isVisible {
            closeEditor()
        } else {
            showEditor(source: source)
        }
    }

    private func showEditor(source: String) {
        guard let editorPanel else { return }

        resetSuccessOverlay()
        if !debugBuild {
            statusLabel?.stringValue = ""
            statusLabel?.isHidden = true
        }

        let wasVisible = editorPanel.isVisible
        if !wasVisible {
            clearEditorText()
            resetEditorForClipboard()
        }
        centerEditorPanel()

        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible {
            editorPanel.alphaValue = 0
        }
        editorPanel.makeKeyAndOrderFront(nil)
        editorPanel.orderFrontRegardless()
        focusEditor()

        if !wasVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                editorPanel.animator().alphaValue = 1
            }
        }

        if source != "status bar" {
            updateStatus("Editor opened from \(source).")
        }
    }

    private func resetEditorForClipboard() {
        let pasteboard = NSPasteboard.general
        let bitmap = ClipboardImageSource.bitmap(in: pasteboard)
        resetFileSettings(imageFormat: bitmap?.preferredFormat)

        guard bitmap == nil, pasteboard.types?.contains(.fileURL) == true else { return }
        let changeCount = pasteboard.changeCount
        imageDetectionTask = Task { @MainActor [weak self] in
            guard let format = await ClipboardImageSource.referencedFileFormat(in: pasteboard),
                  !Task.isCancelled, pasteboard.changeCount == changeCount,
                  let self, editorPanel?.isVisible == true,
                  editorTextView?.string.isEmpty == true, !isImageMode else { return }

            let editorWasFocused = editorPanel?.firstResponder === editorTextView
            selectedImageFormat = format
            setImageMode(true)
            resizeVisibleEditorPanel()
            if editorWasFocused { focusEditor() }
        }
    }

    private func centerEditorPanel(on preferredScreen: NSScreen? = nil) {
        guard let editorPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let screen = preferredScreen
            ?? NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let availableSize = visibleFrame.insetBy(dx: 16, dy: 16).size
        var size = textPanelSize
        if isImageMode {
            var requestedSize = imagePanelSize
            if let raster = pastedImage?.raster, let imagePasteView {
                editorPanel.contentView?.layoutSubtreeIfNeeded()
                let scale = screen?.backingScaleFactor ?? editorPanel.backingScaleFactor
                let chromeWidth = editorPanel.frame.width - imagePasteView.frame.width
                let chromeHeight = editorPanel.frame.height - imagePasteView.frame.height
                requestedSize = NSSize(
                    width: max(
                        textPanelSize.width, ceil(CGFloat(raster.width) / scale + chromeWidth)
                    ),
                    height: max(
                        textPanelSize.height, ceil(CGFloat(raster.height) / scale + chromeHeight)
                    )
                )
            }
            size = NSSize(width: min(requestedSize.width, availableSize.width),
                          height: min(requestedSize.height, availableSize.height))
        }
        let origin = NSPoint(
            x: round(visibleFrame.midX - size.width / 2),
            y: round(visibleFrame.midY - size.height / 2)
        )
        editorPanel.setFrame(NSRect(origin: origin, size: size), display: editorPanel.isVisible)
    }

    private func resizeVisibleEditorPanel() {
        guard let editorPanel, editorPanel.isVisible else { return }
        centerEditorPanel(on: editorPanel.screen)
    }

    @objc private func pasteClipboard() {
        if pasteImageIfAvailable() { return }
        if isImageMode {
            showError("Clipboard does not contain a supported image.")
            return
        }

        guard let editorTextView else { return }
        guard let clipboardText = NSPasteboard.general.string(forType: .string) else {
            showError(FilerError.clipboardDoesNotContainText.localizedDescription)
            return
        }

        editorTextView.string = clipboardText
        let endLocation = editorTextView.string.utf16.count
        editorTextView.setSelectedRange(NSRange(location: endLocation, length: 0))
        editorTextView.scrollRangeToVisible(NSRange(location: endLocation, length: 0))
        editorPanel?.makeFirstResponder(editorTextView)
        updateStatus("Clipboard text loaded.")
    }

    private func pasteImageIfAvailable() -> Bool {
        imageDetectionTask?.cancel()
        let pasteboard = NSPasteboard.general
        guard let source = ClipboardImageSource.detect(in: pasteboard) else { return false }
        do {
            let image = try source.load(from: pasteboard)
            if !imageFormatWasManuallySelected {
                selectedImageFormat = source.preferredFormat
            }
            setImageMode(true)
            pastedImage = image
            imagePasteView?.display(image.raster)
            setMarkupToolbarVisible(true)
            resizeVisibleEditorPanel()
            focusEditor()
            updateStatus("Clipboard image loaded.")
        } catch {
            showError(error.localizedDescription)
        }
        return true
    }

    @objc private func clearEditor() {
        imageDetectionTask?.cancel()
        if isImageMode {
            clearEditorImage()
            setImageMode(false)
            resizeVisibleEditorPanel()
        } else {
            clearEditorText()
        }
        focusEditor()
        updateStatus("Ready for text.")
    }

    private func focusEditor() {
        let responder: NSResponder? = isImageMode ? imagePasteView : editorTextView
        editorPanel?.makeFirstResponder(responder)
    }

    private func clearEditorImage() {
        imageDetectionTask?.cancel()
        imageDetectionTask = nil
        imageFormatWasManuallySelected = false
        pastedImage = nil
        imagePasteView?.display(nil)
        setMarkupToolbarVisible(false)
    }

    private func setMarkupToolbarVisible(_ visible: Bool) {
        markupToolbar?.isHidden = !visible
        updateAccessoryLayout()
    }

    private func updateAccessoryLayout() {
        if !usesCustomExtension, customExtensionField?.currentEditor() != nil {
            focusEditor()
        }
        customExtensionRow?.isHidden = !usesCustomExtension
        let showsAccessory = usesCustomExtension || markupToolbar?.isHidden == false
        editorBottomConstraint?.constant = showsAccessory ? -46 : -12
    }

    @objc private func togglePen(_ sender: NSButton) {
        imagePasteView?.penEnabled = sender.state == .on
        focusEditor()
    }

    @objc private func penWidthChanged(_ sender: NSSlider) {
        let width = Int(sender.doubleValue.rounded())
        sender.integerValue = width
        imagePasteView?.penWidth = width
        penWidthLabel?.stringValue = "\(width) px"
    }

    @objc private func undoImageStroke() {
        imagePasteView?.undoStroke()
        focusEditor()
    }

    private func clearEditorText() {
        editorTextView?.string = ""
        editorTextView?.undoManager?.removeAllActions()
        editorTextView?.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let changedField = notification.object as? NSTextField else { return }
        if changedField === fileNameField {
            selectedFileBaseName = changedField.stringValue
        } else if changedField !== customExtensionField {
            return
        }
        updateFormatLabels()
    }

    @objc private func fileExtensionChanged(_ sender: NSPopUpButton) {
        if isImageMode {
            if let title = sender.titleOfSelectedItem, let format = ImageFileFormat(rawValue: title) {
                selectedImageFormat = format
                imageFormatWasManuallySelected = true
            }
        } else {
            selectedTextExtension = sender.titleOfSelectedItem ?? defaultFileExtension
            updateAccessoryLayout()
            if usesCustomExtension {
                customExtensionField?.selectText(nil)
            }
        }
        updateFormatLabels()
        if let selectedFileExtension {
            updateStatus("File extension set to \(selectedFileExtension).")
        }
    }

    private func resetFileSettings(imageFormat: ImageFileFormat?) {
        selectedFileBaseName = defaultFileBaseName
        selectedTextExtension = defaultFileExtension
        selectedImageFormat = imageFormat ?? .png
        fileNameField?.stringValue = defaultFileBaseName
        if customExtensionField?.currentEditor() != nil {
            editorPanel?.makeFirstResponder(nil)
        }
        customExtensionField?.stringValue = ""
        setImageMode(imageFormat != nil)
    }

    private func setImageMode(_ enabled: Bool) {
        if isImageMode != enabled {
            isImageMode = enabled
            textScrollView?.isHidden = enabled
            imagePasteView?.isHidden = !enabled
            subtitleLabel?.stringValue = enabled
                ? "Paste an image below, then copy it as a Finder file. Clear returns to text."
                : "Paste text below, then copy it as a Finder file."

            extensionPopupButton?.removeAllItems()
            extensionPopupButton?.addItems(
                withTitles: enabled ? ImageFileFormat.allCases.map(\.rawValue) : textExtensionChoices
            )
        }
        extensionPopupButton?.selectItem(withTitle: selectedExtensionChoice)
        updateAccessoryLayout()
        updateFormatLabels()
    }

    private func updateFormatLabels() {
        let validExtension = selectedFileExtension != nil
        copyButton?.isEnabled = validExtension
        if usesCustomExtension {
            customExtensionHint?.stringValue = validExtension ? "" : "Enter a valid extension."
        }
        titleLabel?.stringValue = "Create \(outputFileName)"
        copyButton?.title = usesCustomExtension && (!validExtension || outputFileName.count > 24)
            ? "Copy as File" : "Copy as \(outputFileName)"
        copyButton?.toolTip = usesCustomExtension && validExtension ? outputFileName : nil
        pathLabel?.stringValue = "Creates and replaces: \(outputURL.path)"
        pathLabel?.toolTip = outputURL.path
    }

    @objc private func copyAsFile() {
        guard let editorTextView else { return }
        guard selectedFileExtension != nil else {
            customExtensionField?.selectText(nil)
            return
        }
        if let fileNameField {
            fileNameField.validateEditing()
            selectedFileBaseName = fileNameField.stringValue
        }

        guard !selectedFileBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selectedFileBaseName.contains("/") else {
            showError(FilerError.invalidFileName.localizedDescription)
            return
        }

        do {
            let data: Data
            if isImageMode {
                guard let pastedImage else {
                    showError("Paste an image before copying the file.")
                    return
                }
                data = try pastedImage.encoded(
                    as: selectedImageFormat, strokes: imagePasteView?.strokes ?? []
                )
            } else {
                guard !editorTextView.string.isEmpty else {
                    showError("Enter or paste text before copying the file.")
                    return
                }
                data = Data(editorTextView.string.utf8)
            }
            try writeFile(data)
            try copyFileToClipboard(outputURL)
            updateStatus("Copied \(outputFileName) to clipboard as a Finder file.")
            showSuccessAndClose()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showSuccessAndClose() {
        guard let editorPanel, let successOverlay, let successIconView else {
            closeEditor()
            return
        }

        successDismissWorkItem?.cancel()
        successDismissWorkItem = nil
        editorTextView?.isEditable = false
        editorTextView?.isSelectable = false
        editorPanel.makeFirstResponder(nil)
        editorPanel.alphaValue = 1
        successOverlay.isHidden = false
        successOverlay.alphaValue = 0
        successIconView.alphaValue = 0
        successIconView.layer?.removeAllAnimations()
        playSuccessSound()

        let popAnimation = CASpringAnimation(keyPath: "transform.scale")
        popAnimation.fromValue = 0.55
        popAnimation.toValue = 1.0
        popAnimation.initialVelocity = 0.4
        popAnimation.damping = 12
        popAnimation.mass = 0.6
        popAnimation.stiffness = 180
        popAnimation.duration = popAnimation.settlingDuration
        successIconView.layer?.add(popAnimation, forKey: "checkmark.pop")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            successOverlay.animator().alphaValue = 1
            successIconView.animator().alphaValue = 1
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismissSuccess()
        }
        successDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62, execute: workItem)
    }

    private func playSuccessSound() {
        let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/\(successSoundName).aiff")
        guard fileManager.fileExists(atPath: soundURL.path),
              let sound = NSSound(contentsOf: soundURL, byReference: true) else {
            return
        }

        activeFeedbackSound = sound
        sound.play()
    }

    private func dismissSuccess() {
        successDismissWorkItem = nil
        guard let editorPanel else {
            resetSuccessOverlay()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            editorPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            editorPanel.orderOut(nil)
            editorPanel.alphaValue = 1
            self.clearEditorImage()
            self.resetSuccessOverlay()
        })
    }

    private func resetSuccessOverlay() {
        successDismissWorkItem?.cancel()
        successDismissWorkItem = nil
        successOverlay?.isHidden = true
        successOverlay?.alphaValue = 0
        successIconView?.alphaValue = 1
        successIconView?.layer?.removeAllAnimations()
        editorTextView?.isEditable = true
        editorTextView?.isSelectable = true
    }

    @objc private func closeEditor() {
        successDismissWorkItem?.cancel()
        editorPanel?.orderOut(nil)
        editorPanel?.alphaValue = 1
        clearEditorImage()
        resetSuccessOverlay()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func writeFile(_ data: Data) throws {
        let directoryURL = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try fileManager.removeItem(at: outputURL)
        }

        try data.write(to: outputURL, options: .atomic)
    }

    private func copyFileToClipboard(_ fileURL: URL) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard pasteboard.writeObjects([fileURL as NSURL]) else {
            throw FilerError.clipboardWriteFailed
        }
    }

    private func updateStatus(_ message: String) {
        guard debugBuild else {
            statusLabel?.stringValue = ""
            statusLabel?.isHidden = true
            statusItem?.button?.toolTip = "Open Filer (\(hotkeyDescription))"
            return
        }

        statusLabel?.isHidden = false
        statusLabel?.stringValue = message
        statusLabel?.textColor = .secondaryLabelColor
        statusItem?.button?.toolTip = message
    }

    private func showError(_ message: String) {
        statusLabel?.isHidden = false
        statusLabel?.stringValue = message
        statusLabel?.textColor = .systemRed
        statusItem?.button?.toolTip = message
        NSSound.beep()
    }

    private func registerHotkey() {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("FLER"), id: 1)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_F),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            showError("Global hotkey registration failed.")
            return
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let app = Unmanaged<FilerApp>.fromOpaque(userData).takeUnretainedValue()
                app.toggleEditor(source: "hotkey")
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}
