//
//  Terrarium.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import Foundation
import Combine

/// Main entry point for Python execution in Terrarium.
/// Provides APIs to run Python code, manage scripts, and install packages.
@MainActor
public final class Terrarium: ObservableObject {

    // MARK: - Singleton

    public static let shared = Terrarium()

    // MARK: - Published State

    @Published public private(set) var isInitialized: Bool = false
    @Published public private(set) var initializationError: PythonError?
    @Published public private(set) var currentState: PythonState = .idle

    // MARK: - Services

    public let runtime: PythonRuntimeService
    public let packageManager: PythonPackageManager
    public let scriptManager: PythonScriptManager

    /// WASM-based Python runtime (Pyodide) — handles scientific packages
    /// (numpy, pandas, matplotlib, scipy, scikit-learn, …) that can't run
    /// under CPython on iOS for lack of cross-compiled wheels on PyPI.
    /// Lazily booted; `awaitReady()` blocks on first use.
    public let pyodide: PyodideBridge = .shared

    // MARK: - Configuration

    public let configuration: PythonConfiguration

    // MARK: - Private Properties

    private let executionQueue = DispatchQueue(label: "com.terrarium.python.execution", qos: .userInitiated)
    private var initializationTask: Task<Void, Never>?

    // MARK: - Initialization

    private init() {
        self.configuration = PythonConfiguration.default
        self.runtime = PythonRuntimeService(configuration: configuration)
        self.packageManager = PythonPackageManager(configuration: configuration)
        self.scriptManager = PythonScriptManager(configuration: configuration)
    }

    /// Initialize the Python runtime. Must be called before running any Python code.
    public func initialize() async throws {
        guard !isInitialized else { return }

        currentState = .initializing

        do {
            // Ensure directories exist
            try configuration.ensureDirectoriesExist()

            // Initialize the runtime
            try await runtime.initialize()

            // Load installed packages
            await packageManager.loadInstalledPackages()

            // Load saved scripts
            await scriptManager.loadScripts()

            isInitialized = true
            currentState = .ready
            initializationError = nil
        } catch let error as PythonError {
            initializationError = error
            currentState = .failed(error)
            throw error
        } catch {
            let pythonError = PythonError.initializationFailed(error.localizedDescription)
            initializationError = pythonError
            currentState = .failed(pythonError)
            throw pythonError
        }
    }

    // MARK: - Code Execution

    /// Callback invoked for each line of `%pip` magic-command output.
    /// Always called on the main actor (Terrarium is `@MainActor`), so
    /// it's safe to mutate `@Published` state directly inside.
    public typealias ProgressCallback = @MainActor (String) -> Void

    /// Run Python code from a string.
    /// - Parameters:
    ///   - code: The Python code to execute.
    ///   - timeout: Maximum execution time in seconds (default: 30).
    ///   - onProgress: Optional callback that receives each pip-style log
    ///     line as it happens (`Collecting …`, `Successfully installed …`).
    ///     If `nil`, the install log is batched and prepended to `stdout`.
    /// - Returns: The result of the execution.
    public func run(
        code: String,
        timeout: TimeInterval = 30,
        onProgress: ProgressCallback? = nil
    ) async -> PythonRunResult {
        guard isInitialized else {
            return PythonRunResult(
                exitCode: -1,
                stdout: "",
                stderr: "Python runtime not initialized. Call initialize() first.",
                exception: nil,
                durationMs: 0
            )
        }

        currentState = .executing
        defer { currentState = .ready }

        // Resolve any `%pip` / `!pip` magic commands BEFORE running the
        // rest of the script. Each install / uninstall is routed to the
        // correct runtime (CPython for pure-Python, Pyodide for anything
        // with native deps). After preprocessing we know which runtime to
        // execute the user's actual code on, too — Pyodide takes over if
        // the script imports any native-extension package.
        let pre = await preprocessMagicCommands(code: code, onProgress: onProgress)
        let route = decideRuntime(code: pre.cleanedCode, hint: pre.runtimeHint)

        let result: PythonRunResult
        switch route {
        case .cpython:
            result = await runtime.execute(code: pre.cleanedCode, timeout: timeout)
        case .pyodide:
            result = await executeOnPyodide(pre.cleanedCode)
        }

        // If a progress callback was supplied, the install log was already
        // streamed; don't prepend it to stdout (avoids duplicate output).
        if onProgress != nil || pre.log.isEmpty {
            return result
        }
        let mergedStdout = result.stdout.isEmpty
            ? pre.log
            : pre.log + "\n" + result.stdout
        return PythonRunResult(
            exitCode: result.exitCode,
            stdout: mergedStdout,
            stderr: result.stderr,
            exception: result.exception,
            durationMs: result.durationMs
        )
    }

