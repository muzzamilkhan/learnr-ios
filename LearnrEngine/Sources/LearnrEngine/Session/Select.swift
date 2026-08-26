import Foundation

/// What to ask next.
///
/// Ported from `src/lib/reinforcement/select.ts`. The rule in one line: until
/// the answers form a pattern, ask at random; once they do, lean towards what
/// the child is finding hard without burying them in it, and come back to what
/// they have mastered once enough time has passed for remembering it to be
/// worth something.
///
/// Three things keep the lean from becoming a swarm:
///
///  - a **status weight** per topic, which only tilts the odds — nothing is ever
///    ruled out, so a session never turns into twenty subtractions in a row;
///  - a **share of the questions** that weak topics are held between, so a child
///    with one bad topic still spends most of their time elsewhere, and one with
///    six bad topics does not get an easy ride;
///  - a **cooldown** on the topics just asked, so the mix is spread through the
///    session rather than clumped.
///
/// All three are about **topics**, not templates. A topic's weight is split
/// across however many templates it happens to have, so how much practice a
/// child gets on something is decided by how they are doing at it and never by
/// how much content we got round to writing for it.
///
/// Pure: the caller passes `now` and the RNG, so a whole session can be replayed
/// from its seed and starting profile.
public enum Select {

    /// How much each status pulls a topic towards being asked, before mixing.
    public static func statusWeight(_ status: SkillStatus) -> Double {
        switch status {
        case .struggling: return 3      // Hard, and the point of the exercise.
        case .reviewDue: return 2       // Known, but long enough ago to confirm.
        case .new: return 1.4           // Not enough answers to say.
        case .developing: return 1.2    // On its way; keep it at its natural rate.
        case .secure: return 0.35       // Known and fresh. Not silenced.
        }
    }

    /// Statuses that count as work to be done, held to a share of the session.
    static func isFocus(_ status: SkillStatus) -> Bool {
        status == .struggling || status == .reviewDue
    }

    /// The healthy ratio. A fifth of the questions is enough for a weak topic to
    /// improve; beyond a bit under half it stops feeling like practice and
    /// starts feeling like being picked on.
    public static let minFocusShare = 0.2
    public static let maxFocusShare = 0.45

    /// How far a topic is held back for having just been asked: the last topic
    /// first. Never zero — with a small pool the same topic sometimes has to
    /// come round again, and it should be unlikely rather than impossible.
    public static let cooldown: [Double] = [0.1, 0.4, 0.75]

    /// How many questions back the cooldown remembers.
    public static let recentMemory = cooldown.count

    public struct Context: Sendable {
        public let profile: LearnerProfileState
        public let now: Int
        /// Topics of the last questions asked, newest first.
        public let recent: [String]

        public init(profile: LearnerProfileState, now: Int, recent: [String] = []) {
            self.profile = profile
            self.now = now
            self.recent = recent
        }
    }

    public struct WeightedTemplate: Sendable {
        public let template: QuestionTemplate
        public let status: SkillStatus
        /// Relative odds of being drawn. Only meaningful against the others.
        public let weight: Double
    }

    private static func cooldownFactor(_ topic: String, _ recent: [String]) -> Double {
        guard let position = recent.firstIndex(of: topic) else { return 1 }
        // `COOLDOWN[position] ?? 1` in the TypeScript: a topic further back than
        // the table is remembered by `indexOf` but has no factor, and is not
        // held back at all.
        return position < cooldown.count ? cooldown[position] : 1
    }

    /// How many templates each topic has in this pool.
    ///
    /// The unit of the policy is the **topic** — that is what a status is about
    /// and what a share is measured in — but the draw is over templates, so a
    /// topic's weight has to be split across its own templates rather than
    /// multiplied by them. Without this, template count quietly outvotes status:
    /// shipped years have between one and five templates a topic, so a
    /// struggling topic with one template came up less often than an unproven
    /// topic with four.
    ///
    /// A `Dictionary` is safe here where it would not be in `applyObservation`:
    /// only `count` is read back, by key, and nothing iterates it.
    private static func templatesPerTopic(_ templates: [QuestionTemplate]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for template in templates {
            counts[template.topic, default: 0] += 1
        }
        return counts
    }

