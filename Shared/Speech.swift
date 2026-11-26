@preconcurrency import AVFoundation
import Speech

/// Copies microphone buffers out of the audio callback. Capped at 2 minutes.
final class AudioStore: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var seconds = 0.0
    private var peak: Float = 0

    func append(_ source: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        seconds += Double(source.frameLength) / source.format.sampleRate
        guard seconds <= 120, let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return }
        copy.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<src.count {
            guard let from = src[i].mData, let to = dst[i].mData else { return }
            memcpy(to, from, Int(src[i].mDataByteSize))
        }
        if let channel = source.floatChannelData?[0] {
            for f in 0..<Int(source.frameLength) { peak = max(peak, abs(channel[f])) }
        }
        buffers.append(copy)
    }

    /// Loudest sample so far. Stays 0 if iOS feeds the keyboard silence instead of real audio.
    var loudest: Float { lock.lock(); defer { lock.unlock() }; return peak }
    var duration: Double { lock.lock(); defer { lock.unlock() }; return seconds }

    func take() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { buffers.removeAll(); seconds = 0; peak = 0; lock.unlock() }
        return buffers
    }
}

enum D7NSpeech {
    static func locale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_AU"))
    }

    static func modelStatus() async -> String {
        guard SpeechTranscriber.isAvailable else { return "SpeechTranscriber is not available on this device." }
        guard let locale = await locale() else { return "No supported English model." }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        return "Model \(locale.identifier): \(status)"
    }

    static func prepare() async throws {
        guard SpeechTranscriber.isAvailable, let locale = await locale() else { throw NSError(domain: "d7n", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech model unavailable"]) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    static func transcribe(_ buffers: [AVAudioPCMBuffer]) async throws -> String {
        guard let source = buffers.first?.format, let locale = await locale() else { return "" }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: source, to: format) else {
            throw NSError(domain: "d7n", code: 2, userInfo: [NSLocalizedDescriptionKey: "No compatible audio format"])
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let results = Task { () throws -> String in
            var text = ""
            for try await result in transcriber.results { text += String(result.text.characters) }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            try await analyzer.start(inputSequence: stream)
            for buffer in buffers {
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / source.sampleRate)) + 256
                guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { break }
                var supplied = false
                var conversionError: NSError?
                _ = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    if supplied { inputStatus.pointee = .noDataNow; return nil }
                    supplied = true; inputStatus.pointee = .haveData; return buffer
                }
                if let conversionError { throw conversionError }
                if output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
            }
            continuation.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await results.value
        } catch {
            continuation.finish(); results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}
