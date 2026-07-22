// Container app — M1 placeholder: enable-keyboard onboarding. Settings + Learn = M3.
import SwiftUI

@main
struct VietTelexApp: App {
    var body: some Scene {
        WindowGroup { OnboardingView() }
    }
}

struct OnboardingView: View {
    var body: some View {
        VStack(spacing: 22) {
            Text("⌨️").font(.system(size: 64))
            Text("VietTelex").font(.largeTitle.bold())
            Text("Bộ gõ tiếng Việt Telex — nhanh, sạch, không cần Full Access, không mạng.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Label("Mở **Cài đặt → Cài đặt chung → Bàn phím → Bàn phím**", systemImage: "1.circle.fill")
                Label("Chọn **Thêm bàn phím mới… → Tiếng Việt (VietTelex)**", systemImage: "2.circle.fill")
                Label("Khi gõ, bấm 🌐 để chuyển sang VietTelex", systemImage: "3.circle.fill")
            }
            .padding()
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("Mở Cài đặt").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(28)
    }
}
