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
    // Jupyter-style auto-show: if the user's code created matplotlib
    // figures but never called `.show()` or saved them, auto-render
    // each figure to a PNG and emit it via the terrarium_show marker.
    // This is the same convention Jupyter / IPython uses for plt.plot()
    // calls at the end of a cell — it's what users expect to happen.
    await autoShowMatplotlibFigures();
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

/// Render every open matplotlib figure to a PNG and print it with the
/// `terrarium_show` marker so the runner's View tab picks them up.
/// No-op if matplotlib was never imported in this run.
async function autoShowMatplotlibFigures() {
  try {
    await pyodide.runPythonAsync(`
import sys as _sys
if 'matplotlib' in _sys.modules or 'matplotlib.pyplot' in _sys.modules:
    try:
        import matplotlib.pyplot as _plt
        import io as _io, base64 as _b64
        for _num in _plt.get_fignums():
            _fig = _plt.figure(_num)
            _buf = _io.BytesIO()
            _fig.savefig(_buf, format='png', bbox_inches='tight', dpi=120)
            _buf.seek(0)
            _encoded = _b64.b64encode(_buf.read()).decode('ascii')
            print(f"__TERRARIUM_IMG_PNG_B64__:{_encoded}")
        _plt.close('all')
    except Exception as _e:
        # Don't let auto-show ever crash the user's run — they didn't
        # ask for this behavior, so they shouldn't pay for it failing.
        import sys as __sys
        print(f"(auto-show skipped: {_e})", file=__sys.stderr)
`);
  } catch (_) {
    // Same defensive principle on the JS side.
  }
}

