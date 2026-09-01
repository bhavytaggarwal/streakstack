//
//  MCQCardView.swift
//  PrepPulse
//
//  The three MCQ card surfaces: the swipeable question card, the summary
//  result card with its flag button, and the correction sheet that flag opens.
//

import SwiftUI

// MARK: - Question card

/// One swipeable question card in the deck.
struct MCQCardView: View {
    let question: MCQQuestion
    let selection: Int?
    let isInteractive: Bool
    let onSelect: (Int) -> Void
    let onAdvance: () -> Void
    let isLast: Bool

    @State private var dragX: CGFloat = 0

    private var revealed: Bool { selection != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(question.topic.uppercased())
                .font(.pp(size: 10, .heavy))
                .foregroundStyle(Pastel.inkSoft)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Pastel.cardAlt, in: .capsule)

            Text(question.question)
                .font(.pp(.title3, .semibold))
                .foregroundStyle(Pastel.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index: index, option: option)
                }
            }

            if revealed {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selection == question.safeCorrectIndex ? "Correct" : "Not quite")
                        .font(.pp(.caption, .heavy))
                        .foregroundStyle(Pastel.ink)
                    Text(question.explanation)
                        .font(.pp(.footnote))
                        .foregroundStyle(Pastel.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(selection == question.safeCorrectIndex ? Pastel.mintSoft : Pastel.peachSoft,
                            in: .rect(cornerRadius: 16, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))

                Button(isLast ? "See results" : "Next question") { advance() }
                    .buttonStyle(PastelButtonStyle(fill: Pastel.lavender))
                    .frame(maxWidth: .infinity)

                Text("or swipe the card")
                    .font(.pp(size: 10, .medium))
                    .foregroundStyle(Pastel.inkSoft.opacity(0.8))
                    .frame(maxWidth: .infinity)
            }
        }
        // A floor on the height keeps the cards behind peeking out, whatever
        // the question length.
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
        .softCard(radius: 28, padding: 20)
        .offset(x: dragX)
        .rotationEffect(.degrees(Double(dragX / 24)), anchor: .bottom)
        .gesture(swipe)
        .animation(.snappy(duration: 0.28), value: revealed)
        .accessibilityHint(revealed ? "Swipe left or right for the next question" : "")
    }

    private func optionRow(index: Int, option: String) -> some View {
        let isCorrect = index == question.safeCorrectIndex
        let isPicked = selection == index
        let fill: Color = {
            guard revealed else { return Pastel.cardAlt }
            if isCorrect { return Pastel.mintSoft }
            return isPicked ? Pastel.blushSoft : Pastel.cardAlt
        }()

        return Button {
            onSelect(index)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(revealed && (isCorrect || isPicked) ? Pastel.card : Pastel.card.opacity(0.7))
                        .frame(width: 24, height: 24)
                    if revealed && isCorrect {
                        Image(systemName: "checkmark").font(.pp(size: 11, .bold))
                            .foregroundStyle(Pastel.ink)
                    } else if revealed && isPicked {
                        Image(systemName: "xmark").font(.pp(size: 11, .bold))
                            .foregroundStyle(Pastel.ink)
                    } else {
                        Text(String(UnicodeScalar(65 + index)!))
                            .font(.pp(size: 11, .heavy))
                            .foregroundStyle(Pastel.inkSoft)
                    }
                }
                Text(option)
                    .font(.pp(.subheadline))
                    .foregroundStyle(Pastel.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(fill, in: .rect(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(revealed || !isInteractive)
        .animation(.snappy(duration: 0.25), value: selection)
    }

    private var swipe: some Gesture {
        DragGesture()
            .onChanged { value in
                guard revealed else { return }
                dragX = value.translation.width
            }
            .onEnded { value in
                guard revealed else { return }
                if abs(value.translation.width) > 100 {
                    withAnimation(.easeIn(duration: 0.2)) {
                        dragX = value.translation.width > 0 ? 700 : -700
                    }
                    advance(afterFlick: true)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { dragX = 0 }
                }
            }
    }

    private func advance(afterFlick: Bool = false) {
        Task { @MainActor in
            if afterFlick { try? await Task.sleep(for: .milliseconds(180)) }
            onAdvance()
            dragX = 0
        }
    }
}

// MARK: - Result card

/// One row in the summary, with the flag that opens the correction sheet.
struct MCQResultCard: View {
    let answer: MCQAnswer
    let isFlagged: Bool
    let onFlag: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: answer.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.pp(size: 15, .semibold))
                .foregroundStyle(answer.isCorrect ? Pastel.mint : Pastel.blush)

            VStack(alignment: .leading, spacing: 3) {
                Text(answer.question.question)
                    .font(.pp(.footnote, .semibold))
                    .foregroundStyle(Pastel.ink)
                Text(answer.question.explanation)
                    .font(.pp(.caption))
                    .foregroundStyle(Pastel.inkSoft)

                if isFlagged {
                    Label("Correction logged", systemImage: "checkmark")
                        .font(.pp(size: 10, .semibold))
                        .foregroundStyle(Pastel.inkSoft)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            flagButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .softCard(fill: answer.isCorrect ? Pastel.mintSoft : Pastel.blushSoft,
                  radius: 18, padding: 14)
        .animation(.snappy(duration: 0.25), value: isFlagged)
    }

    private var flagButton: some View {
        Button(action: onFlag) {
            Image(systemName: isFlagged ? "flag.fill" : "flag")
                .font(.pp(size: 12, .semibold))
                .foregroundStyle(isFlagged ? Pastel.ink : Pastel.inkSoft.opacity(0.65))
                .frame(width: 28, height: 28)
                .background(isFlagged ? Pastel.peach.opacity(0.55) : Pastel.card.opacity(0.65),
                            in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFlagged
                            ? "Correction logged. Edit your correction"
                            : "Flag this question as incorrect or ambiguous")
    }
}

// MARK: - Correction sheet

/// Lightweight sheet for reporting a bad question. What the user types is saved
/// as a `FeedbackLog` and replayed to the generator in `<MCQCorrectionLedger>`.
struct MCQCorrectionSheet: View {

    let answer: MCQAnswer
    let existingCorrection: String
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var correction: String
    @FocusState private var editorFocused: Bool

    init(answer: MCQAnswer, existingCorrection: String, onSubmit: @escaping (String) -> Void) {
        self.answer = answer
        self.existingCorrection = existingCorrection
        self.onSubmit = onSubmit
        _correction = State(initialValue: existingCorrection)
    }

    private var trimmed: String {
        correction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    questionCard
                    prompt
                    editor
                    submitButton
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Pastel.canvas.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Flag question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .font(.pp(.subheadline))
                }
            }
        }
    }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(answer.question.topic.uppercased())
                .font(.pp(size: 10, .heavy))
                .foregroundStyle(Pastel.inkSoft)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Pastel.cardAlt, in: .capsule)

            Text(answer.question.question)
                .font(.pp(.headline, .semibold))
                .foregroundStyle(Pastel.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 7) {
                ForEach(Array(answer.question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(index: index, option: option)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Answer key")
                    .font(.pp(size: 10, .heavy))
                    .foregroundStyle(Pastel.inkSoft)
                Text(answer.question.explanation)
                    .font(.pp(.footnote))
                    .foregroundStyle(Pastel.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Pastel.cardAlt, in: .rect(cornerRadius: 14, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .softCard(radius: 22, padding: 16)
    }

    private func optionRow(index: Int, option: String) -> some View {
        let isCorrect = index == answer.question.safeCorrectIndex
        let isPicked = index == answer.selectedIndex

        return HStack(spacing: 9) {
            Text(String(UnicodeScalar(65 + index)!))
                .font(.pp(size: 10, .heavy))
                .foregroundStyle(Pastel.inkSoft)
                .frame(width: 20, height: 20)
                .background(Pastel.card, in: .circle)

            Text(option)
                .font(.pp(.subheadline))
                .foregroundStyle(Pastel.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if isCorrect {
                Text("KEY")
                    .font(.pp(size: 9, .heavy))
                    .foregroundStyle(Pastel.ink)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Pastel.mint.opacity(0.5), in: .capsule)
            } else if isPicked {
                Text("YOURS")
                    .font(.pp(size: 9, .heavy))
                    .foregroundStyle(Pastel.ink)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Pastel.blush.opacity(0.5), in: .capsule)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(isCorrect ? Pastel.mintSoft : (isPicked ? Pastel.blushSoft : Pastel.cardAlt),
                    in: .rect(cornerRadius: 13, style: .continuous))
    }

    private var prompt: some View {
        Text("What was incorrect or ambiguous about this question/answer?")
            .font(.pp(.subheadline, .semibold))
            .foregroundStyle(Pastel.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $correction)
                .font(.pp(.callout))
                .foregroundStyle(Pastel.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 130)
                .padding(10)
                .focused($editorFocused)

            if correction.isEmpty {
                Text("e.g. two options are both correct, or the key contradicts the explanation.")
                    .font(.pp(.callout))
                    .foregroundStyle(Pastel.inkSoft.opacity(0.7))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 18)
                    .allowsHitTesting(false)
            }
        }
        .background(Pastel.card, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(editorFocused ? Pastel.lavender : Pastel.hairline, lineWidth: 1.5)
        )
        .animation(.snappy(duration: 0.2), value: editorFocused)
        .accessibilityLabel("Your correction")
    }

    private var submitButton: some View {
        VStack(spacing: 8) {
            Button("Submit correction") {
                onSubmit(trimmed)
                dismiss()
            }
            .buttonStyle(PastelButtonStyle(fill: trimmed.isEmpty ? Pastel.hairline : Pastel.lavender))
            .disabled(trimmed.isEmpty)
            .opacity(trimmed.isEmpty ? 0.55 : 1)
            .animation(.snappy(duration: 0.2), value: trimmed.isEmpty)

            Text("Saved on this device and sent to the question generator so it avoids the same mistake.")
                .font(.pp(.caption))
                .foregroundStyle(Pastel.inkSoft)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: - Previews

#Preview("Result card") {
    let question = MCQQuestion(
        question: "Your RAG answers are fluent but cite the wrong document. What do you fix first?",
        options: ["The retriever and its ranking", "The generation temperature",
                  "The system prompt tone", "The embedding model's context length"],
        correctIndex: 0,
        explanation: "Fluent-but-wrong citations point at retrieval, not generation — measure recall@k before touching the prompt.",
        topic: "RAG")

    return VStack(spacing: 12) {
        MCQResultCard(answer: MCQAnswer(question: question, selectedIndex: 0),
                      isFlagged: false, onFlag: {})
        MCQResultCard(answer: MCQAnswer(question: question, selectedIndex: 2),
                      isFlagged: true, onFlag: {})
    }
    .padding()
    .background(Pastel.canvas)
}

#Preview("Correction sheet") {
    let question = MCQQuestion(
        question: "Which failure mode does a tool-calling agent hit most often in production?",
        options: ["Token limits", "Looping on a failed tool call", "Slow embeddings", "Cold starts"],
        correctIndex: 1,
        explanation: "Without a retry budget and a terminal state, agents re-issue the same failing call.",
        topic: "Agents")

    return MCQCorrectionSheet(answer: MCQAnswer(question: question, selectedIndex: 0),
                              existingCorrection: "",
                              onSubmit: { _ in })
}
