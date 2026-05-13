//
//  PythonFileManagerView.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import SwiftUI

/// Main view for managing Python scripts.
public struct PythonFileManagerView: View {
    @StateObject private var python = Terrarium.shared
    @State private var searchText = ""
    @State private var selectedScript: PythonScript?
    @State private var showingNewScript = false
    @State private var showingPackageManager = false
    @State private var filterOption: FilterOption = .all

    public init() {}

    public var body: some View {
        NavigationStack {
            Group {
                if python.isInitialized {
                    scriptListContent
                } else {
                    initializationView
                }
            }
            .navigationTitle("Python Scripts")
            .toolbar {
                #if !os(macOS)
                ToolbarItem(placement: .topBarLeading) {
                    filterPicker
                }
                #else
                ToolbarItem(placement: .automatic) {
                    filterPicker
                }
                #endif

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingNewScript = true
                        } label: {
                            Label("New Script", systemImage: "plus")
                        }

                        Button {
                            showingPackageManager = true
                        } label: {
                            Label("Package Manager", systemImage: "shippingbox")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingNewScript) {
                PythonScriptEditorView(mode: .create)
            }
            .sheet(isPresented: $showingPackageManager) {
                PythonPackageManagerView()
            }
            .sheet(item: $selectedScript) { script in
                PythonScriptEditorView(mode: .edit(script))
            }
        }
    }

    @ViewBuilder
    private var filterPicker: some View {
        Picker("Filter", selection: $filterOption) {
            ForEach(FilterOption.allCases, id: \.self) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.menu)
    }

    @ViewBuilder
    private var initializationView: some View {
        VStack(spacing: 20) {
            if python.currentState == .initializing {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Initializing Python Runtime...")
                    .foregroundStyle(.secondary)
            } else if case .failed(let error) = python.currentState {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.orange)

                Text("Initialization Failed")
                    .font(.headline)

                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Retry") {
                    Task {
                        try? await python.initialize()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.tint)

                Text("Python Runtime")
                    .font(.headline)

                Text("Initialize the Python runtime to start creating and running scripts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button("Initialize") {
                    Task {
                        try? await python.initialize()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    @ViewBuilder
    private var scriptListContent: some View {
        let filteredScripts = filterScripts(python.scriptManager.scripts)

        if filteredScripts.isEmpty && searchText.isEmpty {
            ContentUnavailableView {
                Label("No Scripts", systemImage: "doc.text")
            } description: {
                Text("Create your first Python script to get started.")
            } actions: {
                Button("Create Script") {
                    showingNewScript = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(filteredScripts) { script in
                    ScriptRowView(script: script)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedScript = script
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task {
                                    try? await python.deleteScript(id: script.id)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button {
                                Task {
                                    _ = await python.run(scriptId: script.id)
                                }
                            } label: {
                                Label("Run", systemImage: "play.fill")
                            }
                            .tint(.green)
                        }
                }
            }
            .searchable(text: $searchText, prompt: "Search scripts")
            .refreshable {
                await python.scriptManager.loadScripts()
            }
        }
    }

    private func filterScripts(_ scripts: [PythonScript]) -> [PythonScript] {
        var result = scripts

        // Apply filter
        switch filterOption {
        case .all:
            break
        case .aiGenerated:
            result = result.filter { $0.isAIGenerated }
        case .userCreated:
            result = result.filter { !$0.isAIGenerated }
        case .recentlyRun:
            result = result
                .filter { $0.lastExecutedAt != nil }
                .sorted { ($0.lastExecutedAt ?? .distantPast) > ($1.lastExecutedAt ?? .distantPast) }
        }

        // Apply search
        if !searchText.isEmpty {
            result = result.filter { script in
                script.name.localizedCaseInsensitiveContains(searchText) ||
                (script.description?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                script.code.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result
    }
}

// MARK: - Filter Options

private enum FilterOption: CaseIterable {
    case all
    case aiGenerated
    case userCreated
    case recentlyRun

    var displayName: String {
        switch self {
        case .all: return "All Scripts"
        case .aiGenerated: return "AI Generated"
        case .userCreated: return "User Created"
        case .recentlyRun: return "Recently Run"
        }
    }
}

// MARK: - Script Row View

private struct ScriptRowView: View {
    let script: PythonScript

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(script.name)
                    .font(.headline)

                if script.isAIGenerated {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }

                Spacer()

                if let result = script.lastResult {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.success ? .green : .red)
                        .font(.caption)
                }
            }

            if let description = script.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Text("Modified \(script.modifiedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let executed = script.lastExecutedAt {
                    Text("Run \(executed.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !script.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(script.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
