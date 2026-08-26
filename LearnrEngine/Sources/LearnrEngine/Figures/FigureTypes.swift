import Foundation

/// The figure vocabulary, ported from `src/lib/figures/types.ts`.
///
/// A question the child has to *look* at: the picture is the question and the
/// prompt is its caption. This file is what an author writes (`FigureSpec`) and
/// what the builder resolves it into (`Figure`).
///
/// The rule the whole feature protects is that **no single diagram may become
/// the anchor for an answer**. If every obtuse angle is drawn the same way, a
/// child learns to recognise that picture rather than an obtuse angle. So a
/// figure is generated from the bound scope and the `Rng`, and it **varies by
/// default**: a template pins the property the question is about and says
/// nothing about rotation, size or proportion. Omitting an optional field is
/// what asks for jitter; supplying one pins it, deliberately.

/// A point in the resolved figure's box: x right, y **down**, which is what a
/// renderer wants with no flipping of its own.
///
/// The builder works in the ordinary maths frame with y up — the frame
/// rotations and symmetry axes are named in — and turns it over once, on the
/// way out, in `fit`.
public struct Point: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    /// Encoded as the two-element array the TypeScript uses, so a figure
    /// crosses the wire in the shape the web app and the vectors both write.
    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
    }
}

/// The four primitives a figure is drawn from.
///
/// Deliberately few: a renderer turns marks into shapes and makes no decisions,
/// so anything it would have to know how to draw is a decision that has escaped
/// the engine.
public enum Mark: Equatable, Sendable {
    /// A polyline: the shape itself, a right-angle tick, a mirror line.
    case path(points: [Point], closed: Bool, fill: Bool, dashed: Bool)
    /// Degrees, anticlockwise-positive, 0 = east — read the way the angle in
    /// the question is read, not the way a y-down frame would count them. A
    /// renderer places the sweep at `(cx + r·cos θ, cy − r·sin θ)`.
    case arc(at: Point, radius: Double, from: Double, to: Double)
    /// A marked point — the vertex an angle is *at*, which the arms alone do
    /// not say.
    case dot(at: Point)
    /// Text pinned to a point. Five kinds emit one: `bar`, `pictograph`,
    /// `number-line`, `clock` and `grid`.
    case label(at: Point, text: String)
}

extension Mark: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, points, closed, fill, dashed, at, radius, from, to, text
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "path":
            self = .path(
                points: try c.decode([Point].self, forKey: .points),
                closed: try c.decode(Bool.self, forKey: .closed),
                fill: try c.decode(Bool.self, forKey: .fill),
                dashed: try c.decode(Bool.self, forKey: .dashed)
            )
        case "arc":
            self = .arc(
                at: try c.decode(Point.self, forKey: .at),
                radius: try c.decode(Double.self, forKey: .radius),
                from: try c.decode(Double.self, forKey: .from),
                to: try c.decode(Double.self, forKey: .to)
            )
        case "dot":
            self = .dot(at: try c.decode(Point.self, forKey: .at))
        case "label":
            self = .label(
                at: try c.decode(Point.self, forKey: .at),
                text: try c.decode(String.self, forKey: .text)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c,
                debugDescription: "Unknown mark kind \(other.debugDescription)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .path(let points, let closed, let fill, let dashed):
            try c.encode("path", forKey: .kind)
            try c.encode(points, forKey: .points)
            try c.encode(closed, forKey: .closed)
            try c.encode(fill, forKey: .fill)
            try c.encode(dashed, forKey: .dashed)
        case .arc(let at, let radius, let from, let to):
            try c.encode("arc", forKey: .kind)
            try c.encode(at, forKey: .at)
            try c.encode(radius, forKey: .radius)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        case .dot(let at):
            try c.encode("dot", forKey: .kind)
            try c.encode(at, forKey: .at)
        case .label(let at, let text):
            try c.encode("label", forKey: .kind)
            try c.encode(at, forKey: .at)
            try c.encode(text, forKey: .text)
        }
    }
}

/// A resolved figure: serialisable, comparable, and drawable by anything.
public struct Figure: Equatable, Sendable, Codable {
    public var width: Double
    public var height: Double
    public var marks: [Mark]
}

/// The resolved box is this square, in whatever units a renderer scales it to.
public let figureBox: Double = 100

/// Kept clear inside the box by `fit`, so a stroke drawn along the outline has
/// somewhere to be: marks are lines with width, and a figure fitted to the very
/// edge of its box loses half that width to the clip.
///
/// It lives in the vocabulary rather than beside `fit` because a kind that
/// places labels has to know it too — the slack between the drawing and the box
/// is the only room a label's ink has to hang outside the anchor point `fit`
/// measures it by.
public let figurePadding: Double = 6

/// The ceiling a figure's mark count is held to when read back from storage.
///
/// Measured over all 127 shipped figure templates on 200 seeds each, the worst
/// is 68: a clock face, whose dial is sixty minute ticks before it has drawn a
/// hand. This is defence against a hand-rolled payload, not against a child's
/// session.
public let maxMarks = 200

/// Coordinates are rounded to this many places at build time. It keeps a stored
/// figure small and — the reason that matters — it makes two figures comparable
/// as strings, which is what tells "drawn afresh" from "drawn identically
/// again".
public let figurePrecision = 2

/// The closed vocabulary of shape names.
///
/// A count of sides would be less to author with and not enough to author
/// *from*: it cannot tell a rhombus from a kite, and a randomly wobbled
/// quadrilateral has no line of symmetry at all, so a true/false symmetry
/// question drawn that way would have no true case.
public let polygonShapes = [
    "equilateral", "isosceles", "scalene", "right-triangle", "square",
    "rectangle", "rhombus", "parallelogram", "trapezium", "kite",
    "pentagon", "hexagon", "heptagon", "octagon",
]

public let figureKinds = [
    "polygon", "angle", "bar", "pictograph", "spinner", "solid",
    "number-line", "clock", "array", "fraction-shape", "grid",
]

/// An authored figure spec: a kind, and its fields as expression strings.
///
/// Modelled as a kind plus a field bag rather than as an enum of eleven cases,
/// which is the one deliberate departure from the TypeScript's shape. The
/// reason is what reads a spec: every field goes through the same
/// evaluate-and-degrade path (`readField`), and no code anywhere pattern-matches
/// a spec to decide what a field *means* — the kind's builder does that by name.
/// An enum would buy exhaustiveness the builders never use, and cost a decoder
/// that must reject any spec whose kind it does not know, where the contract
/// here is explicitly that an unknown kind still draws something.
public struct FigureSpec: Sendable, Decodable, Equatable {
    public let kind: String
    /// Every other key on the spec, unevaluated. Absent and empty are the same
    /// thing to `readField`, so a missing field needs no representation of its
    /// own.
    public let fields: [String: Expr]

    public init(kind: String, fields: [String: Expr] = [:]) {
        self.kind = kind
        self.fields = fields
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        var kind = ""
        var fields: [String: Expr] = [:]
        for key in c.allKeys {
            if key.stringValue == "kind" {
                kind = (try? c.decode(String.self, forKey: key)) ?? ""
            } else if let expr = try? c.decode(Expr.self, forKey: key) {
                fields[key.stringValue] = expr
            }
            // A non-string field is left out rather than rejected: it reads as
            // absent, which is the same degradation an unevaluable one gets.
        }
        self.kind = kind
        self.fields = fields
    }

    public subscript(field: String) -> Expr? { fields[field] }
}
