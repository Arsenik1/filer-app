# Filer

Filer is a native macOS popup utility opened from the menu bar.

## Purpose

It converts clipboard or editor text into a temporary `file.txt` and places the file on the clipboard as if it had been copied from Finder.

## Problem It Solves

Filer lets you share text as a file with Finder, chat applications, or file upload fields without creating a permanent file. Each generation overwrites the same temporary file.

## Installation

```zsh
./build-app.zsh
open -n -g "./build/Filer.app"
```

Click the `F` menu bar icon or press `Ctrl + Option + Cmd + F`. Paste your text and select `Copy as file.txt`; pressing the same shortcut while the popup is open closes it.

The file is stored at `FileManager.default.temporaryDirectory/Filer/file.txt`. Filer does not keep a permanent file archive.

Create a DMG with `./build-dmg.zsh`. Build with `FILER_DEBUG=1 ./build-app.zsh` to show debug status messages.

Requires Apple Silicon and macOS 26+.
