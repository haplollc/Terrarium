//
//  PythonPackageManagerView.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import SwiftUI

/// View for managing Python packages.
public struct PythonPackageManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var python = Terrarium.shared

    @State private var searchText = ""
    @State private var selectedTab = PackageTab.installed
    @State private var showingInstallSheet = false
    @State private var packageToInstall = ""
    @State private var errorMessage: String?

    /// Pyodide-side packages — fetched async from the WASM runtime on
    /// appear and after each install/uninstall. Stored locally so the
    /// list view can render synchronously.
    @State private var pyodidePackages: [PyodidePackageInfo] = []
    @State private var pyodideLoading = false

    public init() {}

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("View", selection: $selectedTab) {
                    ForEach(PackageTab.allCases, id: \.self) { tab in
                        Text(tab.displayName).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                // Content
                switch selectedTab {
                case .installed:
                    installedPackagesView
                case .available:
                    availablePackagesView
                case .stdlib:
                    standardLibraryView
                }
            }
            .navigationTitle("Python Packages")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingInstallSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search packages")
            .sheet(isPresented: $showingInstallSheet) {
                installPackageSheet
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
            .onAppear {
                loadPyodidePackages()
            }
            .refreshable {
                loadPyodidePackages()
            }
        }
    }

    // MARK: - Installed Packages

    @ViewBuilder
    private var installedPackagesView: some View {
        let cpythonPackages = filteredPackages(python.packageManager.installedPackages)
        let pyodideFiltered = filteredPyodidePackages(pyodidePackages)
        let nothingInstalled = cpythonPackages.isEmpty && pyodideFiltered.isEmpty

        if nothingInstalled {
            if searchText.isEmpty {
                ContentUnavailableView {
                    Label("No Packages Installed", systemImage: "shippingbox")
                } description: {
                    Text("Install Python packages with `%pip install <name>` in the runner, or browse the curated list.")
                } actions: {
                    Button("Browse Packages") {
                        selectedTab = .available
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            List {
                if !cpythonPackages.isEmpty {
                    Section {
                        ForEach(cpythonPackages) { package in
                            InstalledPackageRow(
                                package: package,
                                state: python.packageManager.packageStates[package.name.lowercased()] ?? .installed,
                                onUninstall: {
                                    uninstallPackage(package)
                                }
                            )
                        }
                    } header: {
                        Text("CPython")
                    } footer: {
                        Text("Pure-Python packages running on the bundled CPython 3.13 framework. Fast, no network needed at run-time.")
                    }
                }

                if !pyodideFiltered.isEmpty || pyodideLoading {
                    Section {
                        if pyodideLoading && pyodideFiltered.isEmpty {
                            HStack {
                                ProgressView().scaleEffect(0.8)
                                Text("Loading…").foregroundStyle(.secondary)
                            }
                        }
                        ForEach(pyodideFiltered) { pkg in
                            PyodidePackageRow(
                                package: pkg,
                                onUninstall: { uninstallPyodidePackage(pkg) }
                            )
                        }
                    } header: {
                        HStack {
                            Text("Pyodide")
                            Spacer()
                            Text(totalPyodideSize(pyodideFiltered))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("Scientific packages (numpy, pandas, matplotlib, …) running on Pyodide (WebAssembly). Downloaded on first import from the Pyodide CDN, then cached on this device.")
                    }
                }
            }
        }
    }

    private func filteredPyodidePackages(_ packages: [PyodidePackageInfo]) -> [PyodidePackageInfo] {
        guard !searchText.isEmpty else { return packages }
        return packages.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func totalPyodideSize(_ packages: [PyodidePackageInfo]) -> String {
        let total = packages.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        if total == 0 { return "" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    private func loadPyodidePackages() {
        pyodideLoading = true
        Task {
            let pkgs = await python.pyodide.listPackages()
            pyodidePackages = pkgs
            pyodideLoading = false
        }
    }

    private func uninstallPyodidePackage(_ pkg: PyodidePackageInfo) {
        Task {
            let ok = await python.pyodide.uninstallPackage(pkg.name)
            if !ok {
                errorMessage = "Could not uninstall \(pkg.name) from Pyodide."
            }
            loadPyodidePackages()
        }
    }

    // MARK: - Available Packages

    @ViewBuilder
    private var availablePackagesView: some View {
        let packages = filteredPackages(python.packageManager.availablePackages)

        if packages.isEmpty {
            if searchText.isEmpty {
                ContentUnavailableView {
                    Label("No Packages Available", systemImage: "magnifyingglass")
                } description: {
                    Text("Search for packages or install a package by name.")
                }
            } else {
                ContentUnavailableView.search(text: searchText)
            }
        } else {
            List {
                Section {
                    ForEach(packages) { package in
                        AvailablePackageRow(
                            package: package,
                            state: python.packageManager.packageStates[package.name.lowercased()] ?? (package.isInstalled ? .installed : .notInstalled),
                            onInstall: {
                                installPackage(package.name)
                            }
                        )
                    }
                } header: {
                    Text("Recommended Packages")
                } footer: {
                    Text("These pure-Python packages are known to work on iOS.")
                }
            }
        }
    }

    // MARK: - Standard Library

    @ViewBuilder
    private var standardLibraryView: some View {
        let modules = BuiltinPackages.standardLibraryModules.sorted { $0.key < $1.key }
        let filtered = searchText.isEmpty ? modules : modules.filter {
            $0.key.localizedCaseInsensitiveContains(searchText) ||
            $0.value.localizedCaseInsensitiveContains(searchText)
        }

        List {
            Section {
                ForEach(filtered, id: \.key) { module, description in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(module)
                                .font(.headline)
                                .fontDesign(.monospaced)

                            Spacer()

                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }

                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Python Standard Library")
            } footer: {
                Text("These modules are always available - no installation needed. Use `import \(filtered.first?.key ?? "json")` in your code.")
            }
        }
    }

    // MARK: - Install Sheet

    @ViewBuilder
    private var installPackageSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Package name", text: $packageToInstall)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("Install Package")
                } footer: {
                    Text("Enter the name of a Python package from PyPI. Only pure-Python packages are supported.")
                }

                Section {
                    Button("Install") {
                        let name = packageToInstall
                        packageToInstall = ""
                        showingInstallSheet = false
                        installPackage(name)
                    }
                    .disabled(packageToInstall.isEmpty)
                }

                Section("Notes") {
                    Label("Packages with native extensions (numpy, pandas, etc.) are not supported on iOS.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Install Package")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showingInstallSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Helpers

    private func filteredPackages(_ packages: [PythonPackage]) -> [PythonPackage] {
        guard !searchText.isEmpty else { return packages }

        return packages.filter { pkg in
            pkg.name.localizedCaseInsensitiveContains(searchText) ||
            (pkg.description?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private func installPackage(_ name: String) {
        Task {
            do {
                try await python.installPackage(name)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func uninstallPackage(_ package: PythonPackage) {
        Task {
            do {
                try await python.uninstallPackage(package.name)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Package Tab

private enum PackageTab: CaseIterable {
    case installed
    case available
    case stdlib

    var displayName: String {
        switch self {
        case .installed: return "Installed"
        case .available: return "Available"
        case .stdlib: return "Built-in"
        }
    }
}

// MARK: - Pyodide Package Row

private struct PyodidePackageRow: View {
    let package: PyodidePackageInfo
    let onUninstall: () -> Void

    @State private var isUninstalling = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(package.name)
                        .font(.headline)
                    Text("v\(package.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Pyodide")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.purple.opacity(0.18))
                        .foregroundStyle(.purple)
                        .cornerRadius(4)
                }
                if package.sizeBytes > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: package.sizeBytes, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isUninstalling {
                ProgressView().scaleEffect(0.8)
            } else {
                Button(role: .destructive) {
                    isUninstalling = true
                    onUninstall()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Installed Package Row

private struct InstalledPackageRow: View {
    let package: PythonPackage
    let state: PackageInstallState
    let onUninstall: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(package.name)
                        .font(.headline)

                    if let version = package.version {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if package.isBundled {
                        Text("Bundled")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .foregroundStyle(.blue)
                            .cornerRadius(4)
                    }
                }

                if let description = package.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    if let size = package.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let installed = package.installedAt, !package.isBundled {
                        Text("Installed \(installed.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // State indicator - bundled packages can't be uninstalled
            if package.isBundled {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                switch state {
                case .uninstalling:
                    ProgressView()
                        .scaleEffect(0.8)
                case .failed(let error):
                    Button {
                        // Show error details
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .help(error)
                default:
                    Button(role: .destructive) {
                        onUninstall()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Available Package Row

private struct AvailablePackageRow: View {
    let package: PythonPackage
    let state: PackageInstallState
    let onInstall: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(package.name)
                        .font(.headline)

                    if package.isPurePython {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                if let description = package.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            // Install button/state
            switch state {
            case .notInstalled:
                Button("Install") {
                    onInstall()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            case .installing(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .installed, .bundled:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)

            case .uninstalling:
                ProgressView()
                    .scaleEffect(0.8)

            case .failed(let error):
                Button {
                    onInstall() // Retry
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(error)
            }
        }
        .padding(.vertical, 4)
    }
}
