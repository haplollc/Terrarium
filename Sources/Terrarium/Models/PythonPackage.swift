//
//  PythonPackage.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import Foundation

/// Represents an installed or available Python package.
public struct PythonPackage: Identifiable, Codable, Equatable, Hashable {
    /// Unique identifier (usually the package name).
    public var id: String { name }

    /// The package name (e.g., "numpy", "requests").
    public let name: String

    /// The installed version, if any.
    public var version: String?

    /// Description of the package.
    public var description: String?

    /// Whether this package is installed.
    public var isInstalled: Bool

    /// Whether this is a pure Python package (no native extensions).
    public var isPurePython: Bool

    /// Whether this package is bundled with the app (pre-installed).
    public var isBundled: Bool

    /// The size of the package on disk in bytes.
    public var sizeBytes: Int64?

    /// When the package was installed.
    public var installedAt: Date?

    /// Dependencies of this package.
    public var dependencies: [String]

    public init(
        name: String,
        version: String? = nil,
        description: String? = nil,
        isInstalled: Bool = false,
        isPurePython: Bool = true,
        isBundled: Bool = false,
        sizeBytes: Int64? = nil,
        installedAt: Date? = nil,
        dependencies: [String] = []
    ) {
        self.name = name
        self.version = version
        self.description = description
        self.isInstalled = isInstalled
        self.isPurePython = isPurePython
        self.isBundled = isBundled
        self.sizeBytes = sizeBytes
        self.installedAt = installedAt
        self.dependencies = dependencies
    }
}

/// The installation state of a package.
public enum PackageInstallState: Equatable {
    case notInstalled
    case installing(progress: Double)
    case installed
    case bundled
    case uninstalling
    case failed(String)
}

/// Built-in and bundled packages for Terrarium.
public struct BuiltinPackages {

    // MARK: - Bundled Packages (Pre-installed, ~2.4MB total)

