//
//  PythonBridge.swift
//  Terrarium
//
//  Low-level bridge to the Python C API using BeeWare's Python.xcframework.
//  Handles GIL management, initialization, execution, and cleanup.
//

import Foundation
import os.log

#if canImport(CPython)
import CPython
#endif

/// Logger for Python bridge operations
private let pythonLogger = Logger(subsystem: "com.terrarium.python", category: "PythonBridge")

/// Low-level bridge to the embedded Python C API.
/// This class manages the Python interpreter lifecycle and provides
/// GIL-safe code execution.
public final class PythonBridge: @unchecked Sendable {

    // MARK: - Singleton

    public static let shared = PythonBridge()

    // MARK: - State

    private var isInitialized = false
    private let lock = NSLock()
    private var stdoutCapture: StdoutCapture?
    private var mainThreadState: UnsafeMutablePointer<PyThreadState>?

    // MARK: - Configuration

    private var stdlibPath: String?
    private var sitePackagesPath: String?
    private var bundledSitePackagesPath: String?
    private var libDynloadPath: String?
    private var resourcesPath: String?

    private init() {}

    // MARK: - Initialization

    /// Initialize the Python interpreter with the given paths.
    /// - Parameters:
    ///   - stdlibPath: Path to the Python standard library
    ///   - sitePackagesPath: Path to user site-packages directory
    ///   - bundledSitePackagesPath: Path to bundled site-packages (optional)
    ///   - libDynloadPath: Path to lib-dynload with extension modules (optional)
    ///   - resourcesPath: Path to bundled Python resources
    /// - Throws: PythonError if initialization fails
    public func initialize(
        stdlibPath: String,
        sitePackagesPath: String,
        bundledSitePackagesPath: String? = nil,
        libDynloadPath: String? = nil,
        resourcesPath: String
    ) throws {
        pythonLogger.info("🐍 PythonBridge.initialize() called")
        pythonLogger.info("  stdlibPath: \(stdlibPath)")
        pythonLogger.info("  sitePackagesPath: \(sitePackagesPath)")
        pythonLogger.info("  bundledSitePackagesPath: \(bundledSitePackagesPath ?? "none")")
        pythonLogger.info("  libDynloadPath: \(libDynloadPath ?? "none")")
        pythonLogger.info("  resourcesPath: \(resourcesPath)")

        lock.lock()
        defer { lock.unlock() }

        guard !isInitialized else {
            pythonLogger.info("  Already initialized, returning early")
            return
        }

        self.stdlibPath = stdlibPath
        self.sitePackagesPath = sitePackagesPath
        self.bundledSitePackagesPath = bundledSitePackagesPath
        self.libDynloadPath = libDynloadPath
        self.resourcesPath = resourcesPath

        #if canImport(CPython)
        pythonLogger.info("  CPython module available, initializing real Python runtime")
        try initializePythonRuntime()
        pythonLogger.info("  ✅ Python runtime initialized successfully")
        #else
        pythonLogger.warning("  ⚠️ CPython module NOT available, using simulation mode")
        // Fallback for when Python framework is not available
        // This allows the code to compile without the framework
        isInitialized = true
        #endif
    }

