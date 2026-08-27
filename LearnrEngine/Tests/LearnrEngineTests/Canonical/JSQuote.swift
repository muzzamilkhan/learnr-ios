import Foundation

/// JavaScript's `JSON.stringify` applied to a single string.
///
/// **This exists because `grading.ts` puts `JSON.stringify` back into a form
/// built to avoid it.** The canonical form is not JSON precisely so that two
/// encoders never have to agree about escaping — and then the grading set
/// quotes `response` and `recorded` with `JSON.stringify` anyway. The reason is
/// sound: a response is deliberately allowed to be empty or to carry padding,
/// and quoting escapes anything that would otherwise collide with the form's
/// own separators, while making leading and trailing whitespace visible in a
/// raw diff.
///
/// The consequence is that this port cannot use `JSONEncoder`, which differs
/// from `JSON.stringify` on both counts that matter here:
///
/// - **Non-ASCII passes through unescaped.** `JSON.stringify` emits `−`, `×`,
///   `÷`, `°` and `$` as themselves. An encoder that escapes them instead
///   writes six characters where the oracle wrote one, which is a different
///   byte string and so a different hash.
/// - **Control characters take the lowercase `\u001f` form**, four hex digits,
///   except the seven with short escapes.
///
/// So it is written out by hand, which is thirty lines and testable, rather than
/// configured out of a general encoder. Raised with the oracle as
/// `learnr#6`, where the durable fix would be to drop the quoting on that side;
/// until then this matches what it actually does.
enum JSQuote {
    /// The seven characters `JSON.stringify` gives a short escape, in the order
    /// the specification lists them.
    private static let shortEscapes: [Character: String] = [
        "\"": "\\\"",
        "\\": "\\\\",
        "\u{08}": "\\b",
        "\u{0c}": "\\f",
        "\n": "\\n",
        "\r": "\\r",
        "\t": "\\t",
    ]

    static func quote(_ value: String) -> String {
        var out = "\""
        for character in value {
            if let escape = shortEscapes[character] {
                out += escape
            } else if let scalar = character.unicodeScalars.first,
                      character.unicodeScalars.count == 1,
                      scalar.value < 0x20 {
                // Lowercase hex, four digits — `\u001f`, not `\U001F`.
                out += String(format: "\\u%04x", scalar.value)
            } else {
                // Everything else, non-ASCII included, is emitted as itself.
                out.append(character)
            }
        }
        return out + "\""
    }
}
