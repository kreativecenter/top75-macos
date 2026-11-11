# macOS için TOP75

Darmoshark TOP75’i doğrudan USB üzerinden yapılandıran açık kaynak macOS uygulaması.

**[İndir](https://github.com/kreativecenter/top75-macos/releases) · [İngilizce README](../README.md) · [Protokol notları](protocol.md)**

## Başlangıç

1. Sürüm sayfasından **TOP75-macOS.zip** dosyasını indirip **TOP75.app**’i çıkar.
2. TOP75’i veri taşıyan bir USB kablosuyla bağla. Mod anahtarını **OFF** konumuna getir ve klavye ekranında **USB** yazdığını kontrol et.
3. Kenar çubuğunda **USB bağlı** göründüğünde bir panel aç. Mevcut ayarı oku, değiştir ve klavyeye uygula.

**TOP75 → Ayarlar** (⌘,) menüsünden İngilizce, Türkçe veya sistem dilini seçebilirsin. **⌘F** ile kılavuzda ara.

## Paneller

| Panel | İşlev |
| --- | --- |
| **Aydınlatma** | Renk, efekt, yön, parlaklık ve hız. Tuş başına RGB ve beş yerel ön ayar. |
| **Tuşlar ve profiller** | Klavye çiziminden tuş seç, temel veya Fn katmanına tuş, multimedya işlevi veya makro ata. Üç cihaz profili arasında geçiş yap. |
| **Makrolar** | Tuş olayları, bekleme süreleri ve tekrar sayısını düzenle. |
| **Ekran** | PNG ve JPEG için önizleme ve beş sabit görsel yuvası. En fazla 25 kareli GIF aktarımı. |
| **Cihaz ayarları** | Tuş tepki süresi, otomatik işletim sistemi algılama, kablosuz uyku süreleri ve JSON ayar kaydı. |

Apple Silicon ve Intel için derlenen ön sürüm macOS 14 ve üstünü hedefler. Cihaz ayarları USB üzerinden yazılır ve uygulama TOP75 kimliği **957** olan modeli doğrular. GIF oynatma fiziksel klavyede ayrıca test edilmelidir. JSON geri yükleme, kablosuz yapılandırma, firmware güncelleme, müzik ve ekran eşleme ile fare olaylı makrolar henüz yok.

Xcode ve Swift 6 ile depoda `./scripts/build.sh` çalıştırarak dağıtım paketini oluşturabilirsin. Kaynak kodu [MIT lisansı](../LICENSE) ile yayımlanır.
