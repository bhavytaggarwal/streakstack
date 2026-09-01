//
//  Views.swift
//  PrepPulse
//
//  Pastel design system, HomeView, DescriptiveInterviewView and Settings.
//  The MCQ screens live in MCQTestView.swift / MCQCardView.swift.
//

import SwiftData
import SwiftUI
import UIKit

// MARK: - Design system

extension UIColor {
    fileprivate convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Color {
    /// One token, two values — the pastels stay soft in light mode and drop to
    /// muted, low-chroma versions in dark rather than glowing.
    fileprivate static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

enum Pastel {
    // Accents
    static let lavender = Color.adaptive(0xCDC1F5, 0x6E5FA8)
    static let lavenderSoft = Color.adaptive(0xEDE7FE, 0x2E2842)
    static let mint = Color.adaptive(0xB9E7D3, 0x3F7A63)
    static let mintSoft = Color.adaptive(0xE2F6EE, 0x1F3A31)
    static let peach = Color.adaptive(0xFFCDB2, 0x9A6B4F)
    static let peachSoft = Color.adaptive(0xFFEBDF, 0x3B2C24)
    static let butter = Color.adaptive(0xFFE5A8, 0x8A7238)
    static let sky = Color.adaptive(0xBFDDF7, 0x3E627E)
    static let blush = Color.adaptive(0xFFC2CE, 0x8E4A57)
    static let blushSoft = Color.adaptive(0xFFE6EA, 0x3B242A)

    // Surfaces
    static let canvas = Color.adaptive(0xFBF8F6, 0x14131A)
    static let card = Color.adaptive(0xFFFFFF, 0x1E1D26)
    static let cardAlt = Color.adaptive(0xF4F1FB, 0x252430)
    static let hairline = Color.adaptive(0xE9E4EF, 0x2E2C3A)

    // Text
    static let ink = Color.adaptive(0x2C2838, 0xF2EFF7)
    static let inkSoft = Color.adaptive(0x6C6580, 0xA9A2BC)

    static let flame = LinearGradient(colors: [Color.adaptive(0xFFD9A0, 0xC79A55),
                                               Color.adaptive(0xFFAE9B, 0xC77A6A)],
                                      startPoint: .top, endPoint: .bottom)
    static let dreamy = LinearGradient(colors: [lavender, sky],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Font {
    /// Everything in PrepPulse is SF Rounded.
    static func pp(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
    static func pp(size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// Soft, rounded card surface used everywhere.
struct SoftCard: ViewModifier {
    var fill: Color = Pastel.card
    var radius: CGFloat = 26
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(fill, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Pastel.hairline, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 14, y: 6)
    }
}

extension View {
    func softCard(fill: Color = Pastel.card,
                  radius: CGFloat = 26,
                  padding: CGFloat = 18) -> some View {
        modifier(SoftCard(fill: fill, radius: radius, padding: padding))
    }
}

// MARK: - Shared components

/// Minimalist streak marker for the navigation bar.
struct StreakPill: View {
    @ObservedObject var streaks: StreakStore
    @State private var scale: CGFloat = 1

    private var count: Int { streaks.displayedStreak() }
    private var lit: Bool { count > 0 }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill")
                .font(.pp(size: 13, .bold))
                .foregroundStyle(lit ? AnyShapeStyle(Pastel.flame) : AnyShapeStyle(Pastel.inkSoft))
                .symbolEffect(.bounce, value: streaks.pulse)
            Text("\(count)")
                .font(.pp(size: 15, .heavy))
                .foregroundStyle(lit ? Pastel.ink : Pastel.inkSoft)
                .contentTransition(.numericText(value: Double(count)))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(lit ? Pastel.peachSoft : Pastel.cardAlt, in: .capsule)
        .scaleEffect(scale)
        .onChange(of: streaks.pulse) { _, _ in bounce() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) day streak")
    }

    private func bounce() {
        withAnimation(.spring(response: 0.26, dampingFraction: 0.45)) { scale = 1.3 }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6).delay(0.16)) { scale = 1 }
    }
}

/// 1-to-5 score as pastel stars.
struct PastelStars: View {
    let score: Int
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { position in
                Image(systemName: position <= score ? "star.fill" : "star")
                    .font(.pp(size: size, .semibold))
                    .foregroundStyle(position <= score
                                     ? AnyShapeStyle(Pastel.flame)
                                     : AnyShapeStyle(Pastel.hairline))
                    .scaleEffect(position <= score ? 1 : 0.9)
                    .animation(.spring(response: 0.35, dampingFraction: 0.6)
                        .delay(Double(position) * 0.05), value: score)
            }
            Text("\(score)/5")
                .font(.pp(size: size - 2, .bold))
                .foregroundStyle(Pastel.inkSoft)
                .fixedSize()
                .padding(.leading, 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scored \(score) out of 5")
    }
}

/// "Did the AI grade that fairly?" — the tap is persisted as a `FeedbackLog`
/// by the view model, which owns the surrounding context.
struct MetaFeedbackToggle: View {
    let rating: MetaRating?
    let onRate: (MetaRating) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Fair evaluation?")
                .font(.pp(size: 11, .medium))
                .foregroundStyle(Pastel.inkSoft)

            button(.good, symbol: "hand.thumbsup", tint: Pastel.mint)
            button(.bad, symbol: "hand.thumbsdown", tint: Pastel.blush)
        }
        .animation(.snappy(duration: 0.2), value: rating)
    }

    private func button(_ value: MetaRating, symbol: String, tint: Color) -> some View {
        let active = rating == value
        return Button {
            onRate(value)
        } label: {
            Image(systemName: active ? "\(symbol).fill" : symbol)
                .font(.pp(size: 11, .semibold))
                .foregroundStyle(active ? Pastel.ink : Pastel.inkSoft)
                .frame(width: 26, height: 22)
                .background(active ? tint : Pastel.cardAlt, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value == .good ? "Rate this evaluation good" : "Rate this evaluation bad")
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

struct ThinkingDots: View {
    var label: String = "Thinking…"
    @State private var animating = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Pastel.lavender)
                        .frame(width: 7, height: 7)
                        .opacity(animating ? 1 : 0.3)
                        .scaleEffect(animating ? 1 : 0.7)
                        .animation(.easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.16), value: animating)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Pastel.card, in: .rect(cornerRadius: 20, style: .continuous))

            Text(label)
                .font(.pp(.caption))
                .foregroundStyle(Pastel.inkSoft)
            Spacer(minLength: 0)
        }
        .onAppear { animating = true }
        .accessibilityLabel(label)
    }
}

