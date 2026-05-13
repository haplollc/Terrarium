//
//  PythonInterpreter.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

@preconcurrency import Foundation
@preconcurrency import Dispatch
import os.log

/// Logger for Python interpreter operations
private let interpreterLogger = Logger(subsystem: "com.terrarium.python", category: "PythonInterpreter")

/// The main Python interpreter implementation.
/// Uses PythonBridge for real Python execution when the framework is available,
/// with a fallback simulation mode for development/testing.
public final class PythonInterpreter: @unchecked Sendable {

    // MARK: - Properties

    private let configuration: PythonConfiguration
    private let lock = NSLock()
    private var _isInitialized = false
    private var securityHook: PythonSecurityHook?

    private var isInitialized: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isInitialized
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isInitialized = newValue
        }
    }

    /// Whether we're using the real Python runtime or simulation.
    public var isUsingRealPython: Bool {
        PythonBridge.shared.isPythonFrameworkAvailable
    }

    // MARK: - Initialization

    public init(configuration: PythonConfiguration) throws {
        self.configuration = configuration
    }

    /// Initialize the Python interpreter.
    /// Sets up the runtime, paths, stdout capture, and security hooks.
    public func initialize() async throws {
        interpreterLogger.info("🐍 PythonInterpreter.initialize() called")

        guard !isInitialized else {
            interpreterLogger.info("  Already initialized, returning early")
            return
        }

        // Get paths for initialization
        let stdlibPath = configuration.effectiveStdlibPath.path
        let sitePackagesPath = configuration.effectiveSitePackagesPath.path
        let bundledSitePackagesPath = configuration.bundledSitePackagesPath?.path
        let libDynloadPath = configuration.bundledLibDynloadPath?.path
        let resourcesPath = configuration.pythonHome?.path ?? configuration.baseDirectory.path

        interpreterLogger.info("  Paths:")
        interpreterLogger.info("    stdlibPath: \(stdlibPath)")
        interpreterLogger.info("    sitePackagesPath: \(sitePackagesPath)")
        interpreterLogger.info("    bundledSitePackagesPath: \(bundledSitePackagesPath ?? "none")")
        interpreterLogger.info("    libDynloadPath: \(libDynloadPath ?? "none")")
        interpreterLogger.info("    resourcesPath: \(resourcesPath)")

        // Initialize the Python bridge
        interpreterLogger.info("  Initializing PythonBridge...")
        try PythonBridge.shared.initialize(
            stdlibPath: stdlibPath,
            sitePackagesPath: sitePackagesPath,
            bundledSitePackagesPath: bundledSitePackagesPath,
            libDynloadPath: libDynloadPath,
            resourcesPath: resourcesPath
        )
        interpreterLogger.info("  ✅ PythonBridge initialized")

        // Install security hook to block dangerous modules at runtime
        interpreterLogger.info("  Installing security hook...")
        securityHook = PythonSecurityHook(blockedModules: configuration.blockedModules)
        try securityHook?.install()
        interpreterLogger.info("  ✅ Security hook installed")

        isInitialized = true
        interpreterLogger.info("  ✅ PythonInterpreter initialization complete")
    }

    // MARK: - Execution

    /// Execute Python code with the specified timeout.
    /// - Parameters:
    ///   - code: The Python code to execute
    ///   - timeout: Maximum execution time in seconds
    /// - Returns: The result of execution
    public func execute(code: String, timeout: TimeInterval) async -> PythonRunResult {
        let codePreview = code.prefix(100).replacingOccurrences(of: "\n", with: "\\n")
        interpreterLogger.info("🐍 PythonInterpreter.execute() called")
        interpreterLogger.info("  Code preview: \(codePreview)...")
        interpreterLogger.info("  Timeout: \(timeout)s")
        interpreterLogger.info("  isInitialized: \(self.isInitialized)")
        interpreterLogger.info("  isUsingRealPython: \(self.isUsingRealPython)")

        guard isInitialized else {
            interpreterLogger.error("  ❌ Interpreter not initialized")
            return PythonRunResult(
                exitCode: -1,
                stdout: "",
                stderr: "Interpreter not initialized",
                exception: nil,
                durationMs: 0
            )
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        // Pre-execution security check (defense in depth - also checked by Python hook)
        interpreterLogger.info("  Checking for blocked modules...")
        if let blockedModule = checkForBlockedModules(in: code) {
            interpreterLogger.warning("  ⚠️ Blocked module detected: \(blockedModule)")
            return PythonRunResult(
                exitCode: -1,
                stdout: "",
                stderr: "",
                exception: "ImportError: Module '\(blockedModule)' is blocked for security reasons",
                durationMs: Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            )
        }
        interpreterLogger.info("  No blocked modules found")

        // Execute with timeout
        interpreterLogger.info("  Starting execution with \(timeout)s timeout...")
        let result = await executeWithTimeout(code: code, timeout: timeout)
        let durationMs = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

        interpreterLogger.info("  ✅ Execution completed in \(durationMs)ms")
        interpreterLogger.info("  Exit code: \(result.exitCode)")
        interpreterLogger.info("  Stdout length: \(result.stdout.count)")
        interpreterLogger.info("  Stderr length: \(result.stderr.count)")
        if let exception = result.exception {
            interpreterLogger.error("  Exception: \(exception)")
        }

        return PythonRunResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr,
            exception: result.exception,
            durationMs: durationMs
        )
    }

    private func executeWithTimeout(code: String, timeout: TimeInterval) async -> (exitCode: Int, stdout: String, stderr: String, exception: String?) {
        interpreterLogger.info("    executeWithTimeout() starting...")

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let resumeLock = NSLock()

            interpreterLogger.info("    Creating work item...")

            // Create work item for execution
            let workItem = DispatchWorkItem { [weak self] in
                interpreterLogger.info("    Work item started executing")

                guard let self = self else {
                    interpreterLogger.error("    ❌ Self was deallocated")
                    // Can't call safeResume on nil self
                    resumeLock.lock()
                    if !hasResumed {
                        hasResumed = true
                        resumeLock.unlock()
                        continuation.resume(returning: (exitCode: -1, stdout: "", stderr: "", exception: "Interpreter deallocated"))
                    } else {
                        resumeLock.unlock()
                    }
                    return
                }

                // Execute using PythonBridge
                interpreterLogger.info("    Calling PythonBridge.execute()...")
                let result = PythonBridge.shared.execute(code: code)
                interpreterLogger.info("    PythonBridge.execute() returned")
                interpreterLogger.info("    success: \(result.success), stdout: \(result.stdout.count) chars")

                self.safeResume(
                    continuation: continuation,
                    hasResumed: &hasResumed,
                    lock: resumeLock,
                    result: (
                        exitCode: result.success ? 0 : 1,
                        stdout: result.stdout,
                        stderr: result.stderr,
                        exception: result.exception
                    )
                )
                interpreterLogger.info("    Work item completed")
            }

            interpreterLogger.info("    Dispatching work item to global queue...")
            DispatchQueue.global(qos: .userInitiated).async(execute: workItem)

            // Set up timeout handler
            interpreterLogger.info("    Setting up timeout handler for \(timeout)s...")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                interpreterLogger.warning("    ⏱️ Timeout handler fired after \(timeout)s")
                resumeLock.lock()
                if !hasResumed {
                    interpreterLogger.warning("    ⚠️ Work not completed, triggering timeout")
                    hasResumed = true
                    workItem.cancel()

                    // Interrupt Python execution
                    interpreterLogger.info("    Calling PythonBridge.interrupt()...")
                    PythonBridge.shared.interrupt()

                    resumeLock.unlock()
                    continuation.resume(returning: (
                        exitCode: -1,
                        stdout: "",
                        stderr: "",
                        exception: "ExecutionTimeout: Script exceeded \(Int(timeout)) second limit"
                    ))
                } else {
                    interpreterLogger.info("    Work already completed before timeout")
                    resumeLock.unlock()
                }
            }
        }
    }

    private func safeResume(
        continuation: CheckedContinuation<(exitCode: Int, stdout: String, stderr: String, exception: String?), Never>,
        hasResumed: inout Bool,
        lock: NSLock,
        result: (exitCode: Int, stdout: String, stderr: String, exception: String?)
    ) {
        lock.lock()
        if !hasResumed {
            hasResumed = true
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            lock.unlock()
        }
    }

    // MARK: - Security

    /// Check code for blocked module imports (pre-execution defense in depth).
    private func checkForBlockedModules(in code: String) -> String? {
        for module in configuration.blockedModules {
            // Check for various import patterns
            let patterns = [
                // Standard imports
                "import \(module)",
                "from \(module)",

                // Dynamic imports
                "__import__('\(module)'",
                "__import__(\"\(module)\"",

                // importlib
                "importlib.import_module('\(module)'",
                "importlib.import_module(\"\(module)\"",

                // exec/eval with import (basic check)
                "exec.*import \(module)",
                "eval.*import \(module)",
            ]

            for pattern in patterns {
                // Use regex for patterns with wildcards
                if pattern.contains(".*") {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                       regex.firstMatch(in: code, options: [], range: NSRange(code.startIndex..., in: code)) != nil {
                        return module
                    }
                } else if code.contains(pattern) {
                    return module
                }
            }

            // Also check for submodule access
            let submodulePattern = "\(module)."
            if code.contains("import \(submodulePattern)") || code.contains("from \(submodulePattern)") {
                return module
            }
        }

        return nil
    }

    // MARK: - Cleanup

    /// Finalize and clean up the Python interpreter.
    public func finalize() {
        guard isInitialized else { return }

        // Uninstall security hook
        securityHook?.uninstall()
        securityHook = nil

        // Note: We don't call PythonBridge.shared.finalize() here because
        // the bridge is a singleton that may be used by other components.
        // The bridge should be finalized at app termination.

        isInitialized = false
    }
}