    #if canImport(CPython)
    private func initializePythonRuntime() throws {
        pythonLogger.info("  initializePythonRuntime() starting...")

        // Set Python home before initialization
        guard let resourcesPath = resourcesPath else {
            pythonLogger.error("  ❌ Resources path not set")
            throw PythonError.initializationFailed("Resources path not set")
        }

        // Configure Python paths before initialization
        // Include lib-dynload for extension modules and bundled site-packages
        var pathComponents = [stdlibPath ?? ""]
        if let libDynload = libDynloadPath, !libDynload.isEmpty {
            pathComponents.append(libDynload)
        }
        if let bundledSite = bundledSitePackagesPath, !bundledSite.isEmpty {
            pathComponents.append(bundledSite)
        }
        pathComponents.append(sitePackagesPath ?? "")
        pathComponents.append(resourcesPath)
        let pythonPath = pathComponents.filter { !$0.isEmpty }.joined(separator: ":")

        pythonLogger.info("  Setting PYTHONPATH: \(pythonPath)")
        setenv("PYTHONPATH", pythonPath, 1)
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        setenv("PYTHONHOME", resourcesPath, 1)

        // Initialize Python
        pythonLogger.info("  Checking Py_IsInitialized()...")
        if Py_IsInitialized() == 0 {
            pythonLogger.info("  Calling Py_Initialize()...")
            Py_Initialize()
            pythonLogger.info("  Py_Initialize() returned")
        } else {
            pythonLogger.info("  Python already initialized")
        }

        guard Py_IsInitialized() != 0 else {
            pythonLogger.error("  ❌ Py_Initialize() failed")
            throw PythonError.initializationFailed("Py_Initialize() failed")
        }
        pythonLogger.info("  ✅ Py_IsInitialized() = true")

        // Set sys.executable so AppleFrameworkLoader can resolve .fwork paths
        if let execPath = Bundle.main.executablePath {
            let sysModule = PyImport_ImportModule("sys")
            if let sysModule {
                let pyPath = PyUnicode_FromString(execPath)
                if let pyPath {
                    PyObject_SetAttrString(sysModule, "executable", pyPath)
                    Py_DecRef(pyPath)
                }
                Py_DecRef(sysModule)
            }
        }

        // Set up sys.path
        pythonLogger.info("  Setting up sys.path...")
        try setupSysPath()
        pythonLogger.info("  ✅ sys.path configured")

        // Initialize stdout capture
        pythonLogger.info("  Installing stdout capture...")
        stdoutCapture = StdoutCapture()
        try stdoutCapture?.install()
        pythonLogger.info("  ✅ stdout capture installed")

        // Run a simple diagnostic test to verify Python is working
        pythonLogger.info("  Running diagnostic Python test...")
        let diagnosticResult = runDiagnosticTest()
        if diagnosticResult {
            pythonLogger.info("  ✅ Diagnostic test passed")
        } else {
            pythonLogger.error("  ❌ Diagnostic test failed - Python may not be working correctly")
        }

        // CRITICAL: Release the GIL so other threads can acquire it
        // This is necessary for multi-threaded Python embedding
        pythonLogger.info("  Releasing GIL for multi-threaded access...")
        mainThreadState = PyEval_SaveThread()
        pythonLogger.info("  ✅ GIL released, mainThreadState saved")

        isInitialized = true
    }

