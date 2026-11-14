import Foundation

/// The look of one session's buddy. The same session id always gives the same buddy.
public struct BuddyTraits: Equatable {
    public enum Shape: Int, CaseIterable { case blob, bot, ghost, cat }

    public static let colorCount = 8
    public static let names = [
        "Pip", "Mochi", "Biscuit", "Nova", "Pebble", "Juno", "Waffle", "Ziggy", "Olive", "Comet", "Tofu", "Maple",
        "Bean", "Echo", "Clover", "Fig", "Sprout", "Orbit", "Poppy", "Rune", "Kiwi", "Dot", "Sage", "Nimbus",
    ]

    public var shape: Shape
    public var color: Int
    public var name: String
    /// Shifts the animation so buddies do not move in step with each other.
    public var phase: Double

    public init(seed: String) {
        let hash = Self.fnv1a(seed)
        shape = Shape.allCases[Int(hash % UInt64(Shape.allCases.count))]
        color = Int((hash >> 8) % UInt64(Self.colorCount))
        name = Self.names[Int((hash >> 16) % UInt64(Self.names.count))]
        phase = Double((hash >> 32) % 1000) / 100
    }

    /// Swift's own hashing changes on every launch, so a fixed hash is used here.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

/// Where the evidence hook keeps its log for a session.
public enum Evidence {
    /// The folder name the hooks use for a working directory: every character that is not a letter or digit becomes "-".
    public static func slug(_ cwd: String) -> String {
        let mapped = String(cwd.unicodeScalars.map { scalar -> Character in
            let isPlain = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))
            return isPlain ? Character(scalar) : "-"
        })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    public static func file(home: URL = FileManager.default.homeDirectoryForCurrentUser, cwd: String, sessionId: String) -> URL {
        home.appendingPathComponent("claude-evidence").appendingPathComponent(slug(cwd))
            .appendingPathComponent(sessionId).appendingPathComponent("evidence.md")
    }
}
