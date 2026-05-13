//
//  PythonRuntimeService.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import Foundation
import Combine

/// Service responsible for executing Python code.
/// This implementation uses an embedded Python interpreter when available,
/// or falls back to a sandboxed execution approach.
@MainActor
public final class PythonRuntimeService: ObservableObject {

    // MARK: - Published State

    @Published public private(set) var isInitialized: Bool = false
    @Published public private(set) var currentExecution: ExecutionInfo?
    @Published public private(set) var executionHistory: [ExecutionRecord] = []

    // MARK: - Properties

    private let configuration: PythonConfiguration
    private let executionQueue: DispatchQueue
    private var pythonInterpreter: PythonInterpreter?

    // Keep last 50 execution records
    private let maxHistorySize = 50

    // MARK: - Initialization

    public init(configuration: PythonConfiguration) {
        self.configuration = configuration
        self.executionQueue = DispatchQueue(label: "com.terrarium.python.runtime", qos: .userInitiated)
    }

    /// Initialize the Python interpreter.
    public func initialize() async throws {
        guard !isInitialized else { return }

        // Initialize the Python interpreter
        pythonInterpreter = try PythonInterpreter(configuration: configuration)
        try await pythonInterpreter?.initialize()

        isInitialized = true
    }

    // MARK: - Execution

    /// Execute Python code string.
    public func execute(code: String, timeout: TimeInterval) async -> PythonRunResult {
        let startTime = Date()
        let executionId = UUID()

        currentExecution = ExecutionInfo(id: executionId, startTime: startTime, code: code)

        defer {
            currentExecution = nil
        }

        guard let interpreter = pythonInterpreter else {
            return PythonRunResult(
                exitCode: -1,
                stdout: "",
                stderr: "Python interpreter not initialized",
                exception: nil,
                durationMs: 0
            )
        }

        let result = await interpreter.execute(code: code, timeout: timeout)

        // Record execution
        let record = ExecutionRecord(
            id: executionId,
            code: code,
            result: result,
            timestamp: startTime
        )
        addToHistory(record)

        return result
    }

    /// Execute a Python file.
    public func execute(fileURL: URL, workingDirectory: URL?, timeout: TimeInterval) async -> PythonRunResult {
        // Read the file contents
        let code: String
        do {
            code = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return PythonRunResult(
                exitCode: -1,
                stdout: "",
                stderr: "Failed to read file: \(error.localizedDescription)",
                exception: nil,
                durationMs: 0
            )
        }

        // Execute the code
        return await execute(code: code, timeout: timeout)
    }

    // MARK: - History Management

    private func addToHistory(_ record: ExecutionRecord) {
        executionHistory.insert(record, at: 0)
        if executionHistory.count > maxHistorySize {
            executionHistory.removeLast()
        }
    }

    public func clearHistory() {
        executionHistory.removeAll()
    }
}

// MARK: - Supporting Types

public struct ExecutionInfo: Identifiable, Equatable {
    public let id: UUID
    public let startTime: Date
    public let code: String

    public var elapsedTime: TimeInterval {
        Date().timeIntervalSince(startTime)
    }
}

public struct ExecutionRecord: Identifiable, Equatable {
    public let id: UUID
    public let code: String
    public let result: PythonRunResult
    public let timestamp: Date

    public var codePreview: String {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= 3 {
            return code
        }
        return lines.prefix(3).joined(separator: "\n") + "\n..."
    }
}
