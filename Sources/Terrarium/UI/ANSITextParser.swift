//
//  ANSITextParser.swift
//  Terrarium
//
//  Parses ANSI escape sequences in console output into a SwiftUI
//  AttributedString so the Python Runner's Console tab renders colors,
//  bold, italic, underline, and dim styling the way a real terminal would.
//
//  Supports:
//    • ESC[0m              — reset all attributes
//    • ESC[1m / [22m       — bold on / off
//    • ESC[2m              — dim
//    • ESC[3m / [23m       — italic on / off
//    • ESC[4m / [24m       — underline on / off
//    • ESC[30-37m          — standard foreground (black, red, green, yellow, blue, magenta, cyan, white)
//    • ESC[40-47m          — standard background
//    • ESC[90-97m          — bright foreground (gray, bright red, …)
//    • ESC[100-107m        — bright background
//    • ESC[38;5;Nm         — 256-color foreground (8-bit palette)
//    • ESC[38;2;R;G;Bm     — truecolor foreground (24-bit RGB)
//    • ESC[48;5;Nm         — 256-color background
//    • ESC[48;2;R;G;Bm     — truecolor background
//    • ESC[39m / [49m      — reset to default fg / bg
//
//  Unknown SGR codes are silently dropped (matches xterm's tolerance).
//  Non-SGR ANSI sequences (cursor moves, screen clears, OSC, etc.) are
//  also stripped so they don't leak into the rendered text.

import Foundation
import SwiftUI

enum ANSITextParser {

    /// Parse `text` into an `AttributedString` with ANSI styling applied.
    /// If `text` contains no escape sequences, this is essentially a no-op
    /// (one AttributedString allocation, no regex traversal of the body).
    static func parse(_ text: String) -> AttributedString {
        // Fast path — most prints contain no escapes.
        if !text.contains("\u{1B}") {
            return AttributedString(text)
        }

        var result = AttributedString()
        var state = State()

        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c != "\u{1B}" {
                // Walk forward until the next ESC (or end of string),
                // then emit that slice as one styled run.
                let chunkStart = i
                while i < text.endIndex && text[i] != "\u{1B}" {
                    i = text.index(after: i)
                }
                let chunk = String(text[chunkStart..<i])
                if !chunk.isEmpty {
                    result.append(state.attribute(string: chunk))
                }
                continue
            }

            // ESC sequence. Figure out what kind.
            let escStart = i
            i = text.index(after: i)
            guard i < text.endIndex else {
                // Trailing lone ESC — drop it.
                break
            }

            let second = text[i]
            if second == "[" {
                // CSI: collect parameters and the final byte.
                i = text.index(after: i)
                let paramStart = i
                while i < text.endIndex {
                    let ch = text[i]
                    // SGR parameters are digits + ';'; the final byte is
                    // anywhere in 0x40–0x7E. We only care about 'm' (SGR);
                    // anything else (cursor moves etc.) we strip silently.
                    if ch.isASCII && (ch.isLetter || ch == "~") {
                        break
                    }
                    i = text.index(after: i)
                }
                guard i < text.endIndex else { break }
                let finalByte = text[i]
                let paramString = String(text[paramStart..<i])
                i = text.index(after: i)

                if finalByte == "m" {
                    state.applySGR(paramString)
                }
                // Other CSI commands: dropped silently (no visible effect).
                continue
            }
            if second == "]" {
                // OSC: skip up to BEL (0x07) or ESC\.
                i = text.index(after: i)
                while i < text.endIndex {
                    let ch = text[i]
                    if ch == "\u{07}" {
                        i = text.index(after: i)
                        break
                    }
                    if ch == "\u{1B}" && text.index(after: i) < text.endIndex
                        && text[text.index(after: i)] == "\\"
                    {
                        i = text.index(i, offsetBy: 2)
                        break
                    }
                    i = text.index(after: i)
                }
                continue
            }
            // Other escape kinds (single-character C1): drop the ESC and the
            // following byte. This is more aggressive than xterm but safer
            // for our use case (we never expect these in stdout).
            _ = escStart
            i = text.index(after: i)
        }