    /// Useful packages that come pre-installed with the app.
    /// These are pure-Python and cover common use cases.
    public static let bundled: [PythonPackage] = [

        // ═══════════════════════════════════════════════════════════════
        // HTTP & Networking
        // ═══════════════════════════════════════════════════════════════
        PythonPackage(
            name: "requests",
            version: "2.31.0",
            description: "HTTP library for Python - simple and elegant HTTP requests",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 65_000,
            dependencies: ["urllib3", "certifi", "charset-normalizer", "idna"]
        ),
        PythonPackage(
            name: "urllib3",
            version: "2.1.0",
            description: "HTTP client library with connection pooling",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 200_000,
            dependencies: []
        ),
        PythonPackage(
            name: "certifi",
            version: "2024.2.2",
            description: "Mozilla's SSL/TLS root certificates for HTTPS",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 280_000,
            dependencies: []
        ),
        PythonPackage(
            name: "charset-normalizer",
            version: "3.3.2",
            description: "Character encoding detection library",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 100_000,
            dependencies: []
        ),
        PythonPackage(
            name: "idna",
            version: "3.6",
            description: "Internationalized Domain Names in Applications (IDNA)",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 60_000,
            dependencies: []
        ),

        // ═══════════════════════════════════════════════════════════════
        // HTML, XML & Web Scraping
        // ═══════════════════════════════════════════════════════════════
        PythonPackage(
            name: "beautifulsoup4",
            version: "4.12.3",
            description: "HTML/XML parsing library for web scraping",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 150_000,
            dependencies: ["soupsieve"]
        ),
        PythonPackage(
            name: "soupsieve",
            version: "2.5",
            description: "CSS selector library for Beautiful Soup",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 35_000,
            dependencies: []
        ),
        PythonPackage(
            name: "html2text",
            version: "2024.2.26",
            description: "Convert HTML to clean Markdown text",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 30_000,
            dependencies: []
        ),
        PythonPackage(
            name: "xmltodict",
            version: "0.13.0",
            description: "Convert XML to Python dictionaries and back",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 10_000,
            dependencies: []
        ),

        // ═══════════════════════════════════════════════════════════════
        // Configuration & Data Formats
        // ═══════════════════════════════════════════════════════════════
        PythonPackage(
            name: "pyyaml",
            version: "6.0.1",
            description: "YAML parser and emitter",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 120_000,
            dependencies: []
        ),
        PythonPackage(
            name: "toml",
            version: "0.10.2",
            description: "TOML configuration file parser",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 12_000,
            dependencies: []
        ),
        PythonPackage(
            name: "json5",
            version: "0.9.14",
            description: "JSON5 parser - JSON with comments and trailing commas",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 18_000,
            dependencies: []
        ),
        PythonPackage(
            name: "dotenv",
            version: "0.21.1",
            description: "Read .env files into environment variables",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 20_000,
            dependencies: []
        ),
        PythonPackage(
            name: "markdown",
            version: "3.5.2",
            description: "Markdown to HTML converter",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 100_000,
            dependencies: []
        ),

        // ═══════════════════════════════════════════════════════════════
        // Date & Time
        // ═══════════════════════════════════════════════════════════════
        PythonPackage(
            name: "python-dateutil",
            version: "2.8.2",
            description: "Powerful date/time parsing - understands 'next friday', 'in 2 days'",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 150_000,
            dependencies: []
        ),
        PythonPackage(
            name: "arrow",
            version: "1.3.0",
            description: "Better dates and times - sensible API for datetime",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 100_000,
            dependencies: ["python-dateutil"]
        ),

        // ═══════════════════════════════════════════════════════════════
        // Text & Formatting
        // ═══════════════════════════════════════════════════════════════
        PythonPackage(
            name: "rich",
            version: "13.7.0",
            description: "Beautiful terminal formatting - tables, progress bars, syntax highlighting",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 250_000,
            dependencies: ["pygments", "markdown-it-py"]
        ),
        PythonPackage(
            name: "humanize",
            version: "4.9.0",
            description: "Human-readable data - '3 days ago', '1.2 GB', 'a moment ago'",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 30_000,
            dependencies: []
        ),
        PythonPackage(
            name: "textwrap3",
            version: "0.9.2",
            description: "Enhanced text wrapping utilities",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 8_000,
            dependencies: []
        ),
        PythonPackage(
            name: "colorama",
            version: "0.4.6",
            description: "Cross-platform colored terminal text",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 25_000,
            dependencies: []
        ),
        PythonPackage(
            name: "python-slugify",
            version: "8.0.4",
            description: "Generate URL-friendly slugs from text",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 15_000,
            dependencies: []
        ),

        // ═══════════════════════════════════════════════════════════════
        // Progress & UI
        // ═══════════════════════════════════════════════════════════════
        PythonPackage(
            name: "tqdm",
            version: "4.66.2",
            description: "Fast, extensible progress bars for loops and CLI",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 80_000,
            dependencies: []
        ),

        // ═══════════════════════════════════════════════════════════════
        // Validation & Parsing
        // ═══════════════════════════════════════════════════════════════
        PythonPackage(
            name: "validators",
            version: "0.22.0",
            description: "Validate emails, URLs, IPs, UUIDs, and more",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 30_000,
            dependencies: []
        ),
        PythonPackage(
            name: "semver",
            version: "3.0.2",
            description: "Semantic version parsing and comparison",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 20_000,
            dependencies: []
        ),
        PythonPackage(
            name: "packaging",
            version: "24.0",
            description: "Parse version numbers, requirements, and markers",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 50_000,
            dependencies: []
        ),
        PythonPackage(
            name: "pyparsing",
            version: "3.1.1",
            description: "Create and execute simple grammars",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 45_000,
            dependencies: []
        ),

        // ═══════════════════════════════════════════════════════════════
        // Utilities
        // ═══════════════════════════════════════════════════════════════
        PythonPackage(
            name: "boltons",
            version: "24.0.0",
            description: "200+ utility functions - caching, data structures, iteration, and more",
            isInstalled: true,
            isPurePython: true,
            isBundled: true,
            sizeBytes: 200_000,
            dependencies: []
        ),
    ]