struct ErrorBanner: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundStyle(Pastel.peach)
            Text(message)
                .font(.pp(.footnote))
                .foregroundStyle(Pastel.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Retry", action: onRetry)
                .font(.pp(.footnote, .semibold))
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.pp(size: 11, .bold))
            }
            .foregroundStyle(Pastel.inkSoft)
        }
        .padding(14)
        .background(Pastel.blushSoft, in: .rect(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
    }
}

// MARK: - Home

struct HomeView: View {

    @EnvironmentObject private var streaks: StreakStore
    @EnvironmentObject private var logs: FeedbackLogStore
    @EnvironmentObject private var preferences: Preferences
    @Environment(\.modelContext) private var modelContext
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    streakCard

                    Text("Pick your practice")
                        .font(.pp(.headline, .semibold))
                        .foregroundStyle(Pastel.ink)
                        .padding(.top, 4)

                    NavigationLink {
                        MCQTestView(streaks: streaks,
                                    logs: logs,
                                    modelContainer: modelContext.container)
                    } label: {
                        ModeCard(
                            title: "Rapid MCQ",
                            subtitle: "Five objective questions on LLMs, RAG, agents and MCP. Swipe through, get instant explanations.",
                            symbol: "rectangle.on.rectangle.angled",
                            tint: Pastel.mintSoft,
                            accent: Pastel.mint,
                            badge: "5 questions · ~3 min"
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        DescriptiveInterviewView(streaks: streaks,
                                                 logs: logs,
                                                 preferences: preferences,
                                                 modelContainer: modelContext.container)
                    } label: {
                        ModeCard(
                            title: "Live interview",
                            subtitle: "A senior AI engineer asks, you answer out loud or by typing, and every answer is scored out of five.",
                            symbol: "waveform.and.person.filled",
                            tint: Pastel.lavenderSoft,
                            accent: Pastel.lavender,
                            badge: "Voice or text · open-ended"
                        )
                    }
                    .buttonStyle(.plain)

                    if logs.badCount > 0 || logs.ruleCount > 0 {
                        NavigationLink {
                            AdminDashboardView(store: logs)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "list.bullet.rectangle.portrait.fill")
                                    .foregroundStyle(Pastel.peach)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ledgerHeadline)
                                        .font(.pp(.footnote, .semibold))
                                        .foregroundStyle(Pastel.ink)
                                    Text("Sent to the model every call so it grades you the way you want")
                                        .font(.pp(.caption))
                                        .foregroundStyle(Pastel.inkSoft)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.pp(size: 12, .bold))
                                    .foregroundStyle(Pastel.inkSoft.opacity(0.6))
                            }
                            .softCard(fill: Pastel.peachSoft, radius: 18, padding: 14)
                        }
                        .buttonStyle(.plain)
                    }

                    if preferences.needsAPIKey {
                        Button { showSettings = true } label: {
                            Label("Add your Gemini API key to begin", systemImage: "key.fill")
                                .font(.pp(.footnote, .semibold))
                                .foregroundStyle(Pastel.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .softCard(fill: Pastel.butter.opacity(0.35), radius: 18, padding: 14)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 28)
            }
            .background(Pastel.canvas.ignoresSafeArea())
            .navigationTitle("PrepPulse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { StreakPill(streaks: streaks) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.pp(size: 15, .semibold))
                            .foregroundStyle(Pastel.inkSoft)
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .toolbarBackground(Pastel.canvas, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                SettingsSheet(streaks: streaks, logs: logs, preferences: preferences)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onChange(of: showSettings) { _, showing in
                if !showing { preferences.refreshKeyState() }
            }
            .task { preferences.refreshKeyState() }
        }
        .tint(Pastel.lavender)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.pp(.subheadline, .medium))
                .foregroundStyle(Pastel.inkSoft)
            Text("AI Engineer prep")
                .font(.pp(.largeTitle, .bold))
                .foregroundStyle(Pastel.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    /// "4 rules · 2 flagged" — whichever halves actually exist.
    private var ledgerHeadline: String {
        var parts: [String] = []
        if logs.ruleCount > 0 {
            parts.append("\(logs.ruleCount) rule\(logs.ruleCount == 1 ? "" : "s")")
        }
        if logs.badCount > 0 {
            parts.append("\(logs.badCount) flagged")
        }
        return parts.joined(separator: " · ") + " in the correction ledger"
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 0..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(streaks.displayedStreak())")
                    .font(.pp(size: 40, .heavy))
                    .foregroundStyle(streaks.displayedStreak() > 0
                                     ? AnyShapeStyle(Pastel.flame)
                                     : AnyShapeStyle(Pastel.inkSoft))
                    .contentTransition(.numericText(value: Double(streaks.displayedStreak())))
                Text("day streak")
                    .font(.pp(.subheadline, .semibold))
                    .foregroundStyle(Pastel.inkSoft)
                Spacer()
                if streaks.hasPracticedToday() {
                    Label("Done today", systemImage: "checkmark.circle.fill")
                        .font(.pp(size: 11, .semibold))
                        .foregroundStyle(Pastel.ink)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Pastel.mintSoft, in: .capsule)
                }
            }

            HStack(spacing: 6) {
                ForEach(Array(streaks.weekStrip().enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 4) {
                        Text(Self.weekdayLetter.string(from: day.date))
                            .font(.pp(size: 9, .semibold))
                            .foregroundStyle(Pastel.inkSoft.opacity(0.7))
                        Capsule()
                            .fill(day.practiced ? AnyShapeStyle(Pastel.flame)
                                                : AnyShapeStyle(Pastel.hairline))
                            .frame(height: 6)
                            .overlay(
                                Capsule().strokeBorder(
                                    Pastel.lavender.opacity(index == 6 ? 0.8 : 0), lineWidth: 1.5)
                            )
                    }
                }
            }

            Text(streaks.isAtRisk()
                 ? "One answer today keeps the run alive."
                 : streaks.hasPracticedToday()
                   ? "Best run: \(streaks.longest) days · \(streaks.totalDaysPracticed) days practised"
                   : "Answer one question to start a streak.")
                .font(.pp(.caption))
                .foregroundStyle(Pastel.inkSoft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .softCard(fill: Pastel.card, radius: 26, padding: 18)
        .animation(.snappy, value: streaks.displayedStreak())
    }

    private static let weekdayLetter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return f
    }()
}

