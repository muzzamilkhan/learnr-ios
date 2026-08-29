import SwiftUI

/// The one external link in the app, and the gate in front of it.
///
/// **Why there is a gate.** `docs/app-review-notes.md` tells Apple the app has
/// no external links, and rests its Kids Category parental-gate argument on
/// that - "nothing behind a gate to guard". One ungated link would contradict a
/// claim already written for the reviewer, in the category where Apple looks
/// hardest.
///
/// **Why the date is not kept.** `PrivacyInfo.xcprivacy` says no date of birth
/// is collected. The date entered here is compared and discarded: never
/// written, never sent, and the pass is deliberately not remembered between
/// openings. Remembering it means holding a date of birth or a flag derived
/// from one, which is what would force a privacy-declaration change. Re-asking
/// costs a grown-up five seconds, once.
///
/// No cases, on purpose: there is nowhere for state to live on this type at
/// all, which is a stronger guarantee than "nothing currently stores
/// anything".
enum GrownUpGate {

    /// Where a grown-up is sent to set up an account.
    ///
    /// This is the correct and only right destination - not a placeholder, and
    /// not something to "fix" toward a more specific-looking route. Ledger
    /// `L29` asked the web side for the real sign-up route and the answer is
    /// that there isn't a separate one to find: parent sign-in is Google-only,
    /// so signing in with Google *is* account creation, and the root is the
    /// one URL that behaves correctly for every visitor state - signed-out,
    /// a parent with children already, a parent with none yet, and a
    /// signed-in child.
    ///
    /// Do not change this to `/signin`: that is Auth.js's error destination,
    /// not a page meant for a person to land on deliberately. Do not deep-link
    /// `/children` either: for a signed-out visitor it silently discards the
    /// intent that brought them here.
    static let signUpURL = URL(string: "https://learnr.muzza.tech")!

    /// Eighteen years, by the calendar rather than by 365-day arithmetic - leap
    /// years make the two disagree, and disagreeing on a birthday is the one
    /// day this must get right.
    static func isAdult(birthDate: Date, now: Date) -> Bool {
        let calendar = Calendar(identifier: .gregorian)
        guard let eighteenth = calendar.date(byAdding: .year, value: 18, to: birthDate)
        else { return false }
        return eighteenth <= now
    }
}

/// Asks for a date of birth, opens the link, and forgets the date.
struct GrownUpGateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// View state only. It dies with the sheet, which is the whole design.
    @State private var birthDate = Calendar(identifier: .gregorian)
        .date(byAdding: .year, value: -30, to: Date()) ?? Date()
    @State private var refused = false

    var body: some View {
        VStack(spacing: 22) {
            Text("For grown-ups")
                .font(.system(size: 28, weight: .bold, design: .rounded))

            Text("Please enter your date of birth to continue.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            DatePicker("Date of birth",
                       selection: $birthDate,
                       in: ...Date(),
                       displayedComponents: .date)
                .datePickerStyle(.wheel)
                .labelsHidden()

            if refused {
                Text("Please ask a grown-up to help.")
                    .font(.headline)
                    .foregroundStyle(.red)
            }

            Button("Continue") {
                if GrownUpGate.isAdult(birthDate: birthDate, now: Date()) {
                    openURL(GrownUpGate.signUpURL)
                    dismiss()
                } else {
                    refused = true
                }
            }
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Palette.brand, in: RoundedRectangle(cornerRadius: 18))

            Button("Cancel") { dismiss() }
                .foregroundStyle(Palette.inkSoft)

            // Said plainly, because it is true and because a grown-up asked for
            // a date of birth in a children's app deserves to be told.
            Text("Your date of birth is not stored or sent anywhere.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: 460)
    }
}