    /// Run a simple Python test to verify the runtime is working
    private func runDiagnosticTest() -> Bool {
        // Note: We have the GIL during initialization, so no need to acquire it
        let mainModule = PyImport_AddModule("__main__")
        guard mainModule != nil else {
            pythonLogger.error("    Diagnostic: Failed to get __main__")
            return false
        }

        let globalDict = PyModule_GetDict(mainModule)
        guard globalDict != nil else {
            pythonLogger.error("    Diagnostic: Failed to get globals")
            return false
        }

        // Ensure builtins are available
        let builtinsModule = PyImport_ImportModule("builtins")
        if let builtinsModule = builtinsModule {
            PyDict_SetItemString(globalDict, "__builtins__", builtinsModule)
            Py_DecRef(builtinsModule)
        }

        // Try a simple expression
        let testCode = "1 + 1"
        pythonLogger.info("    Diagnostic: Testing '\(testCode)'")

        // Use Py_eval_input (258) for evaluating an expression
        let result = PyRun_String(testCode, 258, globalDict, globalDict)

        if result != nil {
            // Get the result value
            let longValue = PyLong_AsLong(result)
            pythonLogger.info("    Diagnostic: 1 + 1 = \(longValue)")
            Py_DecRef(result)

            if longValue == 2 {
                return true
            }
        } else {
            // Check for error
            if PyErr_Occurred() != nil {
                pythonLogger.error("    Diagnostic: Python error occurred")
                PyErr_Print()
                PyErr_Clear()
            } else {
                pythonLogger.error("    Diagnostic: PyRun_String returned nil without error")
            }
        }

        // Also test a print statement with Py_file_input (257)
        let printCode = "_diag_result = 42"
        pythonLogger.info("    Diagnostic: Testing assignment")
        let assignResult = PyRun_String(printCode, 257, globalDict, globalDict)

        if assignResult != nil {
            pythonLogger.info("    Diagnostic: Assignment succeeded")
            Py_DecRef(assignResult)

            // Check if the variable was set
            let diagResult = PyDict_GetItemString(globalDict, "_diag_result")
            if diagResult != nil {
                let value = PyLong_AsLong(diagResult)
                pythonLogger.info("    Diagnostic: _diag_result = \(value)")
                return value == 42
            } else {
                pythonLogger.error("    Diagnostic: Variable not found in dict")
            }
        } else {
            if PyErr_Occurred() != nil {
                pythonLogger.error("    Diagnostic: Assignment error occurred")
                PyErr_Print()
                PyErr_Clear()
            } else {
                pythonLogger.error("    Diagnostic: Assignment returned nil without error")
            }
        }

        return false
    }

    private func setupSysPath() throws {
        // Note: This is called during initialization when we already hold the GIL
        // from Py_Initialize(), so we don't use PyGILState_Ensure here.
        let sysModule = PyImport_ImportModule("sys")
        guard sysModule != nil else {
            throw PythonError.initializationFailed("Failed to import sys module")
        }
        defer { Py_DecRef(sysModule) }

        let pathList = PyObject_GetAttrString(sysModule, "path")
        guard pathList != nil else {
            throw PythonError.initializationFailed("Failed to get sys.path")
        }
        defer { Py_DecRef(pathList) }

        // Clear existing paths
        let clearResult = PyList_SetSlice(pathList, 0, PyList_Size(pathList), nil)
        guard clearResult == 0 else {
            throw PythonError.initializationFailed("Failed to clear sys.path")
        }

        // Add our paths (including lib-dynload and bundled site-packages if available)
        let paths = [stdlibPath, libDynloadPath, bundledSitePackagesPath, sitePackagesPath, resourcesPath].compactMap { $0 }
        for path in paths {
            let pathStr = PyUnicode_FromString(path)
            guard pathStr != nil else { continue }
            PyList_Append(pathList, pathStr)
            Py_DecRef(pathStr)
        }
    }
    #endif

    // MARK: - Execution

    /// Execute Python code and return the result.
    /// - Parameters:
    ///   - code: The Python code to execute
    ///   - globals: Optional global namespace dictionary
    ///   - locals: Optional local namespace dictionary
    /// - Returns: Tuple of (success, stdout, stderr, exception)
    public func execute(code: String) -> (success: Bool, stdout: String, stderr: String, exception: String?) {
        let codePreview = code.prefix(100).replacingOccurrences(of: "\n", with: "\\n")
        pythonLogger.info("🐍 PythonBridge.execute() called")
        pythonLogger.info("  Code preview: \(codePreview)...")
        pythonLogger.info("  isInitialized: \(self.isInitialized)")

        pythonLogger.info("  Acquiring lock...")
        lock.lock()
        defer {
            lock.unlock()
            pythonLogger.info("  Lock released")
        }
        pythonLogger.info("  Lock acquired")

        guard isInitialized else {
            pythonLogger.error("  ❌ Python interpreter not initialized")
            return (false, "", "", "Python interpreter not initialized")
        }

        #if canImport(CPython)
        pythonLogger.info("  Executing with real Python...")
        let startTime = CFAbsoluteTimeGetCurrent()
        let result = executeWithPython(code: code)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        pythonLogger.info("  ✅ Execution completed in \(elapsed)s, success: \(result.success)")
        if let exception = result.exception {
            pythonLogger.error("  Exception: \(exception)")
        }
        return result
        #else
        pythonLogger.info("  Executing with simulation...")
        // Fallback simulation when Python is not available
        return simulateExecution(code: code)
        #endif
    }

