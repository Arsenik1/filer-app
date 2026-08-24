# Filer

Filer, macOS menu bar'dan acilan native bir popup uygulamasidir.

## Amaci

Panodaki veya metin alanindaki icerigi gecici bir `file.txt` dosyasina donusturur ve dosyayi Finder'da kopyalanmis gibi panoya koyar.

## Cozdugu Problem

Metin icerigini kalici bir dosya olusturmadan Finder'a, sohbet uygulamalarina veya dosya yukleme alanlarina dosya olarak aktarir. Her seferinde ayni gecici dosyanin uzerine yazar.

## Kurulum

```zsh
./build-app.zsh
open -n -g "./build/Filer.app"
```

Ardindan menu bardaki `F` ikonuna tiklayin veya `Ctrl + Option + Cmd + F` kisayolunu kullanin. Metni yapistirip `Copy as file.txt` secenegine basin; ayni kisayol popup acikken tekrar basilirsa kapatir.

Dosya `FileManager.default.temporaryDirectory/Filer/file.txt` altinda tutulur. Uygulama kalici dosya arsivi tutmaz.

DMG olusturmak icin `./build-dmg.zsh` komutunu kullanin. Debug durumlarini gormek icin `FILER_DEBUG=1 ./build-app.zsh` ile derleyin.

Apple Silicon ve macOS 26+ icin derlenir.