private struct ModeCard: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let accent: Color
    let badge: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(accent.opacity(0.35))
                    .frame(width: 50, height: 50)
                Image(systemName: symbol)
                    .font(.pp(size: 21, .semibold))
                    .foregroundStyle(Pastel.ink)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.pp(.title3, .bold))
                    .foregroundStyle(Pastel.ink)
                Text(subtitle)
                    .font(.pp(.footnote))
                    .foregroundStyle(Pastel.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text(badge)
                    .font(.pp(size: 10, .semibold))
                    .foregroundStyle(Pastel.inkSoft)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Pastel.card.opacity(0.8), in: .capsule)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.pp(size: 13, .bold))
                .foregroundStyle(Pastel.inkSoft.opacity(0.6))
                .padding(.top, 16)
        }
        .softCard(fill: tint, radius: 26, padding: 18)
    }
}


struct PastelButtonStyle: ButtonStyle {
    var fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.pp(.subheadline, .semibold))
            .foregroundStyle(Pastel.ink)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(fill, in: .capsule)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Mode B: descriptive interview

struct DescriptiveInterviewView: View {

    @StateObject private var viewModel: DescriptiveInterviewViewModel
    @ObservedObject private var streaks: StreakStore
    @ObservedObject private var preferences: Preferences
    @FocusState private var inputFocused: Bool