    #if canImport(CPython)
    private func executeWithPython(code: String) -> (success: Bool, stdout: String, stderr: String, exception: String?) {
        pythonLogger.info("    executeWithPython() starting...")

        pythonLogger.info("    Acquiring GIL...")
        let gilState = PyGILState_Ensure()
        pythonLogger.info("    GIL acquired")
        defer {
            PyGILState_Release(gilState)
            pythonLogger.info("    GIL released")
        }

        // Clear captured output
        pythonLogger.info("    Clearing stdout capture...")
        stdoutCapture?.clear()

        // Clear any existing Python errors before execution
        if PyErr_Occurred() != nil {
            pythonLogger.warning("    ⚠️ Clearing pre-existing Python error before execution")
            PyErr_Clear()
        }

        // Get __main__ module for execution context
        pythonLogger.info("    Getting __main__ module...")
        let mainModule = PyImport_AddModule("__main__")
        guard mainModule != nil else {
            pythonLogger.error("    ❌ Failed to get __main__ module")
            return (false, "", "", "Failed to get __main__ module")
        }
        pythonLogger.info("    Got __main__ module")

        pythonLogger.info("    Getting global dict...")
        let globalDict = PyModule_GetDict(mainModule)
        guard globalDict != nil else {
            pythonLogger.error("    ❌ Failed to get global dictionary")
            return (false, "", "", "Failed to get global dictionary")
        }

        // Log the dict size for debugging
        let dictSize = PyDict_Size(globalDict)
        pythonLogger.info("    Got global dict (size: \(dictSize))")

        // Make sure builtins are available
        let builtins = PyDict_GetItemString(globalDict, "__builtins__")
        if builtins == nil {
            pythonLogger.info("    Adding __builtins__ to global dict...")
            let builtinsModule = PyImport_ImportModule("builtins")
            if let builtinsModule = builtinsModule {
                PyDict_SetItemString(globalDict, "__builtins__", builtinsModule)
                Py_DecRef(builtinsModule)
                pythonLogger.info("    ✅ __builtins__ added")
            } else {
                pythonLogger.error("    ❌ Failed to import builtins module")
                PyErr_Clear()
            }
        } else {
            pythonLogger.info("    __builtins__ already present")
        }

        // Execute the code using Py_file_input (257)
        // Note: Py_file_input = 257, Py_single_input = 256, Py_eval_input = 258
        pythonLogger.info("    Calling PyRun_String() with Py_file_input=\(Py_file_input)...")
        pythonLogger.info("    Code length: \(code.count) chars")

        // Use explicit UTF-8 conversion to ensure proper string handling
        let result: UnsafeMutablePointer<PyObject>? = code.withCString { codePtr in
            PyRun_String(
                codePtr,
                Py_file_input,
                globalDict,
                globalDict
            )
        }

        // Immediately check for error after PyRun_String
        let errorOccurred = PyErr_Occurred()
        pythonLogger.info("    PyRun_String() returned, result is \(result == nil ? "nil" : "non-nil"), error: \(errorOccurred == nil ? "none" : "yes")")

        var exception: String?
        var success = true

        // IMPORTANT: Get exception info BEFORE getting stdout/stderr,
        // because getPythonCapturedOutput might clear the error
        if result == nil {
            pythonLogger.warning("    Result is nil, getting exception info FIRST...")
            success = false

            if errorOccurred != nil {
                exception = getExceptionInfo()
                pythonLogger.error("    ❌ Python exception: \(exception ?? "unknown")")
                // Note: getExceptionInfo() calls PyErr_Fetch which clears the error
            } else {
                pythonLogger.error("    ❌ PyRun_String failed but no Python error was set")
            }
        } else {
            pythonLogger.info("    ✅ Execution successful, decrementing result reference...")
            Py_DecRef(result)
        }

        // Now get captured output (after we've saved any exception info)
        pythonLogger.info("    Getting captured stdout...")
        let stdout = stdoutCapture?.getStdout() ?? ""
        pythonLogger.info("    Getting captured stderr...")
        let stderr = stdoutCapture?.getStderr() ?? ""

        // If we didn't get an exception from PyErr but have stderr, use that
        if exception == nil && !stderr.isEmpty && !success {
            pythonLogger.info("    Using stderr as exception message")
            exception = stderr
        }

        pythonLogger.info("    stdout length: \(stdout.count), stderr length: \(stderr.count)")
        if !stdout.isEmpty {
            pythonLogger.info("    stdout preview: \(stdout.prefix(200))")
        }
        if !stderr.isEmpty {
            pythonLogger.info("    stderr preview: \(stderr.prefix(200))")
        }
        return (success, stdout, stderr, exception)
    }

