//
//  PythonConsoleView.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An interactive Python console (REPL) view.
public struct PythonConsoleView: View {
    @StateObject private var python = Terrarium.shared
    @State private var inputCode = ""
    @State private var history: [ConsoleEntry] = []
    @State private var isExecuting = false
    @FocusState private var isInputFocused: Bool

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Console output
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(history) { entry in
                            ConsoleEntryView(entry: entry)
                        }

                        // Anchor for scrolling to bottom
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding()
                }
                .onChange(of: history.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            Divider()

            // Input area
            HStack(spacing: 12) {
                Text(">>>")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)

                TextField("Enter Python code", text: $inputCode, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.plain)
                    .focused($isInputFocused)
                    .lineLimit(1...5)
                    .onSubmit {
                        executeCode()
                    }
                    .submitLabel(.send)

                if isExecuting {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Button {
                        executeCode()
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(inputCode.isEmpty)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
        }
        .navigationTitle("Python Console")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        history.removeAll()
                    } label: {
                        Label("Clear Console", systemImage: "trash")
                    }

                    Button {
                        copyHistory()
                    } label: {
                        Label("Copy History", systemImage: "doc.on.doc")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            initializeIfNeeded()
        }
    }

    private func initializeIfNeeded() {
        guard !python.isInitialized else { return }

        Task {
            do {
                try await python.initialize()
                history.append(ConsoleEntry(
                    input: nil,
                    output: "Python \(python.configuration.pythonVersion) ready.",
                    isError: false
                ))
            } catch {
                history.append(ConsoleEntry(
                    input: nil,
                    output: "Failed to initialize Python: \(error.localizedDescription)",
                    isError: true
                ))
            }
        }
    }

    private func executeCode() {
        let code = inputCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }

        inputCode = ""
        isExecuting = true

        // Add input to history
        history.append(ConsoleEntry(
            input: code,
            output: nil,
            isError: false
        ))

        Task {
            let result = await python.run(code: code)

            // Add output to history
            if result.isSuccess {
                if !result.stdout.isEmpty {
                    history.append(ConsoleEntry(
                        input: nil,
                        output: result.stdout,
                        isError: false
                    ))
                }
            } else {
                let errorOutput = result.exception ?? result.stderr
                if !errorOutput.isEmpty {
                    history.append(ConsoleEntry(
                        input: nil,
                        output: errorOutput,
                        isError: true
                    ))
                }
            }

            isExecuting = false
        }
    }

    private func copyHistory() {
        let text = history.map { entry in
            var line = ""
            if let input = entry.input {
                line += ">>> \(input)\n"
            }
            if let output = entry.output {
                line += output
            }
            return line
        }.joined(separator: "\n")

        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - Console Entry

private struct ConsoleEntry: Identifiable {
    let id = UUID()
    let input: String?
    let output: String?
    let isError: Bool
    let timestamp = Date()
}

private struct ConsoleEntryView: View {
    let entry: ConsoleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let input = entry.input {
                HStack(alignment: .top, spacing: 4) {
                    Text(">>>")
                        .foregroundStyle(.secondary)
                    Text(input)
                }
                .font(.system(.body, design: .monospaced))
            }

            if let output = entry.output {
                Text(output)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(entry.isError ? .red : .primary)
            }
        }
        .textSelection(.enabled)
    }
}