    init(streaks: StreakStore,
         logs: FeedbackLogStore,
         preferences: Preferences,
         modelContainer: ModelContainer? = nil,
         engine: GeminiEngine? = nil) {
        self.streaks = streaks
        self.preferences = preferences
        _viewModel = StateObject(wrappedValue: DescriptiveInterviewViewModel(
            engine: engine,
            modelContainer: modelContainer,
            streaks: streaks,
            logs: logs,
            preferences: preferences
        ))
    }

    var body: some View {
        ZStack {
            Pastel.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                if let average = viewModel.averageScore {
                    scoreSummary(average)
                }

                transcript

                if let error = viewModel.errorMessage {
                    ErrorBanner(message: error,
                                onRetry: viewModel.retry,
                                onDismiss: { viewModel.errorMessage = nil })
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                inputBar
            }
        }
        .navigationTitle("Live interview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    preferences.isVoiceEnabled.toggle()
                    if preferences.isVoiceEnabled {
                        viewModel.speakLatestQuestion()
                    } else {
                        viewModel.speech.stop()
                    }
                } label: {
                    Image(systemName: preferences.isVoiceEnabled
                          ? (viewModel.speech.isSpeaking ? "speaker.wave.3.fill" : "speaker.wave.2.fill")
                          : "speaker.slash.fill")
                        .font(.pp(size: 15, .semibold))
                        .foregroundStyle(preferences.isVoiceEnabled ? Pastel.lavender : Pastel.inkSoft)
                        .symbolEffect(.variableColor.iterative, isActive: viewModel.speech.isSpeaking)
                }
                .accessibilityLabel(preferences.isVoiceEnabled
                                    ? "Turn off spoken questions" : "Speak questions out loud")
            }
            ToolbarItem(placement: .topBarTrailing) { StreakPill(streaks: streaks) }
        }
        .toolbarBackground(Pastel.canvas, for: .navigationBar)
        .animation(.snappy(duration: 0.25), value: viewModel.errorMessage)
        .task { viewModel.startIfNeeded() }
        .onDisappear { viewModel.speech.stop() }
    }

    private func scoreSummary(_ average: Double) -> some View {
        HStack(spacing: 10) {
            Text("Average")
                .font(.pp(size: 11, .semibold))
                .foregroundStyle(Pastel.inkSoft)
            PastelStars(score: Int(average.rounded()), size: 12)
            Spacer()
            Text("\(viewModel.answeredCount) answered")
                .font(.pp(size: 11, .medium))
                .foregroundStyle(Pastel.inkSoft)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Pastel.cardAlt)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.entries) { entry in
                        switch entry {
                        case .candidate(let message):
                            CandidateBubble(message: message)
                                .id(entry.id)
                        case .interviewer(let turn):
                            InterviewerCard(turn: turn,
                                            rating: viewModel.rating(for: turn),
                                            onRate: { viewModel.rate($0, for: turn) })
                                .id(entry.id)
                        }
                    }

                    if viewModel.isThinking {
                        ThinkingDots(label: viewModel.hasStarted
                                     ? "Grading your answer…" : "Preparing your first question…")
                    }

                    Color.clear.frame(height: 6).id("bottom")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .animation(.snappy(duration: 0.3), value: viewModel.entries.count)
            .animation(.snappy(duration: 0.3), value: viewModel.isThinking)
            .onChange(of: viewModel.entries.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: viewModel.isThinking) { _, _ in scrollToBottom(proxy) }
            .onChange(of: inputFocused) { _, focused in if focused { scrollToBottom(proxy) } }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    private var inputBar: some View {
        VStack(spacing: 6) {
            if inputFocused && viewModel.draft.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "mic.fill").font(.pp(size: 9))
                    Text("Tap the mic on your keyboard to answer out loud")
                }
                .font(.pp(size: 11))
                .foregroundStyle(Pastel.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .transition(.opacity)
            }

            HStack(alignment: .bottom, spacing: 10) {
                // Plain multi-line TextField: the system keyboard's dictation key
                // streams into it, so no custom speech recogniser is needed.
                TextField("Answer the question…", text: $viewModel.draft, axis: .vertical)
                    .font(.pp(.body))
                    .lineLimit(1...6)
                    .textInputAutocapitalization(.sentences)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Pastel.card, in: .rect(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(inputFocused ? Pastel.lavender : Pastel.hairline,
                                          lineWidth: 1.5)
                    )
                    .accessibilityLabel("Your answer")

                Button {
                    if viewModel.isThinking { viewModel.stopGenerating() } else { viewModel.send() }
                } label: {
                    Image(systemName: viewModel.isThinking ? "stop.fill" : "arrow.up")
                        .font(.pp(size: 16, .bold))
                        .foregroundStyle(Pastel.ink)
                        .frame(width: 42, height: 42)
                        .background(
                            Circle().fill(viewModel.canSend || viewModel.isThinking
                                          ? Pastel.lavender : Pastel.hairline)
                        )
                }
                .disabled(!viewModel.canSend && !viewModel.isThinking)
                .animation(.snappy(duration: 0.2), value: viewModel.canSend)
                .accessibilityLabel(viewModel.isThinking ? "Stop" : "Send answer")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .padding(.top, 4)
        }
        .animation(.snappy(duration: 0.2), value: inputFocused)
        .background(Pastel.cardAlt)
    }
}

