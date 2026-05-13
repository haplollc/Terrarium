//
//  MarkdownPythonRunner.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import SwiftUI
import MarkdownUI

/// A view modifier that enables Python code execution from Markdown code blocks.
///
/// Usage:
/// ```swift
/// Markdown(content)
///     .enablePythonCodeRunner()
/// ```
public struct MarkdownPythonRunnerModifier: ViewModifier {
    @State private var codeToRun: String?
    @Environment(\.codeRunAction) private var upstreamCodeRunAction

    public init() {}

    public func body(content: Content) -> some View {
        content
            .onCodeRun { code, language in
                let lang = language?.lowercased()
                if lang == "python" || lang == "py" {
                    codeToRun = code
                } else {
                    // Forward non-Python languages to any outer runner (e.g. Swift)
                    // so stacked .enableSwiftCodeRunner() / .enablePythonCodeRunner()
                    // calls cooperate instead of one shadowing the other.
                    upstreamCodeRunAction?(code, language)
                }
            }
            .sheet(item: Binding(
                get: { codeToRun.map { PythonCodeItem(code: $0) } },
                set: { codeToRun = $0?.code }
            )) { item in
                PythonCodeRunnerSheet(code: item.code)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }
}

private struct PythonCodeItem: Identifiable {
    let id = UUID()
    let code: String
}

public extension View {
    /// Enables Python code execution from Markdown code blocks.
    ///
    /// When applied to a `Markdown` view, this adds a "Run" button to Python
    /// code blocks. Tapping the button opens a terminal-like sheet that
    /// executes the code and displays the output.
    ///
    /// Example:
    /// ```swift
    /// Markdown("""
    /// Here's some Python code:
    ///
    /// ```python
    /// print("Hello, World!")
    /// ```
    /// """)
    /// .enablePythonCodeRunner()
    /// ```
    func enablePythonCodeRunner() -> some View {
        modifier(MarkdownPythonRunnerModifier())
    }
}
