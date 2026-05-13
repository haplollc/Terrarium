//
//  StdoutCapture.swift
//  Terrarium
//
//  Captures Python stdout and stderr output by replacing sys.stdout/sys.stderr
//  with custom Python objects that store output in memory.
//

import Foundation
import os.log

#if canImport(CPython)
import CPython
#endif

/// Logger for stdout capture operations
private let captureLogger = Logger(subsystem: "com.terrarium.python", category: "StdoutCapture")

/// Captures stdout and stderr from Python execution.
/// Installs custom Python objects to replace sys.stdout and sys.stderr.
public final class StdoutCapture {

    // MARK: - Properties

    private var capturedStdout: String = ""
    private var capturedStderr: String = ""
    private var isInstalled: Bool = false

    #if canImport(CPython)
    private var originalStdout: UnsafeMutablePointer<PyObject>?
    private var originalStderr: UnsafeMutablePointer<PyObject>?
    private var captureModule: UnsafeMutablePointer<PyObject>?
    #endif

    // MARK: - Python Capture Class Code

    private let captureClassCode = """
import sys
from io import StringIO

class _TerrariumCapturedOutput:
    def __init__(self):
        self._buffer = StringIO()
        self.encoding = 'utf-8'

    def write(self, text):
        self._buffer.write(text)

    def flush(self):
        pass

    def getvalue(self):
        return self._buffer.getvalue()

    def clear(self):
        self._buffer = StringIO()

    def fileno(self):
        return -1

    def isatty(self):
        return False

# Create global capture instances
_terrarium_stdout = _TerrariumCapturedOutput()
_terrarium_stderr = _TerrariumCapturedOutput()
"""

    // MARK: - Initialization

    public init() {}

    // MARK: - Installation

    /// Install the stdout/stderr capture mechanism.
    /// This replaces sys.stdout and sys.stderr with our custom capture objects.
    public func install() throws {
        guard !isInstalled else { return }

        #if canImport(CPython)
        try installPythonCapture()
        #endif

        isInstalled = true
    }

    #if canImport(CPython)
    private func installPythonCapture() throws {
        captureLogger.info("🔧 Installing Python stdout/stderr capture...")

        // Store original stdout/stderr
        captureLogger.info("  Importing sys module...")
        let sysModule = PyImport_ImportModule("sys")
        guard sysModule != nil else {
            captureLogger.error("  ❌ Failed to import sys")
            if PyErr_Occurred() != nil {
                PyErr_Print()
                PyErr_Clear()
            }
            throw PythonError.initializationFailed("Failed to import sys for capture")
        }
        defer { Py_DecRef(sysModule) }
        captureLogger.info("  ✅ sys module imported")

        originalStdout = PyObject_GetAttrString(sysModule, "stdout")
        originalStderr = PyObject_GetAttrString(sysModule, "stderr")
        captureLogger.info("  Stored original stdout/stderr (stdout: \(self.originalStdout != nil), stderr: \(self.originalStderr != nil))")

        // Execute capture class code in __main__
        captureLogger.info("  Getting __main__ module...")
        let mainModule = PyImport_AddModule("__main__")
        guard mainModule != nil else {
            captureLogger.error("  ❌ Failed to get __main__")
            throw PythonError.initializationFailed("Failed to get __main__ for capture")
        }

        let globalDict = PyModule_GetDict(mainModule)
        guard globalDict != nil else {
            captureLogger.error("  ❌ Failed to get globals")
            throw PythonError.initializationFailed("Failed to get globals for capture")
        }
        captureLogger.info("  ✅ Got __main__ and global dict")

        // Run the capture class definition
        captureLogger.info("  Running capture class definition...")
        captureLogger.info("  Capture code length: \(self.captureClassCode.count) chars")

        let result = PyRun_String(
            captureClassCode,
            Py_file_input,
            globalDict,
            globalDict
        )

        if result == nil {
            captureLogger.error("  ❌ Failed to create capture classes")
            if PyErr_Occurred() != nil {
                captureLogger.error("  Python error occurred, printing...")
                PyErr_Print()
                PyErr_Clear()
            } else {
                captureLogger.error("  No Python error set (this is unexpected)")
            }
            throw PythonError.initializationFailed("Failed to create capture classes")
        }
        Py_DecRef(result)
        captureLogger.info("  ✅ Capture class defined")

        // Set sys.stdout and sys.stderr to our capture objects
        let redirectCode = """
import sys
sys.stdout = _terrarium_stdout
sys.stderr = _terrarium_stderr
"""
        captureLogger.info("  Redirecting stdout/stderr...")
        let redirectResult = PyRun_String(
            redirectCode,
            Py_file_input,
            globalDict,
            globalDict
        )

        if redirectResult == nil {
            captureLogger.error("  ❌ Failed to redirect stdout/stderr")
            if PyErr_Occurred() != nil {
                PyErr_Print()
                PyErr_Clear()
            }
            throw PythonError.initializationFailed("Failed to redirect stdout/stderr")
        }
        Py_DecRef(redirectResult)

        // Verify the capture objects are in place
        let terrariumStdout = PyDict_GetItemString(globalDict, "_terrarium_stdout")
        let terrariumStderr = PyDict_GetItemString(globalDict, "_terrarium_stderr")
        captureLogger.info("  Capture objects: stdout=\(terrariumStdout != nil), stderr=\(terrariumStderr != nil)")

        captureLogger.info("  ✅ Stdout/stderr capture installed successfully")
    }
    #endif