private struct CandidateBubble: View {
    let message: Message

    var body: some View {
        HStack {
            Spacer(minLength: 46)
            Text(message.text)
                .font(.pp(.body))
                .foregroundStyle(Pastel.ink)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(Pastel.lavenderSoft,
                            in: UnevenRoundedRectangle(topLeadingRadius: 20,
                                                       bottomLeadingRadius: 20,
                                                       bottomTrailingRadius: 6,
                                                       topTrailingRadius: 20,
                                                       style: .continuous))
                .textSelection(.enabled)
        }
    }
}

private struct InterviewerCard: View {
    let turn: InterviewerTurn
    let rating: MetaRating?
    let onRate: (MetaRating) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let score = turn.score {
                PastelStars(score: score)
            }

            if let critique = turn.feedback, !critique.isEmpty {
                Text(critique)
                    .font(.pp(.footnote))
                    .foregroundStyle(Pastel.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(turn.question)
                .font(.pp(.body, .medium))
                .foregroundStyle(Pastel.ink)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            // The opening question isn't an evaluation, so there's nothing to rate.
            if turn.score != nil {
                Divider().overlay(Pastel.hairline)
                MetaFeedbackToggle(rating: rating, onRate: onRate)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Pastel.card,
                    in: UnevenRoundedRectangle(topLeadingRadius: 20,
                                               bottomLeadingRadius: 6,
                                               bottomTrailingRadius: 20,
                                               topTrailingRadius: 20,
                                               style: .continuous))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 6,
                                   bottomTrailingRadius: 20, topTrailingRadius: 20,
                                   style: .continuous)
                .strokeBorder(Pastel.hairline, lineWidth: 1)
        )
        .padding(.trailing, 30)
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @ObservedObject var streaks: StreakStore
    @ObservedObject var logs: FeedbackLogStore
    @ObservedObject var preferences: Preferences

    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSecrets.userDefaultsKey) private var apiKey = ""
    @State private var confirmStreakReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("AIza…", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.pp(.body))
                } header: {
                    Text("Gemini API key")
                } footer: {
                    Text("Stored on this device and sent straight to Google's API. Get one at aistudio.google.com. For a shipping app, move this to the Keychain or proxy it through your own backend.")
                }

                Section("Voice") {
                    Toggle("Speak questions out loud", isOn: Binding(
                        get: { preferences.isVoiceEnabled },
                        set: { preferences.isVoiceEnabled = $0 }
                    ))
                }

                Section {
                    LabeledContent("Current streak", value: "\(streaks.displayedStreak()) days")
                    LabeledContent("Longest streak", value: "\(streaks.longest) days")
                    LabeledContent("Days practised", value: "\(streaks.totalDaysPracticed)")
                } header: {
                    Text("Progress")
                }

                Section {
                    LabeledContent("Evaluations rated", value: "\(logs.ratedCount)")
                    if let rate = logs.agreementRate {
                        LabeledContent("Rated fair", value: rate.formatted(.percent.precision(.fractionLength(0))))
                    }
                    NavigationLink {
                        AdminDashboardView(store: logs)
                    } label: {
                        LabeledContent("Correction ledger", value: "\(logs.badCount) flagged")
                    }
                } header: {
                    Text("Your rating of the AI")
                } footer: {
                    Text("Thumbs on each evaluation are stored in SwiftData. The five most recent unresolved \"Bad\" ratings are replayed to the model as a correction ledger on every call.")
                }

                Section {
                    Button("Reset streak", role: .destructive) { confirmStreakReset = true }
                    Button("Clear AI ratings", role: .destructive) { logs.reset() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        preferences.refreshKeyState()
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Reset your streak?",
                                isPresented: $confirmStreakReset,
                                titleVisibility: .visible) {
                Button("Reset streak", role: .destructive) { streaks.reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears your current and longest streak. It can't be undone.")
            }
        }
    }
}

// MARK: - Previews

#Preview("Home") {
    let container = try! ModelContainer(
        for: FeedbackLog.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return HomeView()
        .environmentObject(StreakStore())
        .environmentObject(Preferences())
        .environmentObject(FeedbackLogStore(context: ModelContext(container)))
        .modelContainer(container)
}

#Preview("Interview") {
    let container = try! ModelContainer(
        for: FeedbackLog.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return NavigationStack {
        DescriptiveInterviewView(streaks: StreakStore(),
                                 logs: FeedbackLogStore(context: ModelContext(container)),
                                 preferences: Preferences(),
                                 engine: MockGeminiEngine())
    }
    .modelContainer(container)
}
