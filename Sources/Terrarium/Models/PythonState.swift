//
//  PythonState.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import Foundation

/// Represents the current state of the Python runtime.
public enum PythonState: Equatable {
    case idle
    case initializing
    case ready
    case executing
    case failed(PythonError)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var isBusy: Bool {
        switch self {
        case .initializing, .executing:
            return true
        default:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .idle:
            return "Idle"
        case .initializing:
            return "Initializing..."
        case .ready:
            return "Ready"
        case .executing:
            return "Executing..."
        case .failed(let error):
            return "Failed: \(error.localizedDescription)"
        }
    }
}
