//
//  SpeechSynthesizerService.swift
//  PrepPulse
//
//  Optional read-aloud for the interviewer's questions. Input stays on the
//  native keyboard's dictation key, so this is output-only — no mic session,
//  no speech-recognition entitlement needed at runtime.
//

import AVFoundation
import Combine
import Foundation

@MainActor
final class SpeechSynthesizerService: NSObject, ObservableObject {

    @Published private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var didConfigureSession = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Playback

    func speak(_ text: String) {
        let cleaned = Self.spokenForm(of: text)
        guard !cleaned.isEmpty else { return }

        stop()
        activateSession()

        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = Self.preferredVoice()
        // Marginally slower than default: interview questions land better when
        // they aren't rushed, and it gives the listener time to start thinking.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.96
        utterance.pitchMultiplier = 1.0
        utterance.postUtteranceDelay = 0.1
        utterance.preUtteranceDelay = 0.05

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    func toggle(_ text: String) {
        isSpeaking ? stop() : speak(text)
    }

    // MARK: - Audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            if !didConfigureSession {
                // `.duckOthers` keeps background music audible but quiet while
                // the interviewer speaks, which is what people expect on a walk.
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                didConfigureSession = true
            }
            try session.setActive(true, options: [])
        } catch {
            #if DEBUG
            print("[PrepPulse] Audio session activation failed: \(error.localizedDescription)")
            #endif
        }
    }

    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            #if DEBUG
            print("[PrepPulse] Audio session deactivation failed: \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Helpers

    /// Prefers a premium/enhanced US English voice when the user has downloaded
    /// one (Settings → Accessibility → Spoken Content → Voices).
    private static func preferredVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-US") }

        if let premium = english.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = english.first(where: { $0.quality == .enhanced }) { return enhanced }
        return AVSpeechSynthesisVoice(language: "en-US") ?? english.first
    }

    /// Strips leftover punctuation that a synthesiser would either read aloud
    /// or stumble over.
    private static func spokenForm(of text: String) -> String {
        text
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "—", with: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechSynthesizerService: AVSpeechSynthesizerDelegate {

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.deactivateSession()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.deactivateSession()
        }
    }
}
