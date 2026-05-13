//
//  PythonScriptEditorView.swift
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

/// View for creating and editing Python scripts.
public struct PythonScriptEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var python = Terrarium.shared

    let mode: EditorMode

    @State private var name: String = ""
    @State private var code: String = ""
    @State private var description: String = ""
    @State private var tags: [String] = []
    @State private var newTag: String = ""

    @State private var isRunning = false
    @State private var lastResult: PythonRunResult?
    @State private var showingOutput = false
    @State private var errorMessage: String?

    public enum EditorMode {
        case create
        case edit(PythonScript)

        var title: String {
            switch self {
            case .create: return "New Script"
            case .edit: return "Edit Script"
            }
        }

        var script: PythonScript? {
            switch self {
            case .create: return nil
            case .edit(let script): return script
            }
        }
    }

    public init(mode: EditorMode) {
        self.mode = mode
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("Script Info") {
                        TextField("Name", text: $name)
                            #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            #endif

                        TextField("Description (optional)", text: $description)
                    }

                    Section("Code") {
                        codeEditor
                    }

                    Section("Tags") {
                        tagsView
                    }

                    if let result = lastResult {
                        Section("Last Output") {
                            outputPreview(result: result)
                        }
                    }
                }

                // Bottom action bar
                actionBar
            }
            .navigationTitle(mode.title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveScript()
                    }
                    .disabled(name.isEmpty || code.isEmpty)
                }
            }
            .onAppear {
                loadInitialData()
            }
            .sheet(isPresented: $showingOutput) {
                if let result = lastResult {
                    PythonOutputView(result: result)
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") {
                    errorMessage = nil
                }
            } message: {
                if let error = errorMessage {
                    Text(error)
                }
            }
        }
    }

    @ViewBuilder
    private var codeEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Line numbers and code
            ZStack(alignment: .topLeading) {
                TextEditor(text: $code)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)

                if code.isEmpty {
                    Text("# Enter your Python code here\nprint('Hello, World!')")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .opacity(0.5)
                        .allowsHitTesting(false)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)
                }
            }

            // Code stats
            HStack {
                Text("\(code.components(separatedBy: "\n").count) lines")
                Text("\(code.count) characters")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var tagsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Existing tags
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag)
                                Button {
                                    tags.removeAll { $0 == tag }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.2))
                            .cornerRadius(8)
                        }
                    }
                }
            }

            // Add new tag
            HStack {
                TextField("Add tag", text: $newTag)
                    #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()

                Button("Add") {
                    addTag()
                }
                .disabled(newTag.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func outputPreview(result: PythonRunResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.isSuccess ? .green : .red)

                Text(result.isSuccess ? "Success" : "Failed")
                    .font(.headline)

                Spacer()

                Text("\(result.durationMs)ms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !result.combinedOutput.isEmpty {
                Text(result.combinedOutput)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(5)
                    .foregroundStyle(.secondary)

                Button("View Full Output") {
                    showingOutput = true
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 16) {
            Button {
                runScript()
            } label: {
                HStack {
                    if isRunning {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(isRunning ? "Running..." : "Run")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.isEmpty || isRunning)

            Button {
                clearOutput()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(lastResult == nil)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
    }

    // MARK: - Actions

    private func loadInitialData() {
        if let script = mode.script {
            name = script.name
            code = script.code
            description = script.description ?? ""
            tags = script.tags
        }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        if !tag.isEmpty && !tags.contains(tag) {
            tags.append(tag)
        }
        newTag = ""
    }

    private func runScript() {
        guard !code.isEmpty else { return }

        isRunning = true

        Task {
            let result = await python.run(code: code)
            lastResult = result
            isRunning = false

            // If editing, record the execution
            if let script = mode.script {
                try? await python.scriptManager.recordExecution(scriptId: script.id, result: result)
            }
        }
    }

    private func clearOutput() {
        lastResult = nil
    }

    private func saveScript() {
        Task {
            do {
                if let existingScript = mode.script {
                    // Update existing script
                    var updated = existingScript
                    updated.name = name
                    updated.code = code
                    updated.description = description.isEmpty ? nil : description
                    updated.tags = tags

                    try await python.scriptManager.updateScript(updated)
                } else {
                    // Create new script
                    let script = try await python.createScript(
                        name: name,
                        code: code,
                        description: description.isEmpty ? nil : description
                    )
                    // Update tags
                    var withTags = script
                    withTags.tags = tags
                    try await python.scriptManager.updateScript(withTags)
                }

                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Output View

public struct PythonOutputView: View {
    @Environment(\.dismiss) private var dismiss
    let result: PythonRunResult

    public init(result: PythonRunResult) {
        self.result = result
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Status header
                    HStack {
                        Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(result.isSuccess ? .green : .red)

                        VStack(alignment: .leading) {
                            Text(result.isSuccess ? "Execution Successful" : "Execution Failed")
                                .font(.headline)
                            Text("Exit code: \(result.exitCode) | Duration: \(result.durationMs)ms")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)

                    // Standard Output
                    if !result.stdout.isEmpty {
                        outputSection(title: "Standard Output", content: result.stdout, icon: "text.alignleft")
                    }

                    // Standard Error
                    if !result.stderr.isEmpty {
                        outputSection(title: "Standard Error", content: result.stderr, icon: "exclamationmark.triangle", color: .orange)
                    }

                    // Exception
                    if let exception = result.exception {
                        outputSection(title: "Exception", content: exception, icon: "xmark.octagon", color: .red)
                    }

                    // Empty output message
                    if result.stdout.isEmpty && result.stderr.isEmpty && result.exception == nil {
                        Text("No output produced")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("Execution Output")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        copyToClipboard(result.combinedOutput)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func outputSection(title: String, content: String, icon: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
            }

            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
        }
    }

    private func copyToClipboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