    private func getExceptionInfo() -> String? {
        pythonLogger.info("      getExceptionInfo() called")

        guard PyErr_Occurred() != nil else {
            pythonLogger.info("      No error occurred (PyErr_Occurred returned nil)")
            return nil
        }
        pythonLogger.info("      PyErr_Occurred returned non-nil, fetching error...")

        var pType: UnsafeMutablePointer<PyObject>?
        var pValue: UnsafeMutablePointer<PyObject>?
        var pTraceback: UnsafeMutablePointer<PyObject>?

        PyErr_Fetch(&pType, &pValue, &pTraceback)
        pythonLogger.info("      PyErr_Fetch: type=\(pType != nil), value=\(pValue != nil), tb=\(pTraceback != nil)")

        PyErr_NormalizeException(&pType, &pValue, &pTraceback)

        defer {
            if let pType = pType { Py_DecRef(pType) }
            if let pValue = pValue { Py_DecRef(pValue) }
            if let pTraceback = pTraceback { Py_DecRef(pTraceback) }
        }

        var errorMessage = "Python Exception"

        // Get exception type name
        if let pType = pType {
            let typeName = PyObject_GetAttrString(pType, "__name__")
            if let typeName = typeName {
                if let nameStr = PyUnicode_AsUTF8(typeName) {
                    errorMessage = String(cString: nameStr)
                    pythonLogger.info("      Exception type: \(errorMessage)")
                }
                Py_DecRef(typeName)
            }
        }

        // Get exception message
        if let pValue = pValue {
            let strRepr = PyObject_Str(pValue)
            if let strRepr = strRepr {
                if let msgStr = PyUnicode_AsUTF8(strRepr) {
                    let msg = String(cString: msgStr)
                    errorMessage += ": " + msg
                    pythonLogger.info("      Exception message: \(msg)")
                }
                Py_DecRef(strRepr)
            }
        }

        // Get traceback if available
        if let pTraceback = pTraceback {
            let tbModule = PyImport_ImportModule("traceback")
            if let tbModule = tbModule {
                let formatTb = PyObject_GetAttrString(tbModule, "format_tb")
                if let formatTb = formatTb {
                    let args = PyTuple_New(1)
                    PyTuple_SetItem(args, 0, pTraceback)
                    Py_IncRef(pTraceback) // SetItem steals reference

                    let tbList = PyObject_CallObject(formatTb, args)
                    if let tbList = tbList {
                        let separator = PyUnicode_FromString("")
                        let joined = PyUnicode_Join(separator, tbList)
                        if let joined = joined, let tbStr = PyUnicode_AsUTF8(joined) {
                            errorMessage = "Traceback (most recent call last):\n" + String(cString: tbStr) + errorMessage
                            Py_DecRef(joined)
                        }
                        if let separator = separator { Py_DecRef(separator) }
                        Py_DecRef(tbList)
                    }
                    Py_DecRef(args)
                    Py_DecRef(formatTb)
                }
                Py_DecRef(tbModule)
            }
        }

        return errorMessage
    }
    #endif

