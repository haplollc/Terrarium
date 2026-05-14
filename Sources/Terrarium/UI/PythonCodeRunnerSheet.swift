//
//  PythonCodeRunnerSheet.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//  Rewritten 2026-05 to mirror SwiftCodeRunnerSheet's tabbed Console/View layout.
//

import SwiftUI
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A bottom sheet that runs Python code and shows the result.
///
/// Structure mirrors `SwiftCodeRunnerSheet`: a `Console` tab (default) for
/// `print()` output and a `View` tab that displays any images the script
/// produced via `terrarium_show.show(...)`. The xmark, segmented picker, and the
/// Run / Clear buttons all live in the navigation bar at the top.
@MainActor
public struct PythonCodeRunnerSheet: View {
    let code: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: CodeRunnerViewModel
    @State private var selectedTab: Tab = .console
    @State private var consoleCopied = false
    @State private var errorCopied = false

    enum Tab: Hashable {
        case console
        case view
    }

    public init(code: String) {
        self.code = code
        _viewModel = StateObject(wrappedValue: CodeRunnerViewModel(code: code))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.state == .running && viewModel.output.isEmpty && viewModel.images.isEmpty {
                    runningView
                } else if viewModel.state == .error, viewModel.output.isEmpty, viewModel.images.isEmpty,
                          let err = viewModel.error {
                    // Show the error full-screen only when there's no other
                    // output to surface — otherwise users want to see the
                    // partial print()s that came before the exception.
                    errorView(error: err)
                } else {
                    // Both tabs are kept alive at all times via opacity
                    // toggling. Tearing them down on tab switch would force
                    // the ScrollView's content to re-layout — for long
                    // outputs that's a visible jank.
                    ZStack {
                        viewTab
                            .opacity(selectedTab == .view ? 1 : 0)
                            .allowsHitTesting(selectedTab == .view)
                        consoleTab
                            .opacity(selectedTab == .console ? 1 : 0)
                            .allowsHitTesting(selectedTab == .console)
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.medium))
                            .foregroundColor(.primary)
                    }
                }
                ToolbarItem(placement: .principal) {
                    if viewModel.hasResults {
                        Picker("Output", selection: $selectedTab) {
                            Text("Console").tag(Tab.console)
                            Text("View").tag(Tab.view)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220)
                    } else {
                        Text("Python Runner")
                            .font(.headline)
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(action: {
                        if viewModel.state == .running {
                            viewModel.stop()
                        } else {
                            viewModel.run()
                        }
                    }) {
                        Image(systemName: viewModel.state == .running ? "stop.fill" : "play.fill")
                            .font(.body.weight(.medium))
                            .foregroundColor(.primary)
                    }
                    .help(viewModel.state == .running ? "Stop" : "Run again")

                    Button(action: { viewModel.clear() }) {
                        Image(systemName: "trash")
                            .font(.body.weight(.medium))
                            .foregroundColor(viewModel.canClear ? .primary : .secondary)
                    }
                    .disabled(!viewModel.canClear)
                    .help("Clear output")
                }
            }
        }
        .onAppear {
            viewModel.runIfFresh()
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Console tab — terminal-style stdout/stderr display
    // ─────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var consoleTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Console")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
                Spacer()
                if let ms = viewModel.durationMs {
                    Text("\(ms) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary.opacity(0.7))
                }
                if !viewModel.output.isEmpty {
                    copyButton(text: viewModel.output, isCopied: $consoleCopied, tint: .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                if viewModel.output.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.append")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text(viewModel.state == .running ? "Running..." : "No console output")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Use print(...) to log output here.")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    // Parse ANSI escape sequences so `rich`, `colorama`, and
                    // raw `\033[31m` colored prints render properly. Fast
                    // path: if the output has no ESC chars, the parser
                    // returns a plain AttributedString in one allocation.
                    Text(ANSITextParser.parse(viewModel.output))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }

                // Surface a non-fatal error/traceback inline AFTER the
                // partial stdout, matching how a real REPL looks.
                if let err = viewModel.error {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text("Exception")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.red)
                        }
                        Text(err)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.red.opacity(0.85))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal)
                    .padding(.bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: View tab — images / charts produced by terrarium_show.show(...)
    // ─────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private var viewTab: some View {
        if viewModel.images.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 38))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("No view output")
                    .font(.headline)
                    .foregroundColor(.secondary)
                VStack(spacing: 4) {
                    Text("Display charts or images in this tab with:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("import terrarium_show")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.accentColor)
                    Text("terrarium_show.show(fig)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.accentColor)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
            .background(Color(nsColor: .windowBackgroundColor))
            #else
            .background(Color(.systemGroupedBackground))
            #endif
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(Array(viewModel.images.enumerated()), id: \.offset) { _, data in
                        imageCard(for: data)
                    }
                }
                .padding()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
            .background(Color(nsColor: .windowBackgroundColor))
            #else
            .background(Color(.systemGroupedBackground))
            #endif
        }
    }

    @ViewBuilder
    private func imageCard(for data: Data) -> some View {
        #if canImport(UIKit)
        if let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
        } else {
            corruptedImagePlaceholder
        }
        #elseif canImport(AppKit)
        if let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
        } else {
            corruptedImagePlaceholder
        }
        #else
        corruptedImagePlaceholder
        #endif
    }

    private var corruptedImagePlaceholder: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Image data could not be decoded")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Error + running placeholders
    // ─────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private func errorView(error: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("Error")
                        .font(.headline)
                        .foregroundColor(.red)
                    Spacer()
                    copyButton(text: error, isCopied: $errorCopied, tint: .red)
                }
                Text(error)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.red.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .background(Color.red.opacity(0.10))
    }

    private var runningView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Running...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: Copy button shared between console & error
    // ─────────────────────────────────────────────────────────────────────

    @ViewBuilder
    private func copyButton(text: String, isCopied: Binding<Bool>, tint: Color) -> some View {
        Button(action: {
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            #endif
            isCopied.wrappedValue = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { isCopied.wrappedValue = false }
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: isCopied.wrappedValue ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                Text(isCopied.wrappedValue ? "Copied!" : "Copy")
                    .font(.caption)
            }
            .foregroundColor(tint.opacity(0.9))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isCopied.wrappedValue)
    }
}

