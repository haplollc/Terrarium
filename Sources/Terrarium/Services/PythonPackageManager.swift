//
//  PythonPackageManager.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import Foundation
import Combine
import ZIPFoundation

/// Manages Python package installation and removal.
@MainActor
public final class PythonPackageManager: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var installedPackages: [PythonPackage] = []
    @Published public private(set) var availablePackages: [PythonPackage] = []
    @Published public private(set) var packageStates: [String: PackageInstallState] = [:]
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var lastError: PythonError?

    // MARK: - Properties

    private let configuration: PythonConfiguration
    private let fileManager = FileManager.default
    private let session = URLSession.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var packagesMetadataURL: URL {
        configuration.baseDirectory.appendingPathComponent("packages.json")
    }

    // MARK: - Initialization

    public init(configuration: PythonConfiguration) {
        self.configuration = configuration
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        // Initialize with bundled packages as installed
        installedPackages = BuiltinPackages.bundled

        // Mark bundled packages in state
        for pkg in BuiltinPackages.bundled {
            packageStates[pkg.name.lowercased()] = .bundled
        }

        // Initialize available packages with recommendations
        availablePackages = BuiltinPackages.recommended
    }

    // MARK: - Loading

    /// Load installed packages from disk.
    public func loadInstalledPackages() async {
        isLoading = true
        defer { isLoading = false }

        // Start with bundled packages
        var packages = BuiltinPackages.bundled
        for pkg in packages {
            packageStates[pkg.name.lowercased()] = .bundled
        }

        do {
            // Load user-installed packages
            if fileManager.fileExists(atPath: packagesMetadataURL.path) {
                let data = try Data(contentsOf: packagesMetadataURL)
                let metadata = try decoder.decode(PackagesMetadata.self, from: data)

                // Add user-installed packages (skip if already bundled)
                for pkg in metadata.packages {
                    if !BuiltinPackages.isBundled(pkg.name) {
                        var p = pkg
                        p.isInstalled = true
                        packages.append(p)
                        packageStates[pkg.name.lowercased()] = .installed
                    }
                }
            }

            installedPackages = packages

            // Update available packages with install status
            updateAvailablePackagesStatus()

            lastError = nil
        } catch {
            lastError = PythonError.packageInstallFailed(error.localizedDescription)
            installedPackages = packages // Still show bundled packages
        }
    }

    private func saveInstalledPackages() async throws {
        let metadata = PackagesMetadata(packages: installedPackages, lastModified: Date())
        let data = try encoder.encode(metadata)
        try data.write(to: packagesMetadataURL)
    }

    private func updateAvailablePackagesStatus() {
        let installedNames = Set(installedPackages.map { $0.name.lowercased() })
        availablePackages = availablePackages.map { pkg in
            var p = pkg
            p.isInstalled = installedNames.contains(pkg.name.lowercased())
            return p
        }
    }

    // MARK: - Installation

    /// Install a Python package.
    /// - Parameter packageName: The name of the package (e.g., "requests").
    public func install(packageName: String) async throws {
        let normalizedName = packageName.lowercased().trimmingCharacters(in: .whitespaces)

        // Check if already installed
        if installedPackages.contains(where: { $0.name.lowercased() == normalizedName }) {
            return
        }

        // Check if package requires native extensions
        if BuiltinPackages.requiresNativeExtensions(normalizedName) {
            throw PythonError.packageInstallFailed(
                "Package '\(packageName)' requires native extensions and cannot be installed on iOS. " +
                "Only pure-Python packages are supported."
            )
        }

        packageStates[normalizedName] = .installing(progress: 0)

        do {
            // Fetch package info from PyPI
            let packageInfo = try await fetchPackageInfo(name: normalizedName)
            packageStates[normalizedName] = .installing(progress: 0.2)

            // Download the package
            let downloadedURL = try await downloadPackage(info: packageInfo)
            packageStates[normalizedName] = .installing(progress: 0.6)

            // Extract to site-packages
            try await extractPackage(from: downloadedURL, info: packageInfo)
            packageStates[normalizedName] = .installing(progress: 0.9)

            // Add to installed packages
            var package = PythonPackage(
                name: packageInfo.name,
                version: packageInfo.version,
                description: packageInfo.description,
                isInstalled: true,
                isPurePython: true,
                installedAt: Date(),
                dependencies: packageInfo.dependencies
            )

            // Calculate size
            let packageDir = configuration.sitePackagesDirectory.appendingPathComponent(normalizedName)
            package.sizeBytes = calculateDirectorySize(at: packageDir)

            installedPackages.append(package)
            try await saveInstalledPackages()
            updateAvailablePackagesStatus()

            packageStates[normalizedName] = .installed

        } catch {
            packageStates[normalizedName] = .failed(error.localizedDescription)
            throw PythonError.packageInstallFailed(error.localizedDescription)
        }
    }

    /// Uninstall a Python package.
    public func uninstall(packageName: String) async throws {
        let normalizedName = packageName.lowercased()

        // Prevent uninstalling bundled packages
        if BuiltinPackages.isBundled(normalizedName) {
            throw PythonError.packageUninstallFailed(
                "'\(packageName)' is a bundled package and cannot be uninstalled."
            )
        }

        guard let index = installedPackages.firstIndex(where: { $0.name.lowercased() == normalizedName }) else {
            throw PythonError.packageNotFound(packageName)
        }

        packageStates[normalizedName] = .uninstalling

        do {
            // Remove package directory
            let packageDir = configuration.sitePackagesDirectory.appendingPathComponent(normalizedName)
            if fileManager.fileExists(atPath: packageDir.path) {
                try fileManager.removeItem(at: packageDir)
            }

            installedPackages.remove(at: index)
            try await saveInstalledPackages()
            updateAvailablePackagesStatus()

            packageStates[normalizedName] = .notInstalled

        } catch {
            packageStates[normalizedName] = .failed(error.localizedDescription)
            throw PythonError.packageUninstallFailed(error.localizedDescription)
        }
    }

    // MARK: - PyPI Integration

    private func fetchPackageInfo(name: String) async throws -> PyPIPackageInfo {
        let url = URL(string: "https://pypi.org/pypi/\(name)/json")!

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw PythonError.packageNotFound(name)
        }

        let pypiResponse = try JSONDecoder().decode(PyPIResponse.self, from: data)

        return PyPIPackageInfo(
            name: pypiResponse.info.name,
            version: pypiResponse.info.version,
            description: pypiResponse.info.summary,
            downloadURL: findPureWheelURL(in: pypiResponse.urls) ?? pypiResponse.urls.first?.url,
            dependencies: parseRequiresDist(pypiResponse.info.requires_dist)
        )
    }

    private func findPureWheelURL(in urls: [PyPIURL]) -> String? {
        // Prefer pure Python wheels (py3-none-any)
        for url in urls {
            if url.packagetype == "bdist_wheel" &&
               (url.filename.contains("py3-none-any") || url.filename.contains("py2.py3-none-any")) {
                return url.url
            }
        }

        // Fall back to sdist
        return urls.first(where: { $0.packagetype == "sdist" })?.url
    }

    private func parseRequiresDist(_ requiresDist: [String]?) -> [String] {
        guard let requires = requiresDist else { return [] }

        return requires.compactMap { req -> String? in
            // Parse requirement string like "requests (>=2.0)" or "typing-extensions ; python_version < '3.8'"
            let parts = req.components(separatedBy: CharacterSet(charactersIn: " ;(<>="))
            return parts.first?.trimmingCharacters(in: .whitespaces)
        }
    }

    private func downloadPackage(info: PyPIPackageInfo) async throws -> URL {
        guard let downloadURLString = info.downloadURL,
              let downloadURL = URL(string: downloadURLString) else {
            throw PythonError.packageInstallFailed("No download URL available for \(info.name)")
        }

        let (tempURL, _) = try await session.download(from: downloadURL)

        // Move to our downloads directory
        let destinationURL = configuration.downloadsDirectory.appendingPathComponent("\(info.name)-\(info.version).whl")
        try? fileManager.removeItem(at: destinationURL)
        try fileManager.moveItem(at: tempURL, to: destinationURL)

        return destinationURL
    }

    /// Extract a wheel file to site-packages.
    /// Wheels are ZIP archives with a specific structure.
    private func extractPackage(from archiveURL: URL, info: PyPIPackageInfo) async throws {
        let sitePackages = configuration.sitePackagesDirectory

        // Create a temporary extraction directory
        let tempExtractDir = configuration.tempDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)

        defer {
            // Clean up temp directory
            try? fileManager.removeItem(at: tempExtractDir)
        }

        // Extract the wheel (which is a ZIP file)
        try fileManager.unzipItem(at: archiveURL, to: tempExtractDir)

        // Find and move package directories to site-packages
        // Wheel structure: package_name/, package_name.dist-info/, etc.
        let extractedContents = try fileManager.contentsOfDirectory(at: tempExtractDir, includingPropertiesForKeys: [.isDirectoryKey])

        for itemURL in extractedContents {
            let isDirectory = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }

            let itemName = itemURL.lastPathComponent

            // Skip __pycache__ directories
            if itemName == "__pycache__" { continue }

            // Determine destination
            let destinationURL = sitePackages.appendingPathComponent(itemName)

            // Remove existing version if present
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            // Move to site-packages
            try fileManager.moveItem(at: itemURL, to: destinationURL)
        }

        // Also handle single-file packages (e.g., six.py)
        let pyFiles = extractedContents.filter { $0.pathExtension == "py" }
        for pyFile in pyFiles {
            let destinationURL = sitePackages.appendingPathComponent(pyFile.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: pyFile, to: destinationURL)
        }

        // Clean up the downloaded wheel file
        try? fileManager.removeItem(at: archiveURL)
    }

    /// Extract a source distribution (.tar.gz) to site-packages.
    /// This is a fallback when no wheel is available.
    private func extractSourceDistribution(from archiveURL: URL, info: PyPIPackageInfo) async throws {
        // For source distributions, we need to:
        // 1. Extract the tarball
        // 2. Find the package directory (usually named like package_name/)
        // 3. Copy Python files to site-packages

        // This is a simplified implementation - real pip does much more
        let sitePackages = configuration.sitePackagesDirectory
        let packageDir = sitePackages.appendingPathComponent(info.name.lowercased().replacingOccurrences(of: "-", with: "_"))

        // Create package directory
        try fileManager.createDirectory(at: packageDir, withIntermediateDirectories: true)

        // For now, create a placeholder - full sdist support would require
        // running setup.py or parsing pyproject.toml
        let initURL = packageDir.appendingPathComponent("__init__.py")
        let initContent = """
        # Package: \(info.name) v\(info.version)
        # Note: This package was installed from source distribution.
        # Some features may not be available.
        __version__ = "\(info.version)"
        """
        try initContent.write(to: initURL, atomically: true, encoding: .utf8)
    }

    private func calculateDirectorySize(at url: URL) -> Int64 {
        var size: Int64 = 0
        let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])

        while let fileURL = enumerator?.nextObject() as? URL {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size += Int64(fileSize)
            }
        }

        return size
    }

    // MARK: - Search

    /// Search for packages on PyPI.
    public func searchPackages(query: String) async throws -> [PythonPackage] {
        // PyPI doesn't have a simple search API, so we'll return filtered recommendations
        // In a real implementation, you might use a different approach

        let lowercasedQuery = query.lowercased()
        let filtered = availablePackages.filter {
            $0.name.lowercased().contains(lowercasedQuery) ||
            ($0.description?.lowercased().contains(lowercasedQuery) ?? false)
        }

        return filtered
    }
}

// MARK: - PyPI Response Models

private struct PyPIResponse: Codable {
    let info: PyPIInfo
    let urls: [PyPIURL]
}

private struct PyPIInfo: Codable {
    let name: String
    let version: String
    let summary: String?
    let requires_dist: [String]?
}

private struct PyPIURL: Codable {
    let filename: String
    let url: String
    let packagetype: String
}

private struct PyPIPackageInfo {
    let name: String
    let version: String
    let description: String?
    let downloadURL: String?
    let dependencies: [String]
}

private struct PackagesMetadata: Codable {
    var packages: [PythonPackage]
    var lastModified: Date
}
