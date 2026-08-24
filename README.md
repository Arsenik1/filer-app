# Filer

Filer, metinleri tek bir gecici `file.txt` dosyasina yazip bu dosyayi Finder'da kopyalanmis gibi panoya koyan native bir macOS menu bar uygulamasidir.

## Kullanim

1. `./build-app.zsh` ile uygulamayi olusturun.
2. `open -n -g "./build/Filer.app"` ile uygulamayi baslatin.
3. Menu bardaki `F` ikonuna tiklayin veya `Ctrl + Option + Cmd + F` kisayolunu kullanin.
4. Metni alana yapistirin. Isterseniz `Paste Clipboard` butonu mevcut text panosunu alana yukler.
5. `Copy as file.txt` butonuna veya `Command + Return` kisayoluna basin.
6. Artik panodaki oge bir dosyadir; Finder'a, sohbete veya dosya yukleme alanina yapistirabilirsiniz.

## Dosya davranisi

- Uygulama her seferinde ayni dosyayi kullanir: `file.txt`.
- Dosya `FileManager.default.temporaryDirectory/Filer/file.txt` altinda uretilir.
- Yeni icerik eskisinin uzerine atomik olarak yazilir.
- Uygulama kendi kalici veri klasorunu veya dosya arsivini tutmaz.
- Dosyayi panoya koymak icin `NSPasteboard` uzerine Finder dosya URL'si yazilir.

## Build

```zsh
./build-app.zsh
```

DMG olusturmak icin:

```zsh
./build-dmg.zsh
```

Uygulama Apple Silicon ve macOS 26+ icin derlenir.