// MARK: - View Model

@MainActor
private class CodeRunnerViewModel: ObservableObject {
    let code: String

    @Published var state: RunState = .idle
    @Published var output: String = ""
    @Published var error: String?
    @Published var durationMs: Int?
    @Published var images: [Data] = []

    /// Bumped each time `run()` starts. Stale async resumes whose seq
    /// doesn't match the current one drop silently — guards against
    /// double-tap-Run races where the older completion would otherwise
    /// clobber the newer one's results.
    private var runSeq: Int = 0

    /// Reference to the in-flight `run()` Task so `stop()` can cancel it.
    /// Cancelling here aborts the Swift-side await; whether the Python
    /// interpreter itself actually stops depends on `Terrarium.run`'s
    /// own cancellation behavior. Either way, the UI returns to idle.
    private var runTask: Task<Void, Never>?

    enum RunState {
        case idle
        case running
        case success
        case error
    }

    /// Whether there's anything worth tabbing between (or copying).
    var hasResults: Bool {
        !output.isEmpty || error != nil || !images.isEmpty
    }

    /// Whether the Clear button does anything.
    var canClear: Bool {
        hasResults || durationMs != nil
    }

    init(code: String) {
        self.code = code
    }

    /// Run the code only if we haven't already run it once. `onAppear`
    /// can fire multiple times during the sheet's lifetime (e.g. on
    /// dismissing a child sheet) and we don't want every re-appearance
    /// to re-execute the script.
    func runIfFresh() {
        if state == .idle { run() }
    }

    func run() {
        guard state != .running else { return }

        runSeq += 1
        let mySeq = runSeq

        state = .running
        output = ""
        error = nil
        durationMs = nil
        images = []

        runTask = Task {
            if !Terrarium.shared.isInitialized {
                do {
                    try await Terrarium.shared.initialize()
                } catch {
                    guard mySeq == self.runSeq else { return }
                    self.state = .error
                    self.error = "Failed to initialize Python: \(error.localizedDescription)"
                    return
                }
            }

            if Task.isCancelled {
                guard mySeq == self.runSeq else { return }
                self.state = .idle
                return
            }

            // Stream `%pip` magic-command output live into the Console tab
            // as each install / uninstall progresses. Goes through
            // `appendStreamingOutput` so terminal-style carriage returns
            // (\r) overwrite the current line in place — that's how pip
            // draws its byte-level progress bar.
            let result = await Terrarium.shared.run(code: code) { [weak self] line in
                guard let self else { return }
                guard mySeq == self.runSeq else { return }
                self.output = Self.appendStreamingOutput(line, to: self.output)
            }
            guard mySeq == self.runSeq else { return }

            if Task.isCancelled {
                self.state = .idle
                return
            }

            let (cleanedOutput, extractedImages) = Self.extractImages(from: result.stdout)
            self.images = extractedImages
            self.durationMs = result.durationMs

            // Append the script's own stdout to whatever was streamed in
            // live (the `%pip` install log). Replacing would wipe the
            // streamed log; appending preserves the full session.
            let scriptOut = cleanedOutput
            let combined: String
            if self.output.isEmpty {
                combined = scriptOut
            } else if scriptOut.isEmpty {
                combined = self.output
            } else if self.output.hasSuffix("\n") {
                combined = self.output + scriptOut
            } else {
                combined = self.output + "\n" + scriptOut
            }

            if result.isSuccess {
                self.state = .success
                self.output = combined
            } else {
                self.state = .error
                self.output = combined
                self.error = result.exception ?? (result.stderr.isEmpty ? nil : result.stderr)
            }
        }
    }

