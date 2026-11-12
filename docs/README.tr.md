# macOS için TOP75

Darmoshark TOP75’i doğrudan USB üzerinden yapılandıran açık kaynak macOS uygulaması.

**[DMG indir](https://github.com/kreativecenter/top75-macos/releases/latest/download/TOP75-macOS.dmg) · [İngilizce README](../README.md) · [Protokol notları](protocol.md)**

## Başlangıç

1. [**TOP75-macOS.dmg**](https://github.com/kreativecenter/top75-macos/releases/latest/download/TOP75-macOS.dmg) dosyasını aç ve **TOP75.app**’i **Uygulamalar** klasörüne sürükle. [ZIP paketi](https://github.com/kreativecenter/top75-macos/releases/latest/download/TOP75-macOS.zip) de mevcut.
2. TOP75’i veri taşıyan bir USB kablosuyla bağla. Mod anahtarını **OFF** konumuna getir ve klavye ekranında **USB** yazdığını kontrol et.
3. Kenar çubuğunda **USB bağlı** göründüğünde bir panel aç. Mevcut ayarı oku, değiştir ve klavyeye uygula.

**TOP75 → Ayarlar** (⌘,) menüsünden İngilizce, Türkçe veya sistem dilini seçebilirsin. **⌘F** ile kılavuzda ara ve ilgili paneli aç. USB kurulum adımları için kenar çubuğundaki **Bağlantı yardımı** düğmesini kullan.

## Ekran görüntüleri

**Aydınlatma**

![TOP75 aydınlatma panelinde klavye çizimi üzerinde mavi dalga efekti](assets/lighting.png)

**Tuşlar ve profiller**

![TOP75 tuş ve profil panelinde Fn + F12 için multimedya ataması okunmuş](assets/keys-profiles.png)

**Makro zaman çizelgesi ve GIF önizlemesi**

<table>
  <tr>
    <td width="49%"><img src="assets/macros.png" alt="Makro oynatılırken Command ve K tuşları vurgulanıyor"></td>
    <td width="51%"><img src="assets/display.png" alt="128 × 128 GIF önizlemesi, sığdırma ve ortadan kırpma seçenekleri"></td>
  </tr>
</table>

## Paneller

| Panel | İşlev |
| --- | --- |
| **Aydınlatma** | Canlı efekt önizlemesi, beş yerel ön ayar ve ayrı bir tuş rengi düzenleyicisi. Birden fazla tuşu seçip birlikte boya ve tek işlemde uygula. |
| **Tuşlar ve profiller** | Seçilen tuşun mevcut ataması otomatik okunur. Temel ve Fn katmanını düzenle, değişen tuşları çizimde gör ve üç cihaz profiline bu Mac’te ad ver. |
| **Makrolar** | Basma ve bırakma olaylarını düzenle, sırala ve sil. Makroyu klavye çiziminde bir tur oynat ve basılı tuşları gör. |
| **Ekran** | PNG, JPEG veya GIF sürükleyip bırak. 128 × 128 önizlemede oynat, sığdır veya ortadan kırp. Aktarım ilerlemesi panel değiştirince de görünür. |
| **Cihaz ayarları** | Tuş tepkisini, otomatik işletim sistemi algılamayı ve kablosuz uyku sürelerini yönet. JSON kaydını klavyeyle karşılaştır ve istediğin farkları geri yükle. |

Apple Silicon ve Intel için derlenen uygulama macOS 14 ve üstünü hedefler. DMG ve ZIP, aynı imzalı ve Apple noter onaylı uygulamayı içerir. Cihaz ayarları USB üzerinden yazılır ve uygulama TOP75 kimliği **957** olan modeli doğrular. Sabit görsel yükleme, toplu tuş rengi yazma ve seçmeli JSON geri yükleme fiziksel klavyede doğrulandı. GIF oynatma için fiziksel doğrulama bekleniyor. Geri yükleme için yedek ile klavyenin firmware sürümü eşleşmeli. Eski yedeklerde Fn atamaları, kaydın alındığı etkin profil için kullanılabilir. JSON kaydı makro içeriğini ve ekran görsellerini kapsamaz. Kablosuz yapılandırma, firmware güncelleme, müzik ve ekran eşleme ile fare olaylı makrolar henüz yok.

Xcode ve Swift 6 ile depoda `./scripts/build.sh` çalıştırarak dağıtım paketini oluşturabilirsin. Kaynak kodu [MIT lisansı](../LICENSE) ile yayımlanır.