    // MARK: - Runtime routing

    /// Which Python implementation a given script should execute on.
    public enum Runtime {
        case cpython   // bundled CPython framework (fast, native, pure-Python only)
        case pyodide   // WASM Python with scientific stack (numpy, matplotlib, …)
    }

    /// Names of packages that REQUIRE the Pyodide runtime — anything with
    /// native C extensions that can't run under our CPython framework on
    /// iOS, but DOES have a pre-built WASM wheel from Pyodide.
    /// Keep this list in sync with Pyodide's supported-packages page:
    /// https://pyodide.org/en/stable/usage/packages-in-pyodide.html
    private static let pyodideOnlyPackages: Set<String> = [
        "numpy", "pandas", "scipy", "matplotlib", "scikit-learn", "sklearn",
        "scikit-image", "skimage", "sympy", "statsmodels", "lxml",
        "cryptography", "cffi", "pillow", "pil", "opencv-python", "cv2",
        "shapely", "networkx", "regex", "yaml", "pyyaml", "msgpack",
        "protobuf", "pyodide-http", "bokeh", "altair", "seaborn", "plotly",
        "wordcloud", "pyarrow", "polars", "duckdb",
    ]

    /// Decide which runtime to use. Hint from the magic-command preprocess
    /// wins (explicit `# %runtime pyodide` or `%pip install <native>` in
    /// the script). Otherwise we scan imports.
    private func decideRuntime(code: String, hint: Runtime?) -> Runtime {
        if let hint { return hint }
        let lower = code.lowercased()
        for pkg in Self.pyodideOnlyPackages {
            let normalized = pkg.replacingOccurrences(of: "-", with: "_")
            if lower.contains("import \(normalized)") || lower.contains("from \(normalized)") {
                return .pyodide
            }
        }
        return .cpython
    }

    /// Wrap Pyodide's `PyodideRunResult` into `PythonRunResult` so callers
    /// don't care which runtime produced the result.
    private func executeOnPyodide(_ code: String) async -> PythonRunResult {
        let r = await pyodide.runPython(code: code)
        return PythonRunResult(
            exitCode: r.exitCode,
            stdout: r.stdout,
            stderr: r.stderr,
            exception: r.exception,
            durationMs: r.durationMs
        )
    }

    // MARK: - %pip Magic Command Preprocessing

    /// Scan `code` for `%pip`/`!pip` magic lines, execute them through
    /// `packageManager`, and strip them from the returned code. Supports:
    ///   • `%pip install <pkg> [<pkg2> …]`     (also `!pip install`)
    ///   • `%pip uninstall <pkg> [<pkg2> …]`
    ///   • `%pip list`
    /// All output mirrors real pip's format (`Collecting …`, `Requirement
    /// already satisfied: …`, etc.) so the runner's Console tab feels
    /// like a normal pip session.
    /// Bundle of stuff `preprocessMagicCommands` returns:
    ///   • cleanedCode — the script with magic lines stripped
    ///   • log         — batched install log (only used when no live callback was given)
    ///   • runtimeHint — set when `%pip install <pyodide-only-pkg>` ran or
    ///     an explicit `# %runtime <name>` magic was found
    private struct MagicPreprocessResult {
        let cleanedCode: String
        let log: String
        let runtimeHint: Runtime?
    }

    private func preprocessMagicCommands(
        code: String,
        onProgress: ProgressCallback?
    ) async -> MagicPreprocessResult {
        let lines = code.components(separatedBy: "\n")
        var cleaned: [String] = []
        var log: [String] = []
        var installedAnything = false
        var runtimeHint: Runtime?

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)