    /// Cancel the in-flight run. The Swift `await` resumes immediately;
    /// whether the Python interpreter actually halts depends on the
    /// runner. UI returns to `.idle` either way so the user can re-run.
    func stop() {
        guard state == .running else { return }
        runTask?.cancel()
        runTask = nil
        state = .idle
    }

    func clear() {
        output = ""
        error = nil
        durationMs = nil
        images = []
        state = .idle
    }

    // MARK: Streaming-output append (handles \r the way a terminal does)

    /// Append a streamed `chunk` to `existing`, honoring carriage returns:
    /// `\r` moves the cursor back to the start of the current line, so
    /// the next characters overwrite. This is how `pip` (and `wget`,
    /// `curl`, etc.) animate their progress bars without scrolling the
    /// terminal. Without this, every progress update would print on its
    /// own new line and you'd see hundreds of "Downloading … 14%" lines.
    static func appendStreamingOutput(_ chunk: String, to existing: String) -> String {
        guard chunk.contains("\r") else { return existing + chunk }
        var current = existing
        // Split keeps empty subsequences so "\rX\rY" yields ["", "X", "Y"].
        let parts = chunk.split(separator: "\r", omittingEmptySubsequences: false).map(String.init)
        for (i, part) in parts.enumerated() {
            if i > 0 {
                // Just hit a \r — truncate `current` back to the most
                // recent newline (or all the way to empty if none).
                if let lastNL = current.lastIndex(of: "\n") {
                    let after = current.index(after: lastNL)
                    current = String(current[..<after])
                } else {
                    current = ""
                }
            }
            current += part
        }
        return current
    }

    // MARK: Image extraction

    /// Marker that `terrarium_show.show(...)` emits on its own stdout line.
    /// Must stay in sync with `Resources/site-packages/terrarium_show.py`.
    private static let imageMarker = "__TERRARIUM_IMG_PNG_B64__:"

    /// Pull marker lines out of stdout, decode the base64 PNG payloads,
    /// and return both the cleaned stdout (for the Console tab) and the
    /// decoded image data (for the View tab).
    private static func extractImages(from stdout: String) -> (cleaned: String, images: [Data]) {
        guard stdout.contains(imageMarker) else {
            return (stdout, [])
        }

        var cleanedLines: [String] = []
        var images: [Data] = []
        for raw in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let range = line.range(of: imageMarker) {
                let b64 = String(line[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !b64.isEmpty, let data = Data(base64Encoded: b64) {
                    images.append(data)
                }
                // Marker lines are dropped entirely — including any text
                // before the marker on the same line, which is almost
                // never intentional and looks broken in the console.
            } else {
                cleanedLines.append(line)
            }
        }

        // Collapse any runs of blank lines that the dropped markers left
        // behind, so deleting a marker line doesn't leave a visible gap.
        var collapsed: [String] = []
        var lastWasBlank = false
        for line in cleanedLines {
            let isBlank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank && lastWasBlank { continue }
            collapsed.append(line)
            lastWasBlank = isBlank
        }
        // Trim leading/trailing blank lines for tidiness.
        while collapsed.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            collapsed.removeFirst()
        }
        while collapsed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            collapsed.removeLast()
        }

        return (collapsed.joined(separator: "\n"), images)
    }
}

// MARK: - View Modifier for Easy Integration

public struct PythonCodeRunnerModifier: ViewModifier {
    @Binding var codeToRun: String?

    public func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { codeToRun.map { CodeToRun(code: $0) } },
                set: { codeToRun = $0?.code }
            )) { item in
                PythonCodeRunnerSheet(code: item.code)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }
}

private struct CodeToRun: Identifiable {
    let id = UUID()
    let code: String
}

public extension View {
    /// Presents the Python code runner sheet when `codeToRun` is set.
    func pythonCodeRunner(code: Binding<String?>) -> some View {
        modifier(PythonCodeRunnerModifier(codeToRun: code))
    }
}

// MARK: - Preview

#Preview {
    PythonCodeRunnerSheet(code: """
        print("Hello, World!")
        print(2 + 2)

        for i in range(5):
            print(f"Count: {i}")
        """)
}
