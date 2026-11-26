import UIKit
import WebKit
@preconcurrency import AVFoundation

/// Test keyboard: records through a hidden web view (getUserMedia), because keyboard
/// extensions are not allowed to record with AVAudioEngine. WebKit captures the audio
/// under the containing app's microphone permission and hands PCM back to Swift.
final class KeyboardViewController: UIInputViewController, WKUIDelegate {
    private let status = UILabel()
    private let mic = UIButton(type: .system)
    private let globe = UIButton(type: .system)
    private var web: WKWebView?
    private var store: AudioStore?
    private var meter: Timer?
    private var recording = false
    private var busy = false

    private static let page = """
    <!doctype html><html><body><script>
    let ctx, stream, node, src;
    function post(m) { webkit.messageHandlers.audio.postMessage(m); }
    async function start() {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
        ctx = new AudioContext();
        await ctx.resume();
        src = ctx.createMediaStreamSource(stream);
        node = ctx.createScriptProcessor(4096, 1, 1);
        node.onaudioprocess = e => {
          const f = e.inputBuffer.getChannelData(0);
          const bytes = new Uint8Array(f.buffer.slice(f.byteOffset, f.byteOffset + f.byteLength));
          let s = '';
          for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          post({ event: 'audio', rate: ctx.sampleRate, data: btoa(s) });
        };
        src.connect(node); node.connect(ctx.destination);
        post({ event: 'started', rate: ctx.sampleRate });
      } catch (err) { post({ event: 'error', message: String(err && (err.name + ': ' + err.message)) }); }
    }
    function stop() {
      try { node && node.disconnect(); src && src.disconnect(); stream && stream.getTracks().forEach(t => t.stop()); ctx && ctx.close(); } catch (e) {}
      post({ event: 'stopped' });
    }
    </script></body></html>
    """

    override func viewDidLoad() {
        super.viewDidLoad()
        view.heightAnchor.constraint(equalToConstant: 230).isActive = true

        status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .footnote)
        status.textAlignment = .center

        var config = UIButton.Configuration.filled()
        config.image = UIImage(systemName: "mic.fill")
        config.cornerStyle = .capsule
        config.contentInsets = .init(top: 18, leading: 28, bottom: 18, trailing: 28)
        mic.configuration = config
        mic.addTarget(self, action: #selector(micTapped), for: .touchUpInside)

        globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        let stack = UIStackView(arrangedSubviews: [status, mic])
        stack.axis = .vertical; stack.spacing = 14; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        globe.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack); view.addSubview(globe)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            globe.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            globe.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        loadRecorder()
        showIdle()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globe.isHidden = !needsInputModeSwitchKey
    }

    private func loadRecorder() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(MessageProxy(self), name: "audio")
        // Must be in the view hierarchy for capture to run; kept effectively invisible.
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        web.alpha = 0.02
        web.isUserInteractionEnabled = false
        web.uiDelegate = self
        view.addSubview(web)
        // An https base URL gives the page a secure context, which getUserMedia requires.
        web.loadHTMLString(Self.page, baseURL: URL(string: "https://d7n.local/"))
        self.web = web
    }

    // Grant the page's mic request; WebKit still enforces the containing app's permission.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.grant)
    }

    private func showIdle() {
        let permission: String
        switch AVAudioApplication.shared.recordPermission {
        case .granted: permission = "allowed"
        case .denied: permission = "denied"
        default: permission = "not asked"
        }
        status.text = "Full Access: \(hasFullAccess ? "on" : "OFF"). Mic: \(permission).\nTap the mic, speak, tap again."
    }

    @objc private func micTapped() {
        guard !busy else { return }
        if recording {
            busy = true
            status.text = "Stopping…"
            web?.evaluateJavaScript("stop()")
        } else {
            store = AudioStore()
            status.text = "Starting web recorder…"
            web?.evaluateJavaScript("start()")
        }
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], let event = message["event"] as? String else { return }
        switch event {
        case "started":
            recording = true
            mic.configuration?.image = UIImage(systemName: "stop.fill")
            meter = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let store = self.store else { return }
                    self.status.text = String(format: "Recording in the keyboard (web view)… %.1fs\nLoudest level so far: %.3f", store.duration, store.loudest)
                }
            }
        case "audio":
            guard let rate = message["rate"] as? Double, let encoded = message["data"] as? String,
                  let data = Data(base64Encoded: encoded), let store else { return }
            let frames = data.count / MemoryLayout<Float>.size
            guard frames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            data.withUnsafeBytes { raw in
                memcpy(buffer.floatChannelData![0], raw.baseAddress!, frames * MemoryLayout<Float>.size)
            }
            store.append(buffer)
        case "error":
            store = nil; busy = false
            status.text = "BLOCKED in web recorder: \(message["message"] as? String ?? "unknown error")"
        case "stopped":
            finish()
        default: break
        }
    }

    private func finish() {
        meter?.invalidate(); meter = nil
        recording = false
        mic.configuration?.image = UIImage(systemName: "mic.fill")
        guard let store else { busy = false; return }
        self.store = nil
        let loudest = store.loudest, seconds = store.duration
        let buffers = store.take()
        guard !buffers.isEmpty else { busy = false; status.text = "Recorder started but no audio arrived."; return }
        if loudest == 0 { busy = false; status.text = String(format: "Recorded %.1fs but it was pure silence: iOS is muting the keyboard's mic.", seconds); return }
        status.text = String(format: "Got real audio (%.1fs, level %.3f). Transcribing…", seconds, loudest)
        Task { @MainActor in
            defer { busy = false }
            do {
                let text = try await D7NSpeech.transcribe(buffers)
                if text.isEmpty { status.text = "Audio worked, but the transcript was empty. " + (await D7NSpeech.modelStatus()) }
                else { textDocumentProxy.insertText(text); status.text = "WORKS: recorded and typed \(text.count) characters, no app switch." }
            } catch {
                let e = error as NSError
                status.text = "Audio worked, transcription failed: \(e.localizedDescription) [\(e.domain) \(e.code)]. " + (await D7NSpeech.modelStatus())
            }
        }
    }
}

/// Avoids a retain cycle between WKUserContentController and the keyboard.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: KeyboardViewController?
    init(_ target: KeyboardViewController) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.received(message.body) }
    }
}