            // Explicit runtime hint: `# %runtime pyodide` or `# %runtime cpython`
            if stripped.hasPrefix("# %runtime ") || stripped.hasPrefix("#%runtime ") {
                let target = stripped.replacingOccurrences(of: "# %runtime ", with: "")
                    .replacingOccurrences(of: "#%runtime ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if target == "pyodide" { runtimeHint = .pyodide }
                if target == "cpython" { runtimeHint = .cpython }
                continue
            }

            guard stripped.hasPrefix("%pip") || stripped.hasPrefix("!pip") else {
                cleaned.append(line)
                continue
            }

            // Drop the leading "%pip" or "!pip" sigil.
            let body = String(stripped.dropFirst(4)).trimmingCharacters(in: .whitespaces)

            // Subcommand routing.
            if body.hasPrefix("install ") {
                let argsString = String(body.dropFirst("install ".count))
                let result = await handlePipInstall(
                    argsString: argsString,
                    log: &log,
                    onProgress: onProgress
                )
                if result.installedAny { installedAnything = true }
                // Any successful Pyodide install pins the script to the
                // Pyodide runtime — the user clearly wants those packages.
                if result.routedToPyodide && runtimeHint == nil {
                    runtimeHint = .pyodide
                }
            } else if body.hasPrefix("uninstall ") {
                let argsString = String(body.dropFirst("uninstall ".count))
                await handlePipUninstall(argsString: argsString, log: &log, onProgress: onProgress)
            } else if body == "list" {
                await handlePipList(log: &log, onProgress: onProgress)
            } else if body.isEmpty {
                emit(
                    "usage: %pip {install|uninstall|list} [args]",
                    log: &log,
                    onProgress: onProgress
                )
            } else {
                emit(
                    "ERROR: unsupported %pip subcommand: \(body.split(separator: " ").first.map(String.init) ?? body)",
                    log: &log,
                    onProgress: onProgress
                )
            }
        }

        // After installing anything new, invalidate Python's import-finder
        // cache so the script can `import` the just-installed packages on
        // the very next line. (Only meaningful on CPython side — Pyodide's
        // micropip does this for us internally.)
        if installedAnything && runtimeHint != .pyodide {
            cleaned.insert("import importlib as _terrarium_il; _terrarium_il.invalidate_caches()", at: 0)
        }

