//
//  PythonRunResult.swift
//  Terrarium
//
//  Created by Claude Code on 2026-02-01.
//

import Foundation

/// The result of executing Python code.
public struct PythonRunResult: Equatable, Sendable {
    /// The exit code of the Python execution (0 = success).
    public let exitCode: Int

    /// The standard output captured during execution.
    public let stdout: String

    /// The standard error captured during execution.
    public let stderr: String

    /// The formatted exception/traceback if an error occurred.
    public let exception: String?

    /// The duration of execution in milliseconds.
    public let durationMs: Int

    /// Whether the execution was successful (exit code 0 and no exception).
    public var isSuccess: Bool {
        exitCode == 0 && exception == nil
    }

    /// The combined output (stdout + stderr).
    public var combinedOutput: String {
        var output = stdout
        if !stderr.isEmpty {
            if !output.isEmpty { output += "\n" }
            output += stderr
        }
        if let exception = exception {
            if !output.isEmpty { output += "\n" }
            output += exception
        }
        return output
    }

    /// Parse a JSON result from the output if it follows the KUZCO_RESULT convention.
    public func parseResult<T: Decodable>(as type: T.Type) -> T? {
        guard let resultLine = stdout.split(separator: "\n").first(where: { $0.hasPrefix("KUZCO_RESULT=") }) else {
            return nil
        }

        let jsonString = String(resultLine.dropFirst("KUZCO_RESULT=".count))
        guard let data = jsonString.data(using: .utf8) else { return nil }

        return try? JSONDecoder().decode(type, from: data)
    }

    public init(exitCode: Int, stdout: String, stderr: String, exception: String?, durationMs: Int) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.exception = exception
        self.durationMs = durationMs
    }

    /// A successful empty result.
    public static var empty: PythonRunResult {
        PythonRunResult(exitCode: 0, stdout: "", stderr: "", exception: nil, durationMs: 0)
    }
}
