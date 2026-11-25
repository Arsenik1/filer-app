# Filer

`Filer` is a native macOS menu bar app that turns text or clipboard images into temporary files and copies them to the clipboard as Finder files.

## What It Is For

- Quickly creating a file from clipboard text or typed content
- Saving a copied image or screenshot as PNG or JPEG
- Pasting that file into Finder, chats, and file upload fields
- Switching common text formats without opening an editor

## Quick Start

1. Build the app.

```zsh
./build-app.zsh
```

2. Open the app.

```zsh
open -n -g "./build/Filer.app"
```

3. Click the `F` menu bar icon or press `Ctrl + Option + Cmd + F`.
4. Enter a file name and select an extension. Paste or type text, or paste an image with `Cmd + V` or `Paste Clipboard`.
5. Click `Copy as <name>.<extension>` or press `Cmd + Return`.
6. Paste the resulting file into Finder, a chat, or a file upload field.

## How It Works

1. Opening the popup clears its editor and resets the name to `file`. If there is an image on the clipboard, Filer shows an image paste area instead of the text editor.
2. Paste to preview the image at its native pixel scale when it fits, or click `Clear` to return to text. Draw with `Red Pen`, adjust its width from 1 to 30 image pixels (default: 5), or remove the last mark with `Cmd + Z` or `Undo Stroke`.
3. `Copy as…` writes the file to the macOS temporary directory. The saved image includes any marks and is not resized to the preview.
4. The file is copied to the clipboard as a Finder file.
5. The same global shortcut closes the popup when it is open.

## File Options

- Default name: `file`
- Text extensions: `.md` (default), `.txt`, `.json`, `.sql`, `.js`, `.html`, `.css`, `.py`, `.ts`
- Image extensions: `.png`, `.jpg`, `.jpeg`. Filer defaults to the clipboard image's format, or PNG for a clipboard bitmap provided as TIFF.
- File names cannot be empty or contain `/`.

The selected file replaces any existing file with the same name and extension in Filer's temporary directory.

## Requirements

- Apple Silicon (`arm64`)
- macOS 26+

## Image Tests

```zsh
mkdir -p build
swiftc app/ClipboardImage.swift app/ImageStroke.swift tests/ClipboardImageTests.swift \
  -o build/clipboard-image-tests
./build/clipboard-image-tests
```

## Build DMG

```zsh
./build-dmg.zsh
```

Output:

```text
./build/Filer.dmg
```

The DMG contains:

- `Filer.app`
- `Applications` shortcut
- `How to Open.txt`

## Runtime Files

Filer writes generated files under:

```text
${TMPDIR}/Filer/<name>.<extension>
```

This is a temporary macOS location and may be cleared by the system.