        return MagicPreprocessResult(
            cleanedCode: cleaned.joined(separator: "\n"),
            log: log.joined(separator: "\n"),
            runtimeHint: runtimeHint
        )
    }

    // MARK: pip install

    private struct PipInstallSummary {
        var installedAny: Bool = false
        var routedToPyodide: Bool = false
    }

    private func handlePipInstall(
        argsString: String,
        log: inout [String],
        onProgress: ProgressCallback?
    ) async -> PipInstallSummary {
        let tokens = argsString.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        // Handle `-r requirements.txt` separately by reading the file and
        // queueing each non-comment line as its own package spec.
        var packages: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "-r" || t == "--requirement" {
                if i + 1 < tokens.count {
                    let path = tokens[i + 1]
                    let resolved = resolvedRequirementsPath(path)
                    if let contents = try? String(contentsOfFile: resolved, encoding: .utf8) {
                        for rline in contents.components(separatedBy: "\n") {
                            let trimmed = rline.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                                packages.append(trimmed)
                            }
                        }
                    } else {
                        emit("ERROR: could not read requirements file: \(path)", log: &log, onProgress: onProgress)
                    }
                    i += 2
                    continue
                }
            }
            if t.hasPrefix("-") {
                // Silently ignore other flags (-U, --upgrade, etc.) — the
                // simplified resolver doesn't support them yet, but we
                // don't want to abort a multi-package install over it.
                i += 1
                continue
            }
            packages.append(t)
            i += 1
        }

        var summary = PipInstallSummary()
        if packages.isEmpty {
            emit("usage: %pip install <package> [<package2> …]", log: &log, onProgress: onProgress)
            return summary
        }

        for raw in packages {
            let pkg = stripVersionSpecifier(raw)
            let routed = await installOnePackage(rawSpec: raw, name: pkg, log: &log, onProgress: onProgress)
            summary.installedAny = true
            if routed == .pyodide { summary.routedToPyodide = true }
        }
        return summary
    }

    /// Returns which runtime we ended up handing the install to.
    @discardableResult
    private func installOnePackage(
        rawSpec: String,
        name: String,
        log: inout [String],
        onProgress: ProgressCallback?
    ) async -> Runtime {
        let normalized = name.lowercased()

        // Already installed in the CPython side (bundled or user-installed)?
        if let existing = packageManager.installedPackages.first(where: { $0.name.lowercased() == normalized }) {
            let v = existing.version ?? "bundled"
            emit(
                "Requirement already satisfied: \(existing.name) (\(v)) in \(configuration.sitePackagesDirectory.path)",
                log: &log,
                onProgress: onProgress
            )
            return .cpython
        }

        // Route: native packages → Pyodide, everything else → CPython.
        let preferPyodide = Self.pyodideOnlyPackages.contains(normalized)
            || Self.pyodideOnlyPackages.contains(normalized.replacingOccurrences(of: "_", with: "-"))

        if preferPyodide {
            return await installOnPyodide(rawSpec: rawSpec, name: name, log: &log, onProgress: onProgress)
        }

        // CPython path — try it. If it fails because the manager flags it
        // as native, fall back to Pyodide automatically.
        emit("Collecting \(rawSpec)", log: &log, onProgress: onProgress)
        do {
            try await packageManager.install(packageName: name)
            if let installed = packageManager.installedPackages.first(where: { $0.name.lowercased() == normalized }) {
                let v = installed.version ?? "unknown"
                emit("Successfully installed \(installed.name)-\(v)", log: &log, onProgress: onProgress)
            } else {
                emit("Successfully installed \(name)", log: &log, onProgress: onProgress)
            }
            return .cpython
        } catch {
            // If the failure mentions native extensions, retry under Pyodide
            // before giving up. Lets us handle packages that aren't in our
            // static `pyodideOnlyPackages` list but turn out to need WASM.
            let msg = error.localizedDescription.lowercased()
            if msg.contains("native") || msg.contains("pure-python") {
                emit("  Falling back to Pyodide runtime", log: &log, onProgress: onProgress)
                return await installOnPyodide(rawSpec: rawSpec, name: name, log: &log, onProgress: onProgress)
            }
            emit(
                "ERROR: Could not install \(rawSpec) — \(error.localizedDescription)",
                log: &log,
                onProgress: onProgress
            )
            return .cpython
        }
    }

    private func installOnPyodide(
        rawSpec: String,
        name: String,
        log: inout [String],
        onProgress: ProgressCallback?
    ) async -> Runtime {
        // We don't append "Collecting" ourselves — Pyodide's host.js
        // emits its own progress lines including "Collecting <pkg>".
        var lines: [String] = []
        let result = await pyodide.installPackage(name) { line in
            lines.append(line)
            // Stream live if we have a callback; otherwise we'll dump
            // into `log` after the await resolves.
            onProgress?(line + "\n")
        }
        if onProgress == nil {
            log.append(contentsOf: lines)
        }
        if !result.ok, let err = result.error {
            let firstLine = err.split(separator: "\n").first.map(String.init) ?? err
            emit(
                "ERROR: Pyodide could not install \(rawSpec) — \(firstLine)",
                log: &log,
                onProgress: onProgress
            )
        }
        return .pyodide
    }

    // MARK: pip uninstall

    private func handlePipUninstall(
        argsString: String,
        log: inout [String],
        onProgress: ProgressCallback?
    ) async {
        let tokens = argsString
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.hasPrefix("-") }

        if tokens.isEmpty {
            emit("usage: %pip uninstall <package> [<package2> …]", log: &log, onProgress: onProgress)
            return
        }

        // Cache Pyodide list once per uninstall command (cheap, one IPC).
        let pyodideInstalled = await pyodide.listPackages()

        for pkg in tokens {
            let normalized = stripVersionSpecifier(pkg).lowercased()

            // CPython side
            if packageManager.installedPackages.contains(where: { $0.name.lowercased() == normalized }) {
                emit("Uninstalling \(pkg)…", log: &log, onProgress: onProgress)
                do {
                    try await packageManager.uninstall(packageName: stripVersionSpecifier(pkg))
                    emit("Successfully uninstalled \(pkg)", log: &log, onProgress: onProgress)
                } catch {
                    emit(
                        "ERROR: Could not uninstall \(pkg) — \(error.localizedDescription)",
                        log: &log,
                        onProgress: onProgress
                    )
                }
                continue
            }

            // Pyodide side
            if pyodideInstalled.contains(where: { $0.name.lowercased() == normalized }) {
                emit("Uninstalling \(pkg)…  (pyodide)", log: &log, onProgress: onProgress)
                let ok = await pyodide.uninstallPackage(stripVersionSpecifier(pkg))
                if ok {
                    emit("Successfully uninstalled \(pkg)", log: &log, onProgress: onProgress)
                } else {
                    emit("ERROR: Could not uninstall \(pkg) (pyodide)", log: &log, onProgress: onProgress)
                }
                continue
            }

            emit("WARNING: Skipping \(pkg) — not installed", log: &log, onProgress: onProgress)
        }
    }

    // MARK: pip list

    private func handlePipList(log: inout [String], onProgress: ProgressCallback?) async {
        let cpython = packageManager.installedPackages.map {
            (name: $0.name, version: $0.version ?? "—", source: $0.isBundled ? "bundled" : "user")
        }
        let pyodide = await self.pyodide.listPackages().map {
            (name: $0.name, version: $0.version, source: "pyodide")
        }
        let all = (cpython + pyodide).sorted { $0.name.lowercased() < $1.name.lowercased() }

        if all.isEmpty {
            emit("(no packages installed)", log: &log, onProgress: onProgress)
            return
        }
        let nameWidth = max(7, all.map { $0.name.count }.max() ?? 7)
        let versionWidth = max(7, all.map { $0.version.count }.max() ?? 7)
        let header = "Package".padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            + " " + "Version".padding(toLength: versionWidth, withPad: " ", startingAt: 0)
            + " Source"
        emit(header, log: &log, onProgress: onProgress)
        emit(String(repeating: "-", count: nameWidth) + " "
             + String(repeating: "-", count: versionWidth) + " ------",
             log: &log, onProgress: onProgress)
        for pkg in all {
            let line = pkg.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
                + " " + pkg.version.padding(toLength: versionWidth, withPad: " ", startingAt: 0)
                + " " + pkg.source
            emit(line, log: &log, onProgress: onProgress)
        }
    }

    // MARK: helpers

    /// Append `line` to the batched log AND/OR stream it live via
    /// `onProgress`. If `onProgress` is non-nil we ONLY stream — never
    /// batch — so callers that wired a callback never see duplicates.
    private func emit(_ line: String, log: inout [String], onProgress: ProgressCallback?) {
        if let onProgress {
            onProgress(line + "\n")
        } else {
            log.append(line)
        }
    }

    /// `requests==2.31.0` → `requests`, `numpy>=1.20` → `numpy`,
    /// `requests[security]` → `requests`, `pkg; python_version<'3.10'` → `pkg`.
    private func stripVersionSpecifier(_ spec: String) -> String {
        var name = spec
        for sep in ["==", ">=", "<=", "!=", "~=", ">", "<", "[", ";"] {
            if let range = name.range(of: sep) {
                name = String(name[..<range.lowerBound])
            }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// `-r requirements.txt` — resolve a path that may be relative to the
    /// app's working dir, the user-scripts dir, or absolute.
    private func resolvedRequirementsPath(_ raw: String) -> String {
        if raw.hasPrefix("/") { return raw }
        let cwd = FileManager.default.currentDirectoryPath
        return cwd + "/" + raw
    }

    /// Run a Python script from a file URL.
    /// - Parameters:
    ///   - fileURL: The URL of the Python file to execute.
    ///   - workingDirectory: Optional working directory for the script.
    ///   - timeout: Maximum execution time in seconds (default: 30).
    /// - Returns: The result of the execution.
    public func run(fileURL: URL, workingDirectory: URL? = nil, timeout: TimeInterval = 30) async -> PythonRunResult {
        guard isInitialized else {
            return PythonRunResult(
                exitCode: -1,
                stdout: "",
                stderr: "Python runtime not initialized. Call initialize() first.",
                exception: nil,
                durationMs: 0
            )
        }

        currentState = .executing
        defer { currentState = .ready }

        return await runtime.execute(fileURL: fileURL, workingDirectory: workingDirectory, timeout: timeout)
    }

    /// Run a saved Python script by its ID.
    /// - Parameters:
    ///   - scriptId: The unique identifier of the saved script.
    ///   - timeout: Maximum execution time in seconds.
    /// - Returns: The result of the execution.
    public func run(scriptId: UUID, timeout: TimeInterval = 30) async -> PythonRunResult {
        guard let script = scriptManager.scripts.first(where: { $0.id == scriptId }) else {
            return PythonRunResult(
                exitCode: -1,
                stdout: "",
                stderr: "Script not found with ID: \(scriptId)",
                exception: nil,
                durationMs: 0
            )
        }

        return await run(code: script.code, timeout: timeout)
    }

    // MARK: - Script Management Convenience

    /// Create and save a new Python script.
    /// - Parameters:
    ///   - name: The name of the script.
    ///   - code: The Python code.
    ///   - description: Optional description of what the script does.
    /// - Returns: The created script.
    @discardableResult
    public func createScript(name: String, code: String, description: String? = nil) async throws -> PythonScript {
        try await scriptManager.createScript(name: name, code: code, description: description)
    }

    /// Delete a script by its ID.
    public func deleteScript(id: UUID) async throws {
        try await scriptManager.deleteScript(id: id)
    }

    // MARK: - Package Management Convenience

    /// Install a Python package.
    /// - Parameter packageName: The name of the package to install.
    public func installPackage(_ packageName: String) async throws {
        try await packageManager.install(packageName: packageName)
    }

    /// Uninstall a Python package.
    /// - Parameter packageName: The name of the package to uninstall.
    public func uninstallPackage(_ packageName: String) async throws {
        try await packageManager.uninstall(packageName: packageName)
    }
}
