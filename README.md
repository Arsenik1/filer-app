# Filer

Filer is a native macOS menu bar popup that converts text into a temporary `file.txt` and copies it as a Finder file.

## Installation

```zsh
./build-app.zsh
open -n -g "./build/Filer.app"
```

## Usage

Click the `F` menu bar icon or press `Ctrl + Option + Cmd + F`. Paste text, click `Copy as file.txt`, and paste the resulting file into Finder, a chat, or a file upload field. Press the same shortcut again to close the popup.

Requires Apple Silicon and macOS 26+.
