//
//  PythonError.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import Foundation

/// Errors that can occur during Python operations.
public enum PythonError: Error, Equatable, LocalizedError {
    case initializationFailed(String)
    case runtimeNotInitialized
    case executionFailed(String)
    case executionTimeout
    case scriptNotFound(UUID)
    case scriptWriteFailed(String)
    case scriptReadFailed(String)
    case packageInstallFailed(String)
    case packageUninstallFailed(String)
    case packageNotFound(String)
    case invalidPythonCode(String)
    case directoryCreationFailed(String)
    case stdlibNotFound
    case interpreterNotFound

    public var errorDescription: String? {
        switch self {
        case .initializationFailed(let reason):
            return "Python initialization failed: \(reason)"
        case .runtimeNotInitialized:
            return "Python runtime is not initialized"
        case .executionFailed(let reason):
            return "Python execution failed: \(reason)"
        case .executionTimeout:
            return "Python execution timed out"
        case .scriptNotFound(let id):
            return "Script not found: \(id)"
        case .scriptWriteFailed(let reason):
            return "Failed to write script: \(reason)"
        case .scriptReadFailed(let reason):
            return "Failed to read script: \(reason)"
        case .packageInstallFailed(let reason):
            return "Package installation failed: \(reason)"
        case .packageUninstallFailed(let reason):
            return "Package uninstallation failed: \(reason)"
        case .packageNotFound(let name):
            return "Package not found: \(name)"
        case .invalidPythonCode(let reason):
            return "Invalid Python code: \(reason)"
        case .directoryCreationFailed(let path):
            return "Failed to create directory: \(path)"
        case .stdlibNotFound:
            return "Python standard library not found"
        case .interpreterNotFound:
            return "Python interpreter not found"
        }
    }
}