    // MARK: - Interruption

    /// Interrupt the currently running Python code.
    /// This sets a pending interrupt that will be processed at the next opcode.
    public func interrupt() {
        #if canImport(CPython)
        PyErr_SetInterrupt()
        #endif
    }

    // MARK: - Finalization

    /// Finalize and clean up the Python interpreter.
    public func finalize() {
        lock.lock()
        defer { lock.unlock() }

        guard isInitialized else { return }

        #if canImport(CPython)
        // Restore the main thread state before finalization
        if let threadState = mainThreadState {
            PyEval_RestoreThread(threadState)
            mainThreadState = nil
        }

        stdoutCapture?.uninstall()
        stdoutCapture = nil

        if Py_IsInitialized() != 0 {
            Py_Finalize()
        }
        #endif

        isInitialized = false
    }

    // MARK: - Fallback Simulation

    /// Fallback simulation when Python framework is not available.
    /// This allows the app to compile and run basic tests without the framework.
    private func simulateExecution(code: String) -> (success: Bool, stdout: String, stderr: String, exception: String?) {
        var stdout = ""
        var exception: String?
        var success = true

        // Parse print statements as a simple demonstration
        let lines = code.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Handle print() statements
            if trimmed.hasPrefix("print(") && trimmed.hasSuffix(")") {
                let content = String(trimmed.dropFirst(6).dropLast(1))
                // Handle string literals
                if (content.hasPrefix("\"") && content.hasSuffix("\"")) ||
                   (content.hasPrefix("'") && content.hasSuffix("'")) {
                    let text = String(content.dropFirst().dropLast())
                    stdout += text + "\n"
                } else if content.hasPrefix("f\"") || content.hasPrefix("f'") {
                    // f-string - just output the raw content for demo
                    let text = String(content.dropFirst(2).dropLast())
                    stdout += text + "\n"
                } else {
                    // Simple expression
                    stdout += evaluateSimpleExpression(content) + "\n"
                }
            }
            // Handle raise statements
            else if trimmed.contains("raise") {
                if trimmed.contains("Exception") || trimmed.contains("Error") {
                    exception = "Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\n" + trimmed
                    success = false
                    break
                }
            }
        }

        return (success, stdout.trimmingCharacters(in: .newlines), "", exception)
    }

    private func evaluateSimpleExpression(_ expr: String) -> String {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)

        // Simple arithmetic
        if let result = evaluateArithmetic(trimmed) {
            return String(result)
        }

        return trimmed
    }

    private func evaluateArithmetic(_ expr: String) -> Int? {
        let components = expr.components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        if components.count == 2,
           let a = Int(components[0]),
           let b = Int(components[1]) {
            return a + b
        }

        let subComponents = expr.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        if subComponents.count == 2,
           let a = Int(subComponents[0]),
           let b = Int(subComponents[1]) {
            return a - b
        }

        let mulComponents = expr.components(separatedBy: "*").map { $0.trimmingCharacters(in: .whitespaces) }
        if mulComponents.count == 2,
           let a = Int(mulComponents[0]),
           let b = Int(mulComponents[1]) {
            return a * b
        }

        return Int(expr)
    }

    // MARK: - State Queries

    /// Check if the Python interpreter is currently initialized.
    public var isPythonInitialized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isInitialized
    }

    /// Check if the real Python framework is available.
    public var isPythonFrameworkAvailable: Bool {
        #if canImport(CPython)
        return true
        #else
        return false
        #endif
    }
}
