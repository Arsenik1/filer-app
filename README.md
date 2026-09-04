# Filer

`Filer` is a native macOS menu bar app that turns text into a temporary file and copies it to the clipboard as a Finder file. It creates `file.md` by default, or lets you enter a name and choose a supported extension.

## What It Is For

- Quickly creating a file from clipboard text or typed content
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
4. Enter a file name, paste or type text, and select an extension.
5. Click `Copy as <name>.<extension>` or press `Cmd + Return`.
6. Paste the resulting file into Finder, a chat, or a file upload field.

## How It Works

1. Opening the popup clears its editor and resets the name to `file` and extension to `.md`.
2. Filer writes the text to the macOS temporary directory.
3. The file is copied to the clipboard as a Finder file.
4. The same global shortcut closes the popup when it is open.

## File Options

- Default name: `file`
- Default extension: `.md`
- Supported extensions: `.md`, `.txt`, `.json`, `.sql`, `.js`, `.html`, `.css`, `.py`, `.ts`
- File names cannot be empty or contain `/`.

The selected file replaces any existing file with the same name and extension in Filer's temporary directory.

## Requirements

- Apple Silicon (`arm64`)
- macOS 26+

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