async function installPackage(id, pkg) {
  if (!pyodideReady) {
    post({ kind: "installResult", id, pkg, ok: false, error: "Pyodide not yet ready" });
    return;
  }

  post({ kind: "installProgress", id, line: `Collecting ${pkg}` });

  try {
    // PREFERRED PATH — pyodide.loadPackage. Works for any package in
    // Pyodide's official index (numpy, pandas, matplotlib, scipy,
    // sklearn, etc.), supports a `messageCallback` for live progress,
    // and handles transitive deps in parallel. Streams lines like
    // "Loading matplotlib, numpy, contourpy, …" and "Loaded matplotlib".
    let loadedViaIndex = false;
    try {
      await pyodide.loadPackage(pkg, {
        messageCallback: (msg) => {
          post({ kind: "installProgress", id, line: `  ${msg}` });
        },
        errorCallback: (msg) => {
          post({ kind: "installProgress", id, line: `  ${msg}` });
        },
      });
      loadedViaIndex = true;
    } catch (loadErr) {
      // loadPackage throws for packages not in the Pyodide-built index
      // — those need micropip's PyPI resolver. We fall through silently
      // and try micropip next.
      const m = String(loadErr && loadErr.message || loadErr);
      // If the error is anything OTHER than "not in index", re-raise.
      if (!/Can't find a package/i.test(m) && !/not found/i.test(m)) {
        throw loadErr;
      }
      post({ kind: "installProgress", id, line: `  Package not in Pyodide index, falling back to PyPI…` });
    }

    // FALLBACK PATH — micropip.install for arbitrary PyPI packages.
    // micropip doesn't have a `messageCallback`, so we monkey-patch
    // Python's stdout to stream lines back as they're printed. Then
    // we run micropip with verbose=True so it prints per-dep progress.
    if (!loadedViaIndex) {
      // Register a JS function the Python streaming-stdout can call.
      pyodide.globals.set("__terrarium_pip_emit", (line) => {
        post({ kind: "installProgress", id, line: `  ${String(line)}` });
      });
      await pyodide.runPythonAsync(`
import sys, micropip
class _TerrariumStreamingStdout:
    def __init__(self):
        self._buffer = ""
    def write(self, s):
        self._buffer += s
        while "\\n" in self._buffer:
            line, self._buffer = self._buffer.split("\\n", 1)
            if line.strip():
                __terrarium_pip_emit(line)
        return len(s)
    def flush(self):
        if self._buffer.strip():
            __terrarium_pip_emit(self._buffer)
        self._buffer = ""

_old_stdout = sys.stdout
sys.stdout = _TerrariumStreamingStdout()
try:
    await micropip.install(${JSON.stringify(pkg)}, keep_going=True, verbose=True)
finally:
    try: sys.stdout.flush()
    except Exception: pass
    sys.stdout = _old_stdout
`);
      // Clean up the JS hook.
      pyodide.globals.delete("__terrarium_pip_emit");
    }

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
    await pyodide.runPythonAsync(`
import importlib.metadata as _md, shutil, sys, sysconfig, os
from pathlib import Path

pkg_name = ${JSON.stringify(pkg)}
target = pkg_name.lower().replace("-", "_")

# Same dirs listPackages scans — Pyodide's own site-packages PLUS our
# IDBFS mount. We have to clean both so an uninstall actually frees the
# bytes the user expects (whichever dir the package landed in).
search_dirs = []
for key in ("purelib", "platlib"):
    p = sysconfig.get_paths().get(key)
    if p and p not in search_dirs: search_dirs.append(p)
persist = "${PERSIST_DIR}/site-packages"
if persist not in search_dirs:
    search_dirs.append(persist)

# Try micropip first — it's the cleanest path, handles dependencies, and
# updates micropip's own bookkeeping. Falls through to manual cleanup
# below if micropip can't find or uninstall the package.
try:
    import micropip
    if hasattr(micropip, "uninstall"):
        micropip.uninstall(pkg_name)
except Exception:
    pass

# Manual cleanup: scan each site-packages dir for the package's files
# and remove them. Match by normalized name (PyPI normalizes - and _).
for site in search_dirs:
    if not os.path.isdir(site):
        continue
    for entry in os.listdir(site):
        low = entry.lower().replace("-", "_")
        if low == target or low.startswith(target + "-"):
            full = os.path.join(site, entry)
            try:
                if os.path.isdir(full):
                    shutil.rmtree(full, ignore_errors=True)
                else:
                    os.remove(full)
            except Exception:
                pass

# Drop any importlib-cached refs so a subsequent import doesn't pull
# the now-deleted module from the meta-path cache.
for mod in list(sys.modules.keys()):
    if mod == target or mod.startswith(target + "."):
        sys.modules.pop(mod, None)
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
    // Pyodide's `loadPackage` installs into its own internal site-
    // packages dir (`sysconfig.get_paths()["purelib"]`), NOT into our
    // /persist IDBFS mount. micropip with no `target` argument also
    // lands there. So we have to scan BOTH locations to find every
    // user-installed package.
    //
    // We also filter out packages that ship as part of Pyodide's base
    // distribution (the ~30 things loaded at bootstrap — micropip,
    // distutils, etc.) so the list only shows packages the user
    // actually triggered an install for. We do that by reading the
    // `name` from each dist-info's `INSTALLER` file when present —
    // packages installed by `loadPackage` get an INSTALLER of
    // "pyodide.loadPackage", which is exactly what we want to surface.
    const json = await pyodide.runPythonAsync(`
import importlib.metadata as _md, json, os, sys, sysconfig
from pathlib import Path

# Every site-packages dir Python knows about (Pyodide's + our IDBFS mount).
search_dirs = []
for key in ("purelib", "platlib"):
    p = sysconfig.get_paths().get(key)
    if p and p not in search_dirs: search_dirs.append(p)
persist = "${PERSIST_DIR}/site-packages"
if persist not in search_dirs:
    search_dirs.append(persist)

# Packages we never want to surface as "user-installed" — these come
# with the Pyodide WASM runtime itself and the user didn't install them.
BUILTIN_BASELINE = {
    "distutils", "pip", "setuptools", "wheel", "pkg_resources",
    # micropip is the package installer; we load it during bootstrap.
    # Listing it would be confusing.
    "micropip",
}

result = []
seen = set()
for d in search_dirs:
    if not os.path.isdir(d):
        continue
    for entry in sorted(os.listdir(d)):
        if not entry.endswith(".dist-info"):
            continue
        try:
            dist = _md.PathDistribution(Path(d) / entry)
            name = (dist.metadata.get("Name") or
                    entry.rsplit("-", 1)[0]).strip()
            key = name.lower()
            if key in seen:
                continue
            if key in BUILTIN_BASELINE:
                continue
            seen.add(key)

            size = 0
            for f in dist.files or []:
                try: size += dist.locate_file(f).stat().st_size
                except Exception: pass

            result.append({
                "name": name,
                "version": dist.version or "—",
                "size": size,
            })
        except Exception:
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
