import AVFoundation
import Foundation
import PixlMemoryKit
import Speech

/// Turns a Mosaico's dictation clip into text with Apple's speech recognizer (the Speech
/// framework), on this Mac. On-device when the system supports it for the language.
@MainActor
enum Dictation {
    enum Failure: Error { case notAllowed, unavailable, nothingHeard }

    static func transcribe(_ samples: [Int16], rate: Double = 16000) async throws -> String {
        guard await authorized() else { throw Failure.notAllowed }
        guard let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              rec.isAvailable else { throw Failure.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }   // stays on this Mac
        request.addsPunctuation = true
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw Failure.unavailable
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let ch = buffer.floatChannelData![0]
        for (i, s) in samples.enumerated() { ch[i] = Float(s) / 32768 }
        request.append(buffer)
        request.endAudio()
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            rec.recognitionTask(with: request) { result, error in
                guard !done else { return }
                if let result, result.isFinal {
                    done = true
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    text.isEmpty ? cont.resume(throwing: Failure.nothingHeard) : cont.resume(returning: text)
                } else if let error {
                    done = true
                    Debug.log("dictation: recognizer said \(error.localizedDescription)")
                    cont.resume(throwing: Failure.nothingHeard)
                }
            }
        }
    }

    /// 16-bit mono WAV, for checking what the microphone picked up.
    static func saveWAV(_ samples: [Int16], to url: URL, rate: Int = 16000) {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        try? d.write(to: url)
    }

    static func authorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }
}
