import SwiftUI
import LearnrEngine

/// Where a child answers questions.
///
/// The layout, top to bottom: a bar with the way out and how many have been
/// answered, then the question — its figure above its prompt — then the entry,
/// then the pad. The proportions follow the web's: the question gets the room
/// that is left, and the pad gets a fixed share at the bottom where thumbs are.
struct PlayView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var play: PlaySession?
    let level: YearLevel

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            if let play {
                switch play.status {
                case .loading:
                    ProgressView().controlSize(.large).tint(Palette.brand)
                case .unavailable:
                    unavailable
                case .playing:
                    playing(play)
                }
            } else {
                ProgressView().controlSize(.large).tint(Palette.brand)
            }
        }
        .task {
            guard play == nil else { return }
            let session = PlaySession(
                library: session.library, queue: session.queue, api: session.api, level: level)
            play = session
            await session.start()
        }
    }

    // MARK: Playing

    @ViewBuilder
    private func playing(_ play: PlaySession) -> some View {
        VStack(spacing: 0) {
            header(play)

            // The question. Takes the room the pad does not, which is what
            // makes a figure as large as the screen can afford.
            question(play)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            entry(play)

            pad(play)
                .frame(height: 300)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private func header(_ play: PlaySession) -> some View {
        HStack {
            Button {
                Task {
                    await play.finish()
                    await session.refreshPendingCount()
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.inkSoft)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Finish")

            Spacer()

            if play.answeredCount > 0 {
                Text("\(play.answeredCount)")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.inkSoft)
                    .monospacedDigit()
                    .accessibilityLabel("\(play.answeredCount) answered")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func question(_ play: PlaySession) -> some View {
        if let question = play.question {
            VStack(spacing: 20) {
                if let figure = question.question.figure {
                    DiagramView(figure: figure)
                        .frame(maxWidth: 420, maxHeight: .infinity)
                        .padding(.horizontal, 24)
                }

                Text(question.question.prompt)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What has been typed, and what the answer turned out to be.
    ///
    /// One slot rather than two: after a wrong answer the entry is replaced by
    /// the right answer, because that is the thing worth reading. A tapped
    /// question has nothing to show here until it has been answered.
    @ViewBuilder
    private func entry(_ play: PlaySession) -> some View {
        let height: CGFloat = 84

        Group {
            switch play.phase {
            case .asking:
                if play.mode == .tap {
                    Color.clear
                } else {
                    Text(play.entry.isEmpty ? " " : play.entry)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .monospacedDigit()
                }

            case .answered(let correct, let expected):
                HStack(spacing: 12) {
                    Image(systemName: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(correct ? Palette.right : Palette.wrong)

                    Text(correct ? play.entry : expected)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(correct ? Palette.right : Palette.wrong)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(correct ? "Correct" : "The answer is \(expected)")
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(feedbackBackground(play.phase))
        .animation(.easeOut(duration: 0.15), value: play.phase)
    }

    private func feedbackBackground(_ phase: PlaySession.Phase) -> Color {
        switch phase {
        case .asking: return .clear
        case .answered(let correct, _): return correct ? Palette.rightSoft : Palette.wrongSoft
        }
    }

    /// The pad, or the Continue button that replaces it after a wrong answer.
    ///
    /// A wrong answer is never on a timer: the child reads the right answer and
    /// taps Continue, so it stays on screen for as long as they want it.
    @ViewBuilder
    private func pad(_ play: PlaySession) -> some View {
        if case .answered(let correct, _) = play.phase, !correct {
            VStack {
                Spacer()
                Button {
                    play.advance()
                } label: {
                    Text("Continue")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .background(Palette.brand, in: RoundedRectangle(cornerRadius: 16))
                }
                .frame(maxWidth: 420)
                Spacer()
            }
        } else {
            let disabled = play.phase != .asking

            switch play.mode {
            case .number:
                NumberPad(
                    disabled: disabled,
                    canCheck: play.canCheck,
                    onDigit: play.type,
                    onBackspace: play.backspace,
                    onCheck: play.check)
            case .text:
                LetterPad(
                    disabled: disabled,
                    canCheck: play.canCheck,
                    onLetter: play.type,
                    onBackspace: play.backspace,
                    onCheck: play.check)
            case .tap:
                VStack {
                    Spacer()
                    ChoicePad(
                        options: play.options,
                        disabled: disabled,
                        onChoose: play.submit)
                    Spacer()
                }
            }
        }
    }

    // MARK: Nothing to play

    private var unavailable: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 44))
                .foregroundStyle(Palette.inkSoft)

            Text("No questions yet")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink)

            // Honest about the one thing that fixes it. Questions are cached
            // after the first connection, so this only ever appears before a
            // device has managed one.
            Text("Connect to the internet once, and questions will be ready "
                 + "even when you are offline.")
                .font(.system(size: 17))
                .foregroundStyle(Palette.inkSoft)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Try again") {
                Task { await play?.start() }
            }
            .font(.system(size: 18, weight: .semibold, design: .rounded))
            .padding(.top, 8)

            Button("Go back") { dismiss() }
                .font(.system(size: 17))
                .foregroundStyle(Palette.inkSoft)
        }
    }
}