        return result
    }

    // MARK: - State machine

    private struct State {
        var foreground: Color?
        var background: Color?
        var bold: Bool = false
        var dim: Bool = false
        var italic: Bool = false
        var underline: Bool = false

        mutating func reset() {
            foreground = nil
            background = nil
            bold = false
            dim = false
            italic = false
            underline = false
        }

        func attribute(string: String) -> AttributedString {
            var s = AttributedString(string)
            if let foreground { s.foregroundColor = foreground }
            if let background { s.backgroundColor = background }
            if bold {
                s.font = .system(.caption, design: .monospaced).bold()
            }
            if italic {
                s.font = .system(.caption, design: .monospaced).italic()
            }
            if underline {
                s.underlineStyle = .single
            }
            if dim {
                s.foregroundColor = (s.foregroundColor ?? .primary).opacity(0.55)
            }
            return s
        }

        /// Apply one or more semicolon-separated SGR parameters.
        mutating func applySGR(_ params: String) {
            // No params = "0" = reset.
            if params.isEmpty {
                reset()
                return
            }
            let tokens = params.split(separator: ";").compactMap { Int($0) }
            var idx = 0
            while idx < tokens.count {
                let code = tokens[idx]
                switch code {
                case 0:
                    reset()
                case 1:
                    bold = true
                case 2:
                    dim = true
                case 3:
                    italic = true
                case 4:
                    underline = true
                case 22:
                    bold = false
                    dim = false
                case 23:
                    italic = false
                case 24:
                    underline = false
                case 30...37:
                    foreground = Self.standardColor(code - 30, bright: false)
                case 39:
                    foreground = nil
                case 40...47:
                    background = Self.standardColor(code - 40, bright: false)
                case 49:
                    background = nil
                case 90...97:
                    foreground = Self.standardColor(code - 90, bright: true)
                case 100...107:
                    background = Self.standardColor(code - 100, bright: true)
                case 38, 48:
                    // Extended-color specs: 38;5;N (8-bit) or 38;2;R;G;B (24-bit).
                    let isForeground = (code == 38)
                    if idx + 1 < tokens.count {
                        let mode = tokens[idx + 1]
                        if mode == 5, idx + 2 < tokens.count {
                            let c = Self.xterm256(tokens[idx + 2])
                            if isForeground { foreground = c } else { background = c }
                            idx += 2
                        } else if mode == 2, idx + 4 < tokens.count {
                            let r = Double(max(0, min(255, tokens[idx + 2]))) / 255.0
                            let g = Double(max(0, min(255, tokens[idx + 3]))) / 255.0
                            let b = Double(max(0, min(255, tokens[idx + 4]))) / 255.0
                            let c = Color(red: r, green: g, blue: b)
                            if isForeground { foreground = c } else { background = c }
                            idx += 4
                        } else {
                            idx += 1
                        }
                    }
                default:
                    break  // unknown SGR, ignore
                }
                idx += 1
            }
        }

        /// 0=black, 1=red, ..., 7=white. `bright` shifts the swatch to the
        /// "bright" variant (16-color palette upper half).
        private static func standardColor(_ index: Int, bright: Bool) -> Color {
            switch (index, bright) {
            case (0, false):  return Color(red: 0.10, green: 0.10, blue: 0.10)
            case (1, false):  return Color(red: 0.80, green: 0.20, blue: 0.20)
            case (2, false):  return Color(red: 0.20, green: 0.65, blue: 0.30)
            case (3, false):  return Color(red: 0.75, green: 0.55, blue: 0.10)
            case (4, false):  return Color(red: 0.20, green: 0.45, blue: 0.85)
            case (5, false):  return Color(red: 0.65, green: 0.30, blue: 0.75)
            case (6, false):  return Color(red: 0.10, green: 0.65, blue: 0.65)
            case (7, false):  return Color(red: 0.80, green: 0.80, blue: 0.80)
            case (0, true):   return Color(red: 0.45, green: 0.45, blue: 0.45)
            case (1, true):   return Color(red: 1.00, green: 0.40, blue: 0.40)
            case (2, true):   return Color(red: 0.40, green: 0.85, blue: 0.50)
            case (3, true):   return Color(red: 1.00, green: 0.80, blue: 0.30)
            case (4, true):   return Color(red: 0.45, green: 0.65, blue: 1.00)
            case (5, true):   return Color(red: 0.85, green: 0.55, blue: 0.95)
            case (6, true):   return Color(red: 0.40, green: 0.90, blue: 0.90)
            case (7, true):   return Color(red: 1.00, green: 1.00, blue: 1.00)
            default:          return .primary
            }
        }

        /// xterm 256-color palette.
        /// 0-15: standard + bright
        /// 16-231: 6×6×6 RGB cube
        /// 232-255: grayscale ramp
        private static func xterm256(_ n: Int) -> Color {
            if n < 0 || n > 255 { return .primary }
            if n < 8 {
                return standardColor(n, bright: false)
            }
            if n < 16 {
                return standardColor(n - 8, bright: true)
            }
            if n < 232 {
                // 6×6×6 RGB cube. Each channel maps via the xterm ramp:
                // 0 → 0, 1 → 95, 2 → 135, 3 → 175, 4 → 215, 5 → 255
                let i = n - 16
                let r = i / 36
                let g = (i / 6) % 6
                let b = i % 6
                func ramp(_ v: Int) -> Double {
                    if v == 0 { return 0 }
                    return Double(55 + v * 40) / 255.0
                }
                return Color(red: ramp(r), green: ramp(g), blue: ramp(b))
            }
            // 232..255 grayscale ramp
            let level = Double(8 + (n - 232) * 10) / 255.0
            return Color(red: level, green: level, blue: level)
        }
    }
}
