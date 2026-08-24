import AppKit
import Carbon
import Foundation

private let appName = "Filer"
private let statusTitle = "F"
private let hotkeyDescription = "Ctrl + Option + Cmd + F"
private let outputDirectoryName = "Filer"
private let outputFileName = "file.txt"

private enum FilerError: LocalizedError {
    case clipboardDoesNotContainText
    case clipboardWriteFailed

    var errorDescription: String? {
        switch self {
        case .clipboardDoesNotContainText:
            return "Clipboard does not contain plain text."
        case .clipboardWriteFailed:
            return "The file could not be copied to the clipboard."
        }
    }
}

private final class FilerTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 36, modifiers.contains(.command) {
            onCommandReturn?()
            return
        }

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

private final class FilerApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let fileManager = FileManager.default

    private var hotKeyRef: EventHotKeyRef?
    private var statusItem: NSStatusItem?
    private var editorPanel: NSPanel?
    private var editorTextView: FilerTextView?
    private var statusLabel: NSTextField?
    private var hasPositionedEditor = false

    private var outputURL: URL {
        fileManager.temporaryDirectory
            .appendingPathComponent(outputDirectoryName, isDirectory: true)
            .appendingPathComponent(outputFileName, isDirectory: false)
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
        let frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Filer"
        panel.minSize = NSSize(width: 480, height: 360)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let rootView = NSView()
        panel.contentView = rootView

        let titleLabel = NSTextField(labelWithString: "Create file.txt")
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

        let pasteButton = NSButton(
            title: "Paste Clipboard",
            target: self,
            action: #selector(pasteClipboard)
        )
        pasteButton.bezelStyle = .rounded

        let clearButton = NSButton(
            title: "Clear",
            target: self,
            action: #selector(clearText)
        )
        clearButton.bezelStyle = .rounded

        let copyButton = NSButton(
            title: "Copy as file.txt",
            target: self,
            action: #selector(copyAsFile)
        )
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = [.command]

        let closeButton = NSButton(
            title: "Close",
            target: self,
            action: #selector(closeEditor)
        )
        closeButton.bezelStyle = .rounded

        let spacer = NSView()
        let buttonStack = NSStackView(views: [pasteButton, clearButton, spacer, copyButton, closeButton])
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 8
        buttonStack.distribution = .fill
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let pathLabel = NSTextField(labelWithString: "Creates and replaces: \(outputURL.path)")
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.toolTip = outputURL.path

        let statusLabel = NSTextField(labelWithString: "Paste text and click Copy as file.txt.")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1

        [titleLabel, subtitleLabel, scrollView, buttonStack, pathLabel, statusLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            subtitleLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),

            buttonStack.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            buttonStack.heightAnchor.constraint(equalToConstant: 32),

            pathLabel.topAnchor.constraint(equalTo: buttonStack.bottomAnchor, constant: 12),
            pathLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            pathLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 3),
            statusLabel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
        ])

        textView.onCommandReturn = { [weak self] in
            self?.copyAsFile()
        }
        textView.onEscape = { [weak self] in
            self?.closeEditor()
        }

        self.editorPanel = panel
        self.editorTextView = textView
        self.statusLabel = statusLabel
    }

    @objc private func showEditorFromStatusBar() {
        showEditor(source: "status bar")
    }

    @objc private func showEditorFromMenu() {
        showEditor(source: "menu")
    }

    private func showEditor(source: String) {
        guard let editorPanel, let editorTextView else { return }

        if !hasPositionedEditor {
            editorPanel.center()
            hasPositionedEditor = true
        }

        NSApp.activate(ignoringOtherApps: true)
        editorPanel.makeKeyAndOrderFront(nil)
        editorPanel.orderFrontRegardless()
        editorPanel.makeFirstResponder(editorTextView)

        if source != "status bar" {
            updateStatus("Editor opened from \(source).")
        }
    }

    @objc private func pasteClipboard() {
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

    @objc private func clearText() {
        editorTextView?.string = ""
        editorTextView?.undoManager?.removeAllActions()
        editorPanel?.makeFirstResponder(editorTextView)
        updateStatus("Ready for text.")
    }

    @objc private func copyAsFile() {
        guard let editorTextView else { return }
        guard !editorTextView.string.isEmpty else {
            showError("Enter or paste text before copying the file.")
            return
        }

        do {
            try writeTextFile(editorTextView.string)
            try copyFileToClipboard(outputURL)
            updateStatus("Copied file.txt to clipboard as a Finder file.")
            editorPanel?.makeFirstResponder(editorTextView)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func closeEditor() {
        editorPanel?.orderOut(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func writeTextFile(_ text: String) throws {
        let directoryURL = outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: outputURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            try fileManager.removeItem(at: outputURL)
        }

        try Data(text.utf8).write(to: outputURL, options: .atomic)
    }

    private func copyFileToClipboard(_ fileURL: URL) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard pasteboard.writeObjects([fileURL as NSURL]) else {
            throw FilerError.clipboardWriteFailed
        }
    }

    private func updateStatus(_ message: String) {
        statusLabel?.stringValue = message
        statusLabel?.textColor = .secondaryLabelColor
        statusItem?.button?.toolTip = message
    }

    private func showError(_ message: String) {
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
            updateStatus("Global hotkey registration failed.")
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
                app.showEditor(source: "hotkey")
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

let app = NSApplication.shared
private let delegate = FilerApp()
app.delegate = delegate
app.run()
