import SwiftUI
import AVFoundation

@main
struct TestApp: App {
    var body: some Scene { WindowGroup { SetupView() } }
}

struct SetupView: View {
    @State private var mic = "Not asked yet"
    @State private var model = "Checking…"
    @State private var busy = false
    @State private var sample = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("1. Microphone") {
                    LabeledContent("Permission", value: mic)
                    Button("Allow microphone") {
                        Task { mic = await AVAudioApplication.requestRecordPermission() ? "Allowed" : "Denied, change it in Settings" }
                    }
                }
                Section("2. Speech model") {
                    Text(model).font(.callout)
                    Button(busy ? "Downloading…" : "Download model") {
                        busy = true
                        Task {
                            do { try await D7NSpeech.prepare() } catch { model = "Failed: \(error.localizedDescription)" }
                            model = await D7NSpeech.modelStatus(); busy = false
                        }
                    }.disabled(busy)
                }
                Section("3. Turn on the keyboard") {
                    Text("Settings → General → Keyboard → Keyboards → Add New Keyboard → d7n. Then tap d7n and turn on Allow Full Access.")
                        .font(.callout)
                    Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                }
                Section("4. Test") {
                    Text("Switch to the d7n keyboard with the globe key, tap the mic, speak, tap again. Then try the same in Notes or Messages.")
                        .font(.callout)
                    TextField("Type or dictate here", text: $sample, axis: .vertical)
                }
            }
            .navigationTitle("d7n keyboard test")
            .task {
                switch AVAudioApplication.shared.recordPermission {
                case .granted: mic = "Allowed"
                case .denied: mic = "Denied, change it in Settings"
                default: mic = "Not asked yet"
                }
                model = await D7NSpeech.modelStatus()
            }
        }
    }
}