    // MARK: - Standard Library Modules (Always Available)

    /// Key modules from Python's standard library that are always available.
    /// These don't need to be installed - they come with Python itself.
    public static let standardLibraryModules: [String: String] = [
        "json": "JSON encoding and decoding",
        "csv": "CSV file reading and writing",
        "math": "Mathematical functions",
        "random": "Generate pseudo-random numbers",
        "datetime": "Date and time handling",
        "re": "Regular expression operations",
        "collections": "Specialized container datatypes",
        "itertools": "Functions for efficient looping",
        "functools": "Higher-order functions and operations",
        "pathlib": "Object-oriented filesystem paths",
        "urllib.parse": "URL parsing utilities",
        "base64": "Base16, Base32, Base64 encoding",
        "hashlib": "Secure hash and message digests",
        "sqlite3": "SQLite database interface",
        "html": "HTML parsing and entity handling",
        "xml.etree": "XML parsing and creation",
        "configparser": "Configuration file parser",
        "argparse": "Command-line argument parsing",
        "logging": "Logging facility",
        "unittest": "Unit testing framework",
        "pprint": "Pretty-print data structures",
        "textwrap": "Text wrapping and filling",
        "difflib": "Helpers for computing deltas",
        "typing": "Type hints support",
        "dataclasses": "Data Classes",
        "enum": "Enumeration support",
        "uuid": "UUID generation",
        "secrets": "Secure random numbers",
        "statistics": "Statistical functions",
        "fractions": "Rational numbers",
        "decimal": "Fixed and floating point math",
    ]

    // MARK: - Recommended Packages (Can be installed)

    /// Pure-Python packages recommended for installation (not bundled to save space).
    public static let recommended: [PythonPackage] = [
        PythonPackage(
            name: "jinja2",
            version: nil,
            description: "Template engine for Python",
            isPurePython: true,
            sizeBytes: 150_000,
            dependencies: ["markupsafe"]
        ),
        PythonPackage(
            name: "click",
            version: nil,
            description: "Command line interface toolkit",
            isPurePython: true,
            sizeBytes: 80_000,
            dependencies: []
        ),
        PythonPackage(
            name: "attrs",
            version: nil,
            description: "Classes without boilerplate",
            isPurePython: true,
            sizeBytes: 60_000,
            dependencies: []
        ),
        PythonPackage(
            name: "more-itertools",
            version: nil,
            description: "Extended itertools functions",
            isPurePython: true,
            sizeBytes: 100_000,
            dependencies: []
        ),
        PythonPackage(
            name: "tabulate",
            version: nil,
            description: "Pretty-print tabular data",
            isPurePython: true,
            sizeBytes: 30_000,
            dependencies: []
        ),
        PythonPackage(
            name: "pydantic",
            version: nil,
            description: "Data validation using Python type hints",
            isPurePython: true,
            sizeBytes: 200_000,
            dependencies: []
        ),
    ]

    /// Packages that require native extensions and cannot work on iOS.
    public static let nativeExtensionPackages: Set<String> = [
        "numpy",
        "pandas",
        "scipy",
        "matplotlib",
        "pillow",
        "opencv-python",
        "tensorflow",
        "torch",
        "scikit-learn",
        "lxml",
        "cryptography",
        "psycopg2",
        "mysqlclient",
        "grpcio",
        "pyzmq",
        "msgpack",
        "ujson",
        "aiohttp",
    ]

    public static func requiresNativeExtensions(_ packageName: String) -> Bool {
        nativeExtensionPackages.contains(packageName.lowercased())
    }

    /// Get all bundled package names for quick lookup.
    public static var bundledPackageNames: Set<String> {
        Set(bundled.map { $0.name.lowercased() })
    }

    /// Check if a package is bundled.
    public static func isBundled(_ packageName: String) -> Bool {
        bundledPackageNames.contains(packageName.lowercased())
    }
}
