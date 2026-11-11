import AVFoundation
import Foundation
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
                } else if error != nil {
                    done = true
                    cont.resume(throwing: Failure.nothingHeard)
                }
            }
        }
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
