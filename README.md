# SoundsSource

SoundsSource là ứng dụng macOS giúp bạn quản lý và điều chỉnh âm thanh riêng biệt cho từng ứng dụng (Per-App Audio Control).

macOS mặc định chỉ cho phép chỉnh âm lượng chung của toàn hệ thống. Nếu bạn muốn phát nhạc Spotify ra tai nghe, chuyển tiếng Discord sang loa ngoài, hoặc chỉnh EQ riêng cho từng app — SoundsSource được viết ra để giải quyết vấn đề đó.

App chạy nhẹ nhàng trên thanh Menu Bar, không cần cài đặt Virtual Audio Driver hay khởi động lại máy.

> **Yêu cầu hệ thống**: macOS 14.2 (Sonoma) trở lên. App sử dụng API Audio Process Tapping mới của Apple (chỉ có từ macOS 14.2).

---

## ⚡ Tính năng chính

- **Tách âm thanh theo ứng dụng**: Điều chỉnh độc lập cho từng app (Spotify, Chrome, Discord, Game...).
- **Điều hướng đầu ra (Audio Routing)**: Đẩy tiếng của từng app ra các thiết bị phát khác nhau (loa ngoài, tai nghe Bluetooth, DAC...).
- **Âm lượng & Mute riêng**: Thanh kéo âm lượng độc lập kèm nút tắt tiếng tức thì.
- **Parametric EQ 10 dải**: Điều chỉnh tần số từ 32 Hz đến 16 kHz trực tiếp trên đồ thị trực quan.
- **Quản lý Preset**: Lưu cấu hình âm lượng / EQ / Routing thành preset để chuyển đổi nhanh khi cần.
- **Lọc tiến trình thông minh**: Tự động nhận diện và gộp tiến trình con (Helper process của Chrome, Discord...) về ứng dụng chính, tự loại bỏ tiến trình hệ thống không liên quan.

---

## 🚀 Cài đặt

1. Tải file **SoundsSource.dmg** mới nhất tại [mục Releases](https://github.com/songoku-03/voice-macos/releases/latest).
2. Mở file `.dmg` và kéo `SoundsSource.app` vào thư mục **Applications**.

### Cấp quyền & Mở ứng dụng lần đầu

Vì ứng dụng được ký ad-hoc (chưa đăng ký tài khoản Apple Developer để notarize), macOS có thể chặn khi mở lần đầu:

- **Cách 1**: Click chuột phải vào `SoundsSource.app` trong thư mục Applications → Chọn **Open** → Bấm **Open** lần nữa.
- **Cách 2**: Mở Terminal và chạy lệnh bỏ quarantine:
  ```bash
  xattr -dr com.apple.quarantine /Applications/SoundsSource.app
  ```

> **Lưu ý**: Lần đầu khởi chạy, hãy chọn **Allow** khi macOS xin quyền ghi âm (System Audio Capture / Microphone) để ứng dụng có thể bắt luồng âm thanh.

### Cấp quyền Accessibility (Quyền hỗ trợ tiếp cận cho chế độ Khóa màn hình nghỉ mắt)

Nếu bạn sử dụng tính năng **Nghỉ mắt / Eye-rest timer**, ứng dụng cần quyền Accessibility để triển khai chế độ khóa bàn phím trong thời gian nghỉ.

- **Vị trí cài đặt bắt buộc**: File ứng dụng phải được đặt tại `~/Applications/SoundsSource.app` (phát triển) hoặc `/Applications/SoundsSource.app` (chính thức). **Không chạy ứng dụng từ thư mục `~/Documents`, `~/Desktop` hay `~/Downloads`** vì macOS TCC bảo vệ các thư mục này, khiến trình chọn ứng dụng của System Settings không thể tìm thấy file để cấp quyền.
- **Quyền theo định danh (Identity-based TCC grant)**: Quyền Accessibility được cấp theo **Bundle Identifier (`com.soundssource.app`) và Chứng thư ký (Designated Requirement)**. Việc di chuyển ứng dụng giữa `~/Applications` và `/Applications` không làm mất quyền đã cấp.
- **Đường dẫn cấp thủ công**: Mở **System Settings → Privacy & Security → Accessibility**, nhấn nút **`+`** và chọn file ứng dụng tại `~/Applications/SoundsSource.app` (hoặc `/Applications/SoundsSource.app`).
- **Lệnh khôi phục TCC**: Nếu cần reset lại trạng thái cấp quyền Accessibility cho ứng dụng, chạy lệnh Terminal:
  ```bash
  sudo tccutil reset Accessibility com.soundssource.app
  ```

---

## 💻 Hướng dẫn sử dụng

1. Bấm vào biểu tượng sóng âm trên thanh Menu Bar để mở bảng điều khiển.
2. Ứng dụng đang phát âm thanh sẽ xuất hiện trong danh sách (kèm chấm xanh trạng thái).
3. Bật công tắc ở cuối dòng app bạn muốn tùy chỉnh.
4. Mở rộng dòng điều khiển để truy cập các tính năng:
   - Thanh kéo **Volume** & nút **Mute**.
   - **Route to**: Chọn thiết bị phát mong muốn.
   - **Equalizer**: Bật EQ và kéo thả các điểm trên biểu đồ tần số.
5. Khi đã vừa ý, bấm **Save Preset** để lưu lại cho các lần sử dụng sau.

---

## 🛠 Tự build từ mã nguồn

Nếu muốn tự biên dịch hoặc đóng gói ứng dụng:

```bash
git clone https://github.com/songoku-03/voice-macos.git
cd voice-macos

# Build ứng dụng (kết quả tại build/SoundsSource.app)
./scripts/build_app.sh

# Đóng gói thành file cài đặt .dmg
./scripts/build_dmg.sh
```

**Yêu cầu:**
- macOS 14.2+
- Xcode 16 Command Line Tools (Swift 6)

---

## 🏗 Kiến trúc dự án

Code được chia thành các tầng rõ ràng:

```
SoundsSource (Entry point) ──► UI (SwiftUI) ──► Engine (AudioGraph/Presets) ──► Core (CoreAudio/ProcessTap)
```

- **Core**: Tầng làm việc trực tiếp với CoreAudio API để quét tiến trình, tạo Audio Process Tap và quản lý Ring Buffer.
- **Engine**: Quản lý đồ thị `AVAudioEngine`, gắn các node EQ 10-band, Mixer và xử lý lưu/tải Preset.
- **UI**: Giao diện SwiftUI (Popover Menu Bar, danh sách app, bộ chỉnh EQ Curve tương tác).
- **SoundsSource**: Điểm khởi chạy ứng dụng và quản lý Menu Bar StatusItem.

---

## 📄 Giấy phép

Mã nguồn dự án hiện chưa kèm giấy phép mã nguồn mở chính thức. Vui lòng liên hệ tác giả trước khi sử dụng lại code cho mục đích thương mại.

