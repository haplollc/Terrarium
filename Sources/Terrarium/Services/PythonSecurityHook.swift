//
//  PythonSecurityHook.swift
//  Terrarium
//
//  Implements a Python import hook to block dangerous modules at runtime.
//  This provides defense-in-depth beyond the Swift-level code scanning.
//

import Foundation

#if canImport(CPython)
import CPython
#endif

/// Installs a Python-level import hook to block dangerous modules.
/// This provides runtime protection even if the Swift-level check is bypassed.
public final class PythonSecurityHook {

    // MARK: - Properties

    private let blockedModules: Set<String>
    private var isInstalled: Bool = false

    // MARK: - Import Hook Python Code

    /// Python code that defines the import hook class.
    /// This hooks into Python's import machinery to block dangerous modules.
    private var importHookCode: String {
        let blockedList = blockedModules.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
import sys
import builtins

class _TerrariumImportBlocker:
    '''Import hook that blocks dangerous modules for security.'''

    BLOCKED_MODULES = frozenset([\(blockedList)])

    def find_module(self, fullname, path=None):
        '''Called for each import. Return self to block, None to allow.'''
        # Check if module is directly blocked
        if fullname in self.BLOCKED_MODULES:
            return self

        # Check if it's a submodule of a blocked module
        for blocked in self.BLOCKED_MODULES:
            if fullname.startswith(blocked + '.'):
                return self

        return None

    def load_module(self, fullname):
        '''Called when we block an import. Raises ImportError.'''
        raise ImportError(
            f"Module '{fullname}' is blocked for security reasons. "
            f"This module cannot be used in the Terrarium Python environment."
        )

# Install the import blocker
_terrarium_import_blocker = _TerrariumImportBlocker()

# Insert at the beginning of sys.meta_path for priority
if _terrarium_import_blocker not in sys.meta_path:
    sys.meta_path.insert(0, _terrarium_import_blocker)

# Also wrap builtins.__import__ for extra protection
_original_import = builtins.__import__

def _terrarium_safe_import(name, globals=None, locals=None, fromlist=(), level=0):
    '''Wrapped import that checks against blocked modules.'''
    # Check the module name
    if name in _TerrariumImportBlocker.BLOCKED_MODULES:
        raise ImportError(
            f"Module '{name}' is blocked for security reasons."
        )

    return _original_import(name, globals, locals, fromlist, level)

builtins.__import__ = _terrarium_safe_import
"""
    }

    // MARK: - Initialization

    /// Create a new security hook with the specified blocked modules.
    /// - Parameter blockedModules: Set of module names to block
    public init(blockedModules: Set<String>) {
        self.blockedModules = blockedModules
    }

    // MARK: - Installation

    /// Install the import hook into the Python runtime.
    /// - Throws: PythonError if installation fails
    public func install() throws {
        guard !isInstalled else { return }

        #if canImport(CPython)
        try installPythonHook()
        #endif

        isInstalled = true
    }

    #if canImport(CPython)
    private func installPythonHook() throws {
        let gilState = PyGILState_Ensure()
        defer { PyGILState_Release(gilState) }

        let mainModule = PyImport_AddModule("__main__")
        guard mainModule != nil else {
            throw PythonError.initializationFailed("Failed to get __main__ for security hook")
        }

        let globalDict = PyModule_GetDict(mainModule)
        guard globalDict != nil else {
            throw PythonError.initializationFailed("Failed to get globals for security hook")
        }

        let result = PyRun_String(
            importHookCode,
            Py_file_input,
            globalDict,
            globalDict
        )

        if result == nil {
            let error = getLastPythonError()
            PyErr_Clear()
            throw PythonError.initializationFailed("Failed to install security hook: \(error)")
        }

        Py_DecRef(result)
    }

    private func getLastPythonError() -> String {
        guard PyErr_Occurred() != nil else { return "Unknown error" }

        var pType: UnsafeMutablePointer<PyObject>?
        var pValue: UnsafeMutablePointer<PyObject>?
        var pTraceback: UnsafeMutablePointer<PyObject>?

        PyErr_Fetch(&pType, &pValue, &pTraceback)

        defer {
            if let pType = pType { Py_DecRef(pType) }
            if let pValue = pValue { Py_DecRef(pValue) }
            if let pTraceback = pTraceback { Py_DecRef(pTraceback) }
        }

        if let pValue = pValue {
            let strRepr = PyObject_Str(pValue)
            if let strRepr = strRepr {
                defer { Py_DecRef(strRepr) }
                if let msgStr = PyUnicode_AsUTF8(strRepr) {
                    return String(cString: msgStr)
                }
            }
        }

        return "Unknown error"
    }
    #endif

    /// Uninstall the import hook.
    public func uninstall() {
        guard isInstalled else { return }

        #if canImport(CPython)
        uninstallPythonHook()
        #endif

        isInstalled = false
    }

    #if canImport(CPython)
    private func uninstallPythonHook() {
        let gilState = PyGILState_Ensure()
        defer { PyGILState_Release(gilState) }

        // Restore original __import__
        let restoreCode = """
import sys
import builtins

# Remove our import blocker from meta_path
sys.meta_path = [m for m in sys.meta_path if not isinstance(m, _TerrariumImportBlocker)]

# Restore original __import__ if we saved it
if hasattr(builtins, '_original_import'):
    builtins.__import__ = _original_import
"""

        let mainModule = PyImport_AddModule("__main__")
        guard mainModule != nil else { return }

        let globalDict = PyModule_GetDict(mainModule)
        guard globalDict != nil else { return }

        let result = PyRun_String(
            restoreCode,
            Py_file_input,
            globalDict,
            globalDict
        )

        if result != nil {
            Py_DecRef(result)
        } else {
            PyErr_Clear()
        }
    }
    #endif

    // MARK: - Queries

    /// Check if a module would be blocked by the security hook.
    /// - Parameter moduleName: The module name to check
    /// - Returns: true if the module is blocked
    public func isModuleBlocked(_ moduleName: String) -> Bool {
        // Direct match
        if blockedModules.contains(moduleName) {
            return true
        }

        // Check if it's a submodule of a blocked module
        for blocked in blockedModules {
            if moduleName.hasPrefix(blocked + ".") {
                return true
            }
        }

        return false
    }

    /// Get the set of blocked modules.
    public var blockedModuleList: Set<String> {
        blockedModules
    }
}
