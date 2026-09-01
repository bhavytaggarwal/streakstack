//
//  MCQTestView.swift
//  PrepPulse
//
//  Mode A: a five-question objective set, delivered as a swipeable deck and
//  closed out with a summary where any question can be flagged as wrong or
//  ambiguous. Flags are logged to SwiftData and replayed to the generator.
//

import SwiftData
import SwiftUI

struct MCQTestView: View {

    @StateObject private var viewModel: MCQViewModel
    @ObservedObject private var streaks: StreakStore
    @Environment(\.dismiss) private var dismiss

    /// The answer whose correction sheet is open. `nil` means no sheet.
    @State private var flagging: MCQAnswer?

    init(streaks: StreakStore,
         logs: FeedbackLogStore,
         modelContainer: ModelContainer? = nil,
         engine: GeminiEngine? = nil) {
        self.streaks = streaks
        _viewModel = StateObject(wrappedValue: MCQViewModel(engine: engine,
                                                            modelContainer: modelContainer,
                                                            streaks: streaks,
                                                            logs: logs))
    }

    var body: some View {
        ZStack {
            Pastel.canvas.ignoresSafeArea()

            switch viewModel.phase {
            case .idle, .loading:
                loading
            case .playing:
                deck
            case .finished:
                results
            }

            if let error = viewModel.errorMessage {
                VStack {
                    Spacer()
                    ErrorBanner(message: error,
                                onRetry: viewModel.load,
                                onDismiss: { viewModel.errorMessage = nil })
                        .padding(.bottom, 20)
                }
            }
        }
        .navigationTitle("Rapid MCQ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { StreakPill(streaks: streaks) }
        }
        .toolbarBackground(Pastel.canvas, for: .navigationBar)
        .animation(.snappy(duration: 0.3), value: viewModel.phase)
        .animation(.snappy(duration: 0.25), value: viewModel.errorMessage)
        .sheet(item: $flagging) { answer in
            MCQCorrectionSheet(
                answer: answer,
                existingCorrection: viewModel.existingCorrection(for: answer),
                onSubmit: { correction in
                    viewModel.submitCorrection(correction, for: answer)
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task { viewModel.loadIfNeeded() }
        .onDisappear { viewModel.cancel() }
    }

    // MARK: Loading

    private var loading: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Pastel.lavenderSoft).frame(width: 86, height: 86)
                Image(systemName: "sparkles")
                    .font(.pp(size: 30, .semibold))
                    .foregroundStyle(Pastel.lavender)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
            Text("Writing five fresh questions")
                .font(.pp(.headline, .semibold))
                .foregroundStyle(Pastel.ink)
            Text("Gemini returns them as strict JSON, so they land in the deck already structured.")
                .font(.pp(.footnote))
                .foregroundStyle(Pastel.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 42)
        }
    }

    // MARK: Card deck

    private var deck: some View {
        VStack(spacing: 14) {
            progressRow

            Spacer(minLength: 0)

            ZStack {
                // Two cards peeking behind the top one give the deck depth.
                ForEach(Array(viewModel.questions.enumerated().reversed()), id: \.element.id) { offset, question in
                    let depth = offset - viewModel.index
                    if depth >= 0 && depth <= 2 {
                        MCQCardView(
                            question: question,
                            selection: depth == 0 ? viewModel.selection : nil,
                            isInteractive: depth == 0,
                            onSelect: viewModel.choose,
                            onAdvance: viewModel.advance,
                            isLast: viewModel.isLastQuestion
                        )
                        .scaleEffect(1 - CGFloat(depth) * 0.045)
                        .offset(y: CGFloat(depth) * 14)
                        .opacity(depth == 0 ? 1 : 0.55)
                        .zIndex(Double(10 - depth))
                        .allowsHitTesting(depth == 0)
                    }
                }
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.bottom, 24)
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ForEach(0..<viewModel.questions.count, id: \.self) { position in
                Capsule()
                    .fill(position < viewModel.answers.count
                          ? (viewModel.answers[position].isCorrect ? Pastel.mint : Pastel.blush)
                          : position == viewModel.index ? Pastel.lavender : Pastel.hairline)
                    .frame(height: 6)
            }
        }
        .padding(.horizontal, 22)
        .animation(.snappy, value: viewModel.answers.count)
    }

    // MARK: Results

    private var results: some View {
        ScrollView {
            VStack(spacing: 18) {
                scoreRing

                VStack(spacing: 10) {
                    ForEach(viewModel.answers) { answer in
                        MCQResultCard(
                            answer: answer,
                            isFlagged: viewModel.isFlagged(answer),
                            onFlag: { flagging = answer }
                        )
                    }
                }

                Text("Something wrong with a question? Tap its flag — the correction goes to the generator so it stops making that mistake.")
                    .font(.pp(.caption))
                    .foregroundStyle(Pastel.inkSoft)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)

                HStack(spacing: 12) {
                    Button("New set") { viewModel.restart() }
                        .buttonStyle(PastelButtonStyle(fill: Pastel.lavender))
                    Button("Done") { dismiss() }
                        .buttonStyle(PastelButtonStyle(fill: Pastel.cardAlt))
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
    }

    private var scoreRing: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Pastel.hairline, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(viewModel.correctCount) / 5)
                    .stroke(Pastel.dreamy, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.7, dampingFraction: 0.7),
                               value: viewModel.correctCount)
                VStack(spacing: -2) {
                    Text("\(viewModel.correctCount)")
                        .font(.pp(size: 40, .heavy))
                        .foregroundStyle(Pastel.ink)
                    Text("of 5")
                        .font(.pp(.caption, .semibold))
                        .foregroundStyle(Pastel.inkSoft)
                }
            }
            .frame(width: 130, height: 130)

            Text(verdict)
                .font(.pp(.headline, .semibold))
                .foregroundStyle(Pastel.ink)
        }
        .padding(.top, 12)
    }

    private var verdict: String {
        switch viewModel.correctCount {
        case 5: return "Clean sweep. Go do the live interview."
        case 4: return "Strong. One slip to review."
        case 3: return "Solid base, gaps worth closing."
        default: return "Worth another pass — read the explanations."
        }
    }
}

// MARK: - Preview

#Preview("MCQ") {
    let container = try! ModelContainer(
        for: FeedbackLog.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return NavigationStack {
        MCQTestView(streaks: StreakStore(),
                    logs: FeedbackLogStore(context: ModelContext(container)),
                    engine: MockGeminiEngine())
    }
    .modelContainer(container)
}