    /// Uninstall the capture mechanism and restore original stdout/stderr.
    public func uninstall() {
        guard isInstalled else { return }

        #if canImport(CPython)
        uninstallPythonCapture()
        #endif

        isInstalled = false
    }

    #if canImport(CPython)
    private func uninstallPythonCapture() {
        let sysModule = PyImport_ImportModule("sys")
        guard sysModule != nil else { return }
        defer { Py_DecRef(sysModule) }

        // Restore original stdout
        if let originalStdout = originalStdout {
            PyObject_SetAttrString(sysModule, "stdout", originalStdout)
            Py_DecRef(originalStdout)
            self.originalStdout = nil
        }

        // Restore original stderr
        if let originalStderr = originalStderr {
            PyObject_SetAttrString(sysModule, "stderr", originalStderr)
            Py_DecRef(originalStderr)
            self.originalStderr = nil
        }
    }
    #endif

    // MARK: - Output Retrieval

    /// Get captured stdout content.
    public func getStdout() -> String {
        #if canImport(CPython)
        return getPythonCapturedOutput(name: "_terrarium_stdout")
        #else
        return capturedStdout
        #endif
    }

    /// Get captured stderr content.
    public func getStderr() -> String {
        #if canImport(CPython)
        return getPythonCapturedOutput(name: "_terrarium_stderr")
        #else
        return capturedStderr
        #endif
    }

    #if canImport(CPython)
    private func getPythonCapturedOutput(name: String) -> String {
        let mainModule = PyImport_AddModule("__main__")
        guard mainModule != nil else {
            captureLogger.warning("  getPythonCapturedOutput(\(name)): Failed to get __main__")
            return ""
        }

        let globalDict = PyModule_GetDict(mainModule)
        guard globalDict != nil else {
            captureLogger.warning("  getPythonCapturedOutput(\(name)): Failed to get global dict")
            return ""
        }

        // Get the capture object
        let captureObj = PyDict_GetItemString(globalDict, name)
        guard captureObj != nil else {
            captureLogger.warning("  getPythonCapturedOutput(\(name)): Capture object not found in globals")
            return ""
        }

        // Call getvalue()
        let getValue = PyObject_GetAttrString(captureObj, "getvalue")
        guard getValue != nil else {
            captureLogger.warning("  getPythonCapturedOutput(\(name)): getvalue method not found")
            return ""
        }
        defer { Py_DecRef(getValue) }

        let result = PyObject_CallObject(getValue, nil)
        guard result != nil else {
            captureLogger.warning("  getPythonCapturedOutput(\(name)): getvalue() call failed")
            // Don't call PyErr_Clear() here - it might clear an error from user code
            // that we need to report. Just return empty string.
            return ""
        }
        defer { Py_DecRef(result) }

        if let utf8Str = PyUnicode_AsUTF8(result) {
            let output = String(cString: utf8Str)
            if !output.isEmpty {
                captureLogger.info("  getPythonCapturedOutput(\(name)): Got \(output.count) chars")
            }
            return output
        }

        return ""
    }
    #endif

    // MARK: - Clear

    /// Clear captured output buffers.
    public func clear() {
        #if canImport(CPython)
        clearPythonCapture()
        #else
        capturedStdout = ""
        capturedStderr = ""
        #endif
    }

    #if canImport(CPython)
    private func clearPythonCapture() {
        let mainModule = PyImport_AddModule("__main__")
        guard mainModule != nil else { return }

        let globalDict = PyModule_GetDict(mainModule)
        guard globalDict != nil else { return }

        // Clear both capture objects
        for name in ["_terrarium_stdout", "_terrarium_stderr"] {
            let captureObj = PyDict_GetItemString(globalDict, name)
            guard captureObj != nil else { continue }

            let clearMethod = PyObject_GetAttrString(captureObj, "clear")
            guard clearMethod != nil else { continue }
            defer { Py_DecRef(clearMethod) }

            let result = PyObject_CallObject(clearMethod, nil)
            if result != nil {
                Py_DecRef(result)
            } else {
                PyErr_Clear()
            }
        }
    }
    #endif

    // MARK: - Simulation Support

    /// Append to captured stdout (for simulation mode).
    public func appendStdout(_ text: String) {
        capturedStdout += text
    }

    /// Append to captured stderr (for simulation mode).
    public func appendStderr(_ text: String) {
        capturedStderr += text
    }
}
