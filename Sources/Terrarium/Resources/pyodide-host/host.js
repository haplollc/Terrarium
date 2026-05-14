// Terrarium Pyodide host
//
// Loaded inside a hidden WKWebView. Bridges Swift ↔ Pyodide:
//   • runPython(id, code)         — execute user code, post result back
//   • installPackage(id, pkg)     — micropip.install with progress
//   • uninstallPackage(id, pkg)   — best-effort uninstall (rm site-package)
//   • listPackages(id)            — enumerate installed packages
//   • clearPackageCache(id)       — wipe IndexedDB-backed cache
//
// All responses are sent via window.webkit.messageHandlers.terrariumPyodide.postMessage.

let pyodide = null;
let pyodideReady = false;
let stdoutBuf = "";
let stderrBuf = "";
let progressBuf = [];

// Persistent storage path inside Pyodide's emscripten FS. We mount IDBFS
// here so installed packages survive WebView reloads (and thus app
// launches). Site-packages, downloaded wheels, anything micropip wrote.
const PERSIST_DIR = "/persist";

function post(payload) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.terrariumPyodide) {
    window.webkit.messageHandlers.terrariumPyodide.postMessage(payload);
  }
}

async function syncFS(populate) {
  return new Promise((resolve, reject) => {
    pyodide.FS.syncfs(populate, (err) => (err ? reject(err) : resolve()));
  });
}

async function bootstrap() {
  try {
    pyodide = await loadPyodide({
      // jsDelivr's CDN is Pyodide's canonical distribution channel for
      // the runtime + ~250 prebuilt WASM packages. Pinned to v0.29.4
      // to match the loader script in host.html.
      indexURL: "https://cdn.jsdelivr.net/pyodide/v0.29.4/full/",
      stdout: (text) => { stdoutBuf += text + "\n"; },
      stderr: (text) => { stderrBuf += text + "\n"; },
    });

    // Mount IDBFS at /persist and pull any previously-synced packages
    // off disk. `populate=true` loads from IndexedDB into the FS.
    pyodide.FS.mkdir(PERSIST_DIR);
    pyodide.FS.mount(pyodide.FS.filesystems.IDBFS, {}, PERSIST_DIR);
    await syncFS(true);

    // Make sure /persist/site-packages exists, then put it on sys.path
    // before any user import resolution happens.
    const sitePackages = PERSIST_DIR + "/site-packages";
    if (!pyodide.FS.analyzePath(sitePackages).exists) {
      pyodide.FS.mkdir(sitePackages);
      await syncFS(false);
    }
    pyodide.runPython(`
import sys
if "${sitePackages}" not in sys.path:
    sys.path.insert(0, "${sitePackages}")
`);

    // Pre-load micropip — it's tiny (~150 KB) and we use it for every
    // `%pip install`. Without this, the first install pays a load tax.
    await pyodide.loadPackage("micropip");

    // Override micropip's install target to /persist/site-packages so
    // installed wheels survive the FS reset on reload.
    pyodide.runPython(`
import micropip
import micropip._compat as _mc

# Force micropip to write into the persistent dir. Without this, wheels
# land in the in-memory site-packages and vanish on reload.
import sys
_target = "${sitePackages}"
if _target not in sys.path:
    sys.path.insert(0, _target)
`);

    pyodideReady = true;
    post({ kind: "ready", version: pyodide.version });
  } catch (err) {
    post({ kind: "bootstrapFailed", error: String(err && err.stack || err) });
  }
}

function resetBuffers() {
  stdoutBuf = "";
  stderrBuf = "";
  progressBuf = [];
}

async function runPython(id, code) {
  if (!pyodideReady) {
    post({ kind: "runResult", id, stdout: "", stderr: "Pyodide not yet ready", exception: null, exitCode: -1, durationMs: 0 });
    return;
  }
  resetBuffers();
  const t0 = performance.now();
  let exception = null;
  let exitCode = 0;
  try {
    await pyodide.runPythonAsync(code);
  } catch (e) {
    exception = String(e && e.message || e);
    exitCode = 1;
  }
  const durationMs = Math.round(performance.now() - t0);
  // Sync any FS changes the user code made to IDBFS so they persist.
  try { await syncFS(false); } catch (_) {}
  post({
    kind: "runResult",
    id,
    stdout: stdoutBuf,
    stderr: stderrBuf,
    exception,
    exitCode,
    durationMs,
  });
}

