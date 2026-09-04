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
private let fileExtensions = [
    ".md",
    ".txt",
    ".json",
    ".sql",
    ".js",
    ".html",
    ".css",
    ".py",
    ".ts",
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

private final class FilerPopupBackgroundView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 20
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

    private func updateBorderColor() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let color = isDark ? NSColor.white : NSColor.black
        layer?.borderColor = color.withAlphaComponent(0.14).cgColor
    }
}

private final class FilerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class FilerApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let fileManager = FileManager.default

    private var hotKeyRef: EventHotKeyRef?
    private var statusItem: NSStatusItem?
    private var editorPanel: NSPanel?
    private var editorTextView: FilerTextView?
    private var titleLabel: NSTextField?
    private var copyButton: NSButton?
    private var fileNameField: NSTextField?
    private var extensionPopupButton: NSPopUpButton?
    private var pathLabel: NSTextField?
    private var statusLabel: NSTextField?
    private var successOverlay: NSVisualEffectView?
    private var successIconView: NSImageView?
    private var successDismissWorkItem: DispatchWorkItem?
    private var activeFeedbackSound: NSSound?
    private var selectedFileBaseName = defaultFileBaseName
    private var selectedFileExtension = defaultFileExtension

    private var outputFileName: String {
        "\(selectedFileBaseName)\(selectedFileExtension)"
    }

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
            title: "Copy as \(outputFileName)",
            target: self,
            action: #selector(copyAsFile)
        )
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.keyEquivalentModifierMask = [.command]

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
        extensionPopupButton.addItems(withTitles: fileExtensions)
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

        [titleLabel, subtitleLabel, scrollView, buttonStack, pathLabel, statusLabel, closeButton, successOverlay].forEach {
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

            scrollView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor, constant: -12),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),

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

        textView.onCommandReturn = { [weak self] in
            self?.copyAsFile()
        }
        textView.onEscape = { [weak self] in
            self?.closeEditor()
        }

        self.editorPanel = panel
        self.editorTextView = textView
        self.titleLabel = titleLabel
        self.copyButton = copyButton
        self.fileNameField = fileNameField
        self.extensionPopupButton = extensionPopupButton
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
        guard let editorPanel, let editorTextView else { return }

        resetSuccessOverlay()
        if !debugBuild {
            statusLabel?.stringValue = ""
            statusLabel?.isHidden = true
        }

        let wasVisible = editorPanel.isVisible
        if !wasVisible {
            resetFileSettings()
            clearEditorText()
        }
        centerEditorPanel()

        NSApp.activate(ignoringOtherApps: true)
        if !wasVisible {
            editorPanel.alphaValue = 0
        }
        editorPanel.makeKeyAndOrderFront(nil)
        editorPanel.orderFrontRegardless()
        editorPanel.makeFirstResponder(editorTextView)

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

    private func centerEditorPanel() {
        guard let editorPanel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(
            x: round(visibleFrame.midX - editorPanel.frame.width / 2),
            y: round(visibleFrame.midY - editorPanel.frame.height / 2)
        )
        editorPanel.setFrameOrigin(origin)
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
        clearEditorText()
        editorPanel?.makeFirstResponder(editorTextView)
        updateStatus("Ready for text.")
    }

    private func clearEditorText() {
        editorTextView?.string = ""
        editorTextView?.undoManager?.removeAllActions()
        editorTextView?.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let changedField = notification.object as? NSTextField,
              let fileNameField,
              changedField === fileNameField else {
            return
        }

        selectedFileBaseName = changedField.stringValue
        updateFormatLabels()
    }

    @objc private func fileExtensionChanged(_ sender: NSPopUpButton) {
        selectedFileExtension = sender.titleOfSelectedItem ?? defaultFileExtension
        updateFormatLabels()
        updateStatus("File extension set to \(selectedFileExtension).")
    }

    private func resetFileSettings() {
        selectedFileBaseName = defaultFileBaseName
        selectedFileExtension = defaultFileExtension
        fileNameField?.stringValue = defaultFileBaseName
        extensionPopupButton?.selectItem(withTitle: defaultFileExtension)
        updateFormatLabels()
    }

    private func updateFormatLabels() {
        titleLabel?.stringValue = "Create \(outputFileName)"
        copyButton?.title = "Copy as \(outputFileName)"
        pathLabel?.stringValue = "Creates and replaces: \(outputURL.path)"
        pathLabel?.toolTip = outputURL.path
    }

    @objc private func copyAsFile() {
        guard let editorTextView else { return }
        if let fileNameField {
            selectedFileBaseName = fileNameField.stringValue
        }

        guard !selectedFileBaseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !selectedFileBaseName.contains("/") else {
            showError(FilerError.invalidFileName.localizedDescription)
            return
        }

        guard !editorTextView.string.isEmpty else {
            showError("Enter or paste text before copying the file.")
            return
        }

        do {
            try writeTextFile(editorTextView.string)
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
        resetSuccessOverlay()
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

let app = NSApplication.shared
private let delegate = FilerApp()
app.delegate = delegate
app.run()
