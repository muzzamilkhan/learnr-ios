import SwiftUI
import LearnrEngine

/// Ninety seconds of one mode.
///
/// Three screens in one, by phase: the run-up, the run, and what the score
/// turned out to be. The question is up during the countdown too — that is the
/// point of a run-up, and it is why the clock starts on a question that has
/// already been read.
struct SpeedRunView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    let mode: Mode
    @State private var run: SpeedSession?

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            if let run {
                switch run.phase {
                case .countdown, .running:
                    playing(run)
                case .over:
                    SpeedResultView(run: run, onDone: { dismiss() }, onAgain: { restart() })
                }
            } else {
                ProgressView().controlSize(.large).tint(Palette.brand)
            }
        }
        .task {
            guard run == nil else { return }
            let session = SpeedSession(
                mode: mode, api: session.api, queue: session.isDemo ? nil : session.queue)
            run = session
            session.start()
        }
        .onDisappear { run?.abandon() }
    }

    private func restart() {
        let fresh = SpeedSession(
            mode: mode, api: session.api, queue: session.isDemo ? nil : session.queue)
        run = fresh
        fresh.start()
    }

    // MARK: The run

    @ViewBuilder
    private func playing(_ run: SpeedSession) -> some View {
        VStack(spacing: 0) {
            header(run)

            Spacer(minLength: 0)

            questions(run)

            Spacer(minLength: 0)

            entry(run)

            SpeedPad(
                disabled: run.phase != .running,
                onDigit: { run.type($0) },
                onBackspace: run.backspace,
                onClear: run.clear)
                .frame(height: 300)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .overlay(alignment: .bottom) {
            // Bottom-aligned and over the pad only. An earlier version covered
            // the whole screen, which dimmed the very question the run-up
            // exists to let a child read — the countdown was hiding the thing
            // it is there to buy time for. Rendering the PNGs is what showed
            // it; nothing in the state machine was wrong.
            if run.phase == .countdown {
                countdown(run)
            }
        }
    }

    private func header(_ run: SpeedSession) -> some View {
        HStack {
            Button {
                run.abandon()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.inkSoft)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Stop")

            Spacer()

            clock(run)

            Spacer()

            Text("\(run.score)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
                .frame(width: 44)
                .accessibilityLabel("\(run.score) correct")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    /// The clock. Colour and weight step with the pulse rather than counting
    /// down smoothly — the engine names the four states so the view keys off
    /// them instead of re-deriving the thresholds.
    private func clock(_ run: SpeedSession) -> some View {
        Text("\(run.secondsLeft)")
            .font(.system(size: 40, weight: .bold, design: .rounded))
            .foregroundStyle(Self.pulseColour(run.pulse))
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .animation(.easeOut(duration: 0.2), value: run.secondsLeft)
            .scaleEffect(run.pulse == .urgent ? 1.12 : 1)
            .animation(
                run.pulse == .urgent
                    ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                    : .default,
                value: run.pulse)
            .accessibilityLabel("\(run.secondsLeft) seconds left")
    }

    static func pulseColour(_ pulse: Pulse) -> Color {
        switch pulse {
        case .calm: return Palette.inkSoft
        case .slow: return Palette.ink
        case .fast: return Color(hex: 0xD98324)
        case .urgent: return Palette.wrong
        }
    }

    /// The question, and the one after it dimmed above.
    ///
    /// The lookahead is state rather than a render trick, which is why it is
    /// read off the engine here: a lookahead drawn wrongly is visible before it
    /// is answered.
    @ViewBuilder
    private func questions(_ run: SpeedSession) -> some View {
        if let state = run.state {
            VStack(spacing: 18) {
                Text(state.next.prompt)
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.inkSoft)
                    .opacity(0.45)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityHidden(true)

                Text(state.current.prompt)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.opacity)
                    .animation(.easeOut(duration: 0.12), value: state.current.prompt)
            }
            .padding(.horizontal, 24)
        }
    }

    /// What has been typed, graded as it lands.
    ///
    /// A dead entry goes red and stays: it is cleared by the child, because
    /// clearing it for them would erase the mistake before it was seen. There is
    /// no Check key — a right answer submits itself.
    private func entry(_ run: SpeedSession) -> some View {
        let dead = run.verdict == .dead

        return Text(run.entry.isEmpty ? " " : run.entry)
            .font(.system(size: 48, weight: .bold, design: .rounded))
            .foregroundStyle(dead ? Palette.wrong : Palette.ink)
            .monospacedDigit()
            .frame(height: 84)
            .frame(maxWidth: .infinity)
            .background(dead ? Palette.wrongSoft : .clear)
            .animation(.easeOut(duration: 0.12), value: dead)
            .accessibilityLabel(
                run.entry.isEmpty
                    ? "Nothing typed"
                    : (dead ? "\(run.entry), not right" : run.entry))
    }

    // MARK: The run-up

    private func countdown(_ run: SpeedSession) -> some View {
        // Whole seconds, rounded up: three, two, one, and the run starts as one
        // would have become zero.
        let seconds = Int((Double(run.countdownRemainingMs) / 1000).rounded(.up))

        return ZStack {
            Palette.paper

            VStack(spacing: 12) {
                Text(Modes.modeLabel(mode))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.inkSoft)

                Text("\(max(seconds, 1))")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.brand)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.2), value: seconds)
            }
        }
        // The pad's own height, so the run-up occupies the space the keys will
        // and the question above stays fully legible.
        .frame(height: 384)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Starting in \(max(seconds, 1))")
    }
}

/// The result: the score, and one of three things to say about it.
///
/// Takes the three things it shows rather than the session that produced them.
/// The view has no use for a clock or an entry, and taking only what it renders
/// is what lets every tone be built and looked at directly.
struct SpeedResultView: View {
    let mode: Mode
    let score: Int
    let outcome: SpeedSession.Outcome
    let onDone: () -> Void
    let onAgain: () -> Void

    init(mode: Mode, score: Int, outcome: SpeedSession.Outcome,
         onDone: @escaping () -> Void, onAgain: @escaping () -> Void) {
        self.mode = mode
        self.score = score
        self.outcome = outcome
        self.onDone = onDone
        self.onAgain = onAgain
    }

    init(run: SpeedSession, onDone: @escaping () -> Void, onAgain: @escaping () -> Void) {
        self.init(mode: run.mode, score: run.score, outcome: run.outcome,
                  onDone: onDone, onAgain: onAgain)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text(Modes.modeLabel(mode))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.inkSoft)

            Text("\(score)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()

            Text(headline)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onAgain) {
                    Text("Go again")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 68)
                        .background(Palette.brand, in: RoundedRectangle(cornerRadius: 16))
                }

                Button("Done", action: onDone)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.inkSoft)
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .accessibilityElement(children: .contain)
    }

    /// The three things a result screen has to say. A first run has nothing to
    /// beat, so it is told what it set rather than congratulated on it — a
    /// fanfare there would be invented.
    private var headline: String {
        switch outcome {
        case .pending:
            return " "
        case .unsent:
            // The score stands; it is the record that could not be checked.
            // Saying so plainly beats a celebration that might be wrong.
            return "Nice work"
        case .settled(let tone, let best):
            switch tone {
            case .first: return "That's your score to beat"
            case .record: return "A new personal best!"
            case .short: return "Your best is \(best)"
            }
        }
    }

    private var tint: Color {
        if case .settled(.record, _) = outcome { return Palette.right }
        return Palette.inkSoft
    }
}
