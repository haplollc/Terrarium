//
//  PythonConfiguration.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import Foundation

/// Configuration for the Python runtime.
public struct PythonConfiguration {
    /// The base directory for all Python-related files.
    public let baseDirectory: URL

    /// Directory for storing generated Python scripts.
    public var scriptsDirectory: URL {
        baseDirectory.appendingPathComponent("scripts", isDirectory: true)
    }

    /// Directory for installed packages (site-packages).
    public var sitePackagesDirectory: URL {
        baseDirectory.appendingPathComponent("site-packages", isDirectory: true)
    }

    /// Directory for the Python standard library.
    public var stdlibDirectory: URL {
        baseDirectory.appendingPathComponent("stdlib", isDirectory: true)
    }

    /// Directory for temporary files during execution.
    public var tempDirectory: URL {
        baseDirectory.appendingPathComponent("temp", isDirectory: true)
    }

    /// Directory for package downloads.
    public var downloadsDirectory: URL {
        baseDirectory.appendingPathComponent("downloads", isDirectory: true)
    }

    /// The metadata file that stores script and package info.
    public var metadataFile: URL {
        baseDirectory.appendingPathComponent("metadata.json")
    }

    /// Default timeout for Python execution in seconds.
    public var defaultTimeout: TimeInterval

    /// Maximum allowed execution time in seconds.
    public var maxTimeout: TimeInterval

    /// Maximum allowed memory usage in bytes (advisory).
    public var maxMemoryBytes: Int64

    /// Whether to capture stdout during execution.
    public var captureStdout: Bool

    /// Whether to capture stderr during execution.
    public var captureStderr: Bool

    /// Python version to use.
    public var pythonVersion: String

    /// Modules that are blocked from import for security.
    public var blockedModules: Set<String>

    // MARK: - Framework Paths

    /// Path to the bundled Python standard library from Python.xcframework.
    /// This is the python-stdlib directory extracted from BeeWare's iOS support package.
    public var bundledStdlibPath: URL? {
        Bundle.main.url(forResource: "python-stdlib", withExtension: nil)
    }

    /// Path to the bundled site-packages with pre-installed pure-Python packages.
    public var bundledSitePackagesPath: URL? {
        Bundle.main.url(forResource: "site-packages", withExtension: nil)
    }

    /// Path to the bundled lib-dynload with Python extension modules (.so files).
    public var bundledLibDynloadPath: URL? {
        Bundle.main.url(forResource: "lib-dynload", withExtension: nil)
    }

    /// Path to the Python.xcframework (resolved at runtime).
    public var pythonFrameworkPath: URL? {
        // The framework is linked at build time, so we don't need the path at runtime
        // This is primarily for debugging and verification
        Bundle.main.privateFrameworksURL?.appendingPathComponent("Python.framework")
    }

    /// Whether the real Python framework is available.
    public var isPythonFrameworkAvailable: Bool {
        #if canImport(Python)
        return true
        #else
        return false
        #endif
    }

    /// Get the effective stdlib path (bundled or user directory).
    public var effectiveStdlibPath: URL {
        bundledStdlibPath ?? stdlibDirectory
    }

    /// Get the effective site-packages path (bundled + user packages).
    /// User-installed packages go to sitePackagesDirectory.
    public var effectiveSitePackagesPath: URL {
        sitePackagesDirectory
    }

    /// All Python paths that should be added to sys.path.
    public var pythonPaths: [URL] {
        var paths: [URL] = []

        // Bundled stdlib first
        if let bundledStdlib = bundledStdlibPath {
            paths.append(bundledStdlib)
        }

        // User stdlib directory (for any custom additions)
        paths.append(stdlibDirectory)

        // Bundled site-packages
        if let bundledSite = bundledSitePackagesPath {
            paths.append(bundledSite)
        }

        // User site-packages (for pip-installed packages)
        paths.append(sitePackagesDirectory)

        return paths
    }

    /// The Python home directory for Py_SetPythonHome.
    public var pythonHome: URL? {
        bundledStdlibPath?.deletingLastPathComponent()
    }

    /// The default configuration.
    public static var `default`: PythonConfiguration {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("Terrarium", isDirectory: true)

        return PythonConfiguration(
            baseDirectory: baseDir,
            defaultTimeout: 30,
            maxTimeout: 300,
            maxMemoryBytes: 256 * 1024 * 1024, // 256 MB
            captureStdout: true,
            captureStderr: true,
            pythonVersion: "3.13",
            blockedModules: Self.defaultBlockedModules
        )
    }

    /// Default set of blocked modules for security.
    /// Note: iOS sandbox already restricts file system and network access,
    /// so we allow os/socket for compatibility with common packages like requests.
    public static var defaultBlockedModules: Set<String> {
        [
            // Process execution (doesn't work on iOS anyway, but block for safety)
            "subprocess",

            // Server modules (we allow client networking but not servers)
            "socketserver",
            "http.server",

            // Legacy/dangerous network protocols
            "ftplib",
            "smtplib",
            "poplib",
            "imaplib",
            "nntplib",
            "telnetlib",

            // Process/threading that could cause issues
            "multiprocessing",

            // Low-level/unsafe - these can bypass Python's safety
            "ctypes",
            "cffi",
            "_ctypes",

            // Code execution helpers
            "code",
            "codeop",
            "compileall",

            // Package management (not useful on iOS)
            "distutils",
            "ensurepip",
            "pip",

            // Debugging that could leak info
            "pdb",
            "bdb",
            "trace",

            // Platform-specific (Windows)
            "nt",
            "msvcrt",
            "winreg",
            "_winapi",
        ]
    }

    public init(
        baseDirectory: URL,
        defaultTimeout: TimeInterval = 30,
        maxTimeout: TimeInterval = 300,
        maxMemoryBytes: Int64 = 256 * 1024 * 1024,
        captureStdout: Bool = true,
        captureStderr: Bool = true,
        pythonVersion: String = "3.13",
        blockedModules: Set<String>? = nil
    ) {
        self.baseDirectory = baseDirectory
        self.defaultTimeout = defaultTimeout
        self.maxTimeout = maxTimeout
        self.maxMemoryBytes = maxMemoryBytes
        self.captureStdout = captureStdout
        self.captureStderr = captureStderr
        self.pythonVersion = pythonVersion
        self.blockedModules = blockedModules ?? Self.defaultBlockedModules
    }

    /// Ensure all required directories exist.
    public func ensureDirectoriesExist() throws {
        let directories = [
            baseDirectory,
            scriptsDirectory,
            sitePackagesDirectory,
            stdlibDirectory,
            tempDirectory,
            downloadsDirectory
        ]

        let fm = FileManager.default
        for directory in directories {
            if !fm.fileExists(atPath: directory.path) {
                do {
                    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                } catch {
                    throw PythonError.directoryCreationFailed(directory.path)
                }
            }
        }
    }

    /// Verify that required Python resources are available.
    public func verifyResources() -> (available: Bool, missingComponents: [String]) {
        var missing: [String] = []

        #if !canImport(Python)
        missing.append("Python.xcframework")
        #endif

        if bundledStdlibPath == nil {
            missing.append("python-stdlib bundle")
        }

        return (missing.isEmpty, missing)
    }
}