    /// The odds each template is drawn at, and why. Public because it is the
    /// whole policy: a test can read it, and so can anything that later wants to
    /// explain a choice to a parent.
    public static func weightTemplates(
        _ templates: [QuestionTemplate], _ context: Context
    ) -> [WeightedTemplate] {
        let recent = context.recent

        let statuses = templates.map { template in
            Profile.skillStatus(
                Profile.findSkill(context.profile, template.topic, template.level), context.now)
        }

        // Nothing is known yet, so there is nothing to act on: draw at random
        // rather than build a diagnosis out of two answers. Random here means
        // random over templates, which is what it has always meant.
        guard Profile.hasPattern(context.profile) else {
            return zip(templates, statuses).map {
                WeightedTemplate(template: $0, status: $1, weight: 1)
            }
        }

        let perTopic = templatesPerTopic(templates)

        let weighted = zip(templates, statuses).map { template, status in
            WeightedTemplate(
                template: template,
                status: status,
                weight: statusWeight(status) * cooldownFactor(template.topic, recent)
                    / Double(perTopic[template.topic] ?? 1))
        }

        let focus = weighted.filter { isFocus($0.status) }
        let rest = weighted.filter { !isFocus($0.status) }
        if focus.isEmpty || rest.isEmpty { return weighted }

        // Summed left to right, matching `reduce` in the TypeScript. Float
        // addition is not associative, so the order is part of the answer.
        let focusMass = focus.reduce(0.0) { $0 + $1.weight }
        let restMass = rest.reduce(0.0) { $0 + $1.weight }
        if focusMass <= 0 || restMass <= 0 { return weighted }

        // The floor is skipped when every topic needing work is the one just
        // asked: holding the ratio matters over a session, not at the cost of
        // asking the same thing twice running.
        let justAsked = recent.first
        let floor = focus.contains { $0.template.topic != justAsked } ? minFocusShare : 0

        let share = focusMass / (focusMass + restMass)
        let target = min(max(share, floor), maxFocusShare)
        if target == share { return weighted }

        let scale = (target * restMass) / ((1 - target) * focusMass)
        return weighted.map { entry in
            isFocus(entry.status)
                ? WeightedTemplate(
                    template: entry.template, status: entry.status, weight: entry.weight * scale)
                : entry
        }
    }

    /// Draws one template. The RNG is spent exactly once, whatever the weights.
    public static func selectTemplate(
        _ templates: [QuestionTemplate], _ context: Context, _ rng: inout Rng
    ) throws -> QuestionTemplate {
        guard !templates.isEmpty else { throw SelectError.emptyPool }

        let weighted = weightTemplates(templates, context)
        let total = weighted.reduce(0.0) { $0 + $1.weight }

        // `!(total > 0)` in the TypeScript, which is also false for NaN — and
        // NaN is reachable, since a weight is a quotient. Written the same way
        // round here so a NaN total falls through to `pick` rather than walking
        // a list that every comparison against it will refuse.
        guard total > 0 else { return rng.pick(templates) }

        // `roll < 0`, not `<= 0`. The two part only when `roll` lands exactly on
        // zero mid-walk, which needs `rng.next()` to return exactly 0 —
        // mulberry32 emits `k / 2^32` and no draw in three million was zero, so
        // this is unreachable rather than merely unlikely. Written as the
        // TypeScript writes it regardless: the walk is the policy, and matching
        // it costs nothing.
        var roll = rng.next() * total
        for entry in weighted {
            roll -= entry.weight
            if roll < 0 { return entry.template }
        }
        // The final template, when float error leaves `roll` a hair above zero
        // after the last subtraction.
        return weighted[weighted.count - 1].template
    }

    /// The topics this pool would currently treat as work to be done.
    public static func focusTopics(
        _ templates: [QuestionTemplate], _ context: Context
    ) -> [String] {
        let topics = weightTemplates(templates, context)
            .filter { isFocus($0.status) }
            .map(\.template.topic)
        // `[...new Set(topics)].sort()` — deduplicated, then sorted. JavaScript's
        // default sort is by UTF-16 code unit, which for the ASCII topic names
        // in shipped content is the same order Swift's `<` gives.
        return Array(Set(topics)).sorted()
    }
}

public enum SelectError: Error, Equatable {
    /// Refused rather than returning nothing: an empty pool is a content bug,
    /// and a session that silently drew nothing would be harder to find.
    case emptyPool
}
