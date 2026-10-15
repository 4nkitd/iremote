import Foundation

public enum HardwareKeyboard {
    public struct Stroke: Equatable {
        public let code: Int
        public let direction: Int
    }

    public static func strokes(for text: String) -> [Stroke]? {
        guard text.count <= 512 else { return nil }
        var result: [Stroke] = []
        let punctuation: [Character: (Int, Bool)] = [
            " ": (62, false),
            ",": (55, false), ".": (56, false), "`": (68, false),
            "-": (69, false), "=": (70, false), "[": (71, false), "]": (72, false),
            "\\": (73, false), ";": (74, false), "'": (75, false), "/": (76, false),
            "@": (77, false), "+": (81, false), "*": (17, false), "#": (18, false),
            "!": (8, true), "$": (11, true), "%": (12, true), "^": (13, true),
            "&": (14, true), "(": (16, true), ")": (7, true), "_": (69, true),
            "{": (71, true), "}": (72, true), "|": (73, true), ":": (74, true),
            "\"": (75, true), "<": (55, true), ">": (56, true), "?": (76, true), "~": (68, true),
        ]
        for character in text {
            let code: Int
            let shift: Bool
            if let ascii = character.asciiValue, (97...122).contains(ascii) {
                code = Int(ascii) - 97 + 29; shift = false
            } else if let ascii = character.asciiValue, (65...90).contains(ascii) {
                code = Int(ascii) - 65 + 29; shift = true
            } else if let ascii = character.asciiValue, (48...57).contains(ascii) {
                code = Int(ascii) - 48 + 7; shift = false
            } else if let mapping = punctuation[character] {
                (code, shift) = mapping
            } else { return nil }
            if shift { result.append(Stroke(code: 59, direction: 1)) }
            result.append(Stroke(code: code, direction: 3))
            if shift { result.append(Stroke(code: 59, direction: 2)) }
        }
        return result
    }
}