async function installPackage(id, pkg) {
  if (!pyodideReady) {
    post({ kind: "installResult", id, pkg, ok: false, error: "Pyodide not yet ready" });
    return;
  }
  // Stream pip-style progress lines as separate messages so the Swift
  // side can append them to the runner's Console tab live.
  post({ kind: "installProgress", id, line: `Collecting ${pkg}` });
  try {
    await pyodide.runPythonAsync(`
import micropip
await micropip.install(${JSON.stringify(pkg)}, keep_going=True)
`);
    // After install, look up the installed version for the success line.
    let version = "unknown";
    try {
      const v = pyodide.runPython(`
import importlib.metadata as _md
try: _v = _md.version(${JSON.stringify(pkg)})
except Exception: _v = ""
_v
`);
      if (v) version = v;
    } catch (_) {}
    try { await syncFS(false); } catch (_) {}
    post({ kind: "installProgress", id, line: `Successfully installed ${pkg}-${version}` });
    post({ kind: "installResult", id, pkg, ok: true, version });
  } catch (err) {
    const msg = String(err && err.message || err);
    post({ kind: "installProgress", id, line: `ERROR: ${msg.split("\n")[0]}` });
    post({ kind: "installResult", id, pkg, ok: false, error: msg });
  }
}

async function uninstallPackage(id, pkg) {
  if (!pyodideReady) {
    post({ kind: "uninstallResult", id, pkg, ok: false, error: "Pyodide not yet ready" });
    return;
  }
  try {
    // micropip 0.6+ has uninstall; fall back to manual rm for older
    // releases bundled in older Pyodide versions.
    const out = await pyodide.runPythonAsync(`
import micropip, importlib.metadata as _md, shutil, sys, os
pkg = ${JSON.stringify(pkg)}
try:
    if hasattr(micropip, "uninstall"):
        micropip.uninstall(pkg)
    # Best-effort: wipe the dist-info + top-level package dir.
    try:
        dist = _md.distribution(pkg)
        site = os.path.dirname(dist._path) if hasattr(dist, "_path") else None
    except Exception:
        site = None
    persist = "${PERSIST_DIR}/site-packages"
    for entry in os.listdir(persist):
        low = entry.lower().replace("-", "_")
        target = pkg.lower().replace("-", "_")
        if low == target or low.startswith(target + "-"):
            full = os.path.join(persist, entry)
            if os.path.isdir(full):
                shutil.rmtree(full, ignore_errors=True)
            else:
                try: os.remove(full)
                except: pass
    "ok"
`);
    try { await syncFS(false); } catch (_) {}
    post({ kind: "uninstallResult", id, pkg, ok: true });
  } catch (err) {
    post({ kind: "uninstallResult", id, pkg, ok: false, error: String(err) });
  }
}

async function listPackages(id) {
  if (!pyodideReady) {
    post({ kind: "listResult", id, packages: [] });
    return;
  }
  try {
    const json = await pyodide.runPythonAsync(`
import importlib.metadata as _md, json, os, sys
result = []
persist = "${PERSIST_DIR}/site-packages"
# Only enumerate dist-info dirs in the persistent location — bundled
# Pyodide packages live elsewhere and shouldn't appear as user-managed.
if os.path.isdir(persist):
    for entry in os.listdir(persist):
        if entry.endswith(".dist-info"):
            try:
                dist = _md.PathDistribution(__import__("pathlib").Path(persist) / entry)
                size = 0
                for f in dist.files or []:
                    try: size += (dist.locate_file(f)).stat().st_size
                    except: pass
                result.append({"name": dist.metadata["Name"], "version": dist.version, "size": size})
            except Exception as e:
                pass
json.dumps(result)
`);
    post({ kind: "listResult", id, packages: JSON.parse(json) });
  } catch (err) {
    post({ kind: "listResult", id, packages: [], error: String(err) });
  }
}

async function clearPackageCache(id) {
  try {
    await pyodide.runPythonAsync(`
import shutil, os
persist = "${PERSIST_DIR}/site-packages"
if os.path.isdir(persist):
    for entry in os.listdir(persist):
        full = os.path.join(persist, entry)
        try:
            if os.path.isdir(full):
                shutil.rmtree(full, ignore_errors=True)
            else:
                os.remove(full)
        except Exception:
            pass
`);
    try { await syncFS(false); } catch (_) {}
    post({ kind: "clearResult", id, ok: true });
  } catch (err) {
    post({ kind: "clearResult", id, ok: false, error: String(err) });
  }
}

window.terrariumRunPython = runPython;
window.terrariumInstallPackage = installPackage;
window.terrariumUninstallPackage = uninstallPackage;
window.terrariumListPackages = listPackages;
window.terrariumClearPackageCache = clearPackageCache;

bootstrap();
