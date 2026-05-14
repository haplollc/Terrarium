# Terrarium

> Embedded Python 3.13 runtime for iOS & macOS apps, with a one-line API and a SwiftUI runner sheet.

Terrarium runs real Python scripts inside your iOS/macOS app — no server, no transpile, no JS shim for the simple path. For the hard cases (numpy, pandas, matplotlib, scipy, scikit-learn, anything with C extensions that doesn't ship iOS wheels on PyPI) it falls back to **Pyodide**, fetching the runtime + packages from Pyodide's CDN on demand and persisting them across launches.

```swift
import Terrarium

// One-time:
try await Terrarium.shared.initialize()

// Run anything:
let result = await Terrarium.shared.run(code: """
    import requests
    print(requests.get("https://api.github.com/zen").text)
""")
print(result.stdout)
```

That's it. No subprocess. No webview (for the CPython path). The interpreter is in-process.

---

## Features

- **Real CPython 3.13** — bundled via `Python.xcframework`. Pure-Python scripts run natively, fast.
- **`%pip install <pkg>` magic** — Jupyter-style inline installs from inside any script. Resolves against PyPI, downloads the wheel, drops it into a writable user-site-packages directory. Persistent across launches.
- **`%pip uninstall <pkg>` and `%pip list`** also work.
- **Pyodide fallback** for the scientific stack — `import matplotlib` / `import numpy` / `import pandas` etc. routes to a hidden WKWebView running Pyodide. Packages download from jsDelivr's CDN on first import, cache to IndexedDB, and persist forever (until the user deletes them in Settings).
- **Runner sheet** — drop-in SwiftUI view that gives you a Run/Stop toolbar, a Console tab with ANSI color support (rich, colorama, raw escape codes all work), a View tab for rendered images, live install progress, and an inline code editor.
- **Image / chart display** — Python scripts call `terrarium_show.show(figure_or_bytes)`; the runner decodes and displays in a View tab.
- **Package manager UI** — searchable bottom sheet showing CPython-installed + Pyodide-cached packages with per-row delete.
- **Self-contained package** — all resources (Python stdlib, bundled site-packages, lib-dynload, Pyodide host) ship inside the SwiftPM `Bundle.module`. No manual Xcode folder references required.

---

## Installation

### Step 1: Fetch `Python.xcframework`

Terrarium needs the CPython runtime (~112 MB binary). It's not in git because it's a binary blob. Run once after cloning:

```bash
./Scripts/setup-python.sh
```

This pulls the pinned iOS arm64 build from BeeWare's [Python-Apple-support](https://github.com/beeware/Python-Apple-support).

### Step 2: Add the Swift package

In Xcode: `File → Add Package Dependencies` → enter `https://github.com/haplollc/Terrarium`.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/haplollc/Terrarium", from: "1.0.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["Terrarium"]),
],
```

### Step 3: Build & use

```swift
import Terrarium

@main
struct MyApp: App {
    init() {
        Task { try? await Terrarium.shared.initialize() }
    }
    var body: some Scene { … }
}
```

**That's it.** No folder references to add. No SwiftPM resource declarations. `Bundle.module` inside the package has everything: `python-stdlib`, `site-packages`, `lib-dynload`, `pyodide-host`. The package handles its own resource layout.

---

## API

### Run code

```swift
let result = await Terrarium.shared.run(
    code: "print('hello')",
    timeout: 30,
    onProgress: { line in
        // pip-style progress lines stream here in real time
        print(line, terminator: "")
    }
)

print(result.stdout)     // "hello\n"
print(result.stderr)     // ""
print(result.exception)  // nil
print(result.isSuccess)  // true
print(result.durationMs) // 12
```

### `%pip` magic

Inside your script:

```python
%pip install requests humanize        # CPython path, pure-Python wheels
%pip install matplotlib numpy pandas  # Pyodide path, WASM wheels
%pip uninstall humanize
%pip list

import matplotlib.pyplot as plt
plt.plot([1, 2, 3, 2, 5])
```

### Display images from Python

```python
import io, terrarium_show
import matplotlib.pyplot as plt

plt.plot([1, 2, 3])
buf = io.BytesIO()
plt.savefig(buf, format='png')
terrarium_show.show(buf.getvalue())
```

`terrarium_show.show()` also accepts a PIL Image or a matplotlib Figure directly:

```python
from PIL import Image
img = Image.open("photo.png")
terrarium_show.show(img)
```

### Force a specific runtime

By default, Terrarium auto-detects which runtime to use based on imports. To override:

```python
# %runtime pyodide
import some_pure_python_package_i_want_in_pyodide_anyway
```

```python
# %runtime cpython
# Force CPython even though we import numpy (will fail unless you've
# cross-compiled iOS wheels via mobile-forge).
```

### Drop-in runner sheet

If you want the full Console / View / install-progress UI:

```swift
import SwiftUI
import Terrarium

struct ContentView: View {
    @State private var pythonCode: String? = nil

    var body: some View {
        Button("Run script") {
            pythonCode = """
                %pip install matplotlib
                import matplotlib.pyplot as plt, io, terrarium_show
                plt.plot([1, 2, 3, 4, 5])
                buf = io.BytesIO()
                plt.savefig(buf, format='png')
                terrarium_show.show(buf.getvalue())
                """
        }
        .sheet(item: $pythonCode.identifiable) { code in
            PythonCodeRunnerSheet(code: code.value)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}
```

The runner sheet has a toolbar Run/Stop button, segmented Console/View tabs, live install progress, ANSI color support, and inline image rendering.

### Package manager UI

```swift
.sheet(isPresented: $showingPackages) {
    PythonPackageManagerView()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
}
```

Searchable list of installed CPython + Pyodide packages, with per-package delete and cumulative storage size.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Terrarium (Swift, MainActor)                                │
│    └── run(code:) ─→ scan for %pip magics + native imports   │
│                       │                                        │
│         ┌─────────────┴─────────────┐                         │
│         ▼                            ▼                         │
│   PythonRuntimeService        PyodideBridge                   │
│   (CPython.xcframework         (hidden WKWebView,             │
│    in-process)                  Pyodide WASM from CDN,        │
│                                  IDBFS persistent fs)         │
│                                                                │
│   ⬇ pure-Python only          ⬇ numpy/pandas/scipy/         │
│      (requests, bs4, etc.)       matplotlib/sklearn/…          │
└──────────────────────────────────────────────────────────────┘
```

### Why two runtimes?

CPython on iOS is fast and native. But PyPI doesn't publish iOS arm64 wheels for any package with C extensions (numpy, Pillow, matplotlib, scipy, …). Pyodide, the Python-to-WebAssembly project, has pre-built WASM versions of [~250 scientific packages](https://pyodide.org/en/stable/usage/packages-in-pyodide.html). Terrarium uses Pyodide as a fallback specifically for those packages — the runtime is heavier (WebAssembly, runs in a hidden WebView) but gives you the full scientific stack with no per-package iOS build pipeline.

### How `%pip install` routes

| You write | Terrarium does |
|---|---|
| `%pip install requests` | Resolves on PyPI, downloads the pure-Python wheel into the app's user-site-packages dir. |
| `%pip install numpy` | Routes to Pyodide. `micropip.install("numpy")` fetches the WASM wheel from Pyodide CDN, caches to IDBFS. |
| `%pip install some-random-pkg` | Tries CPython first. If the wheel is pure-Python it lands there. If it's a sdist or has native extensions, falls back to Pyodide automatically. |

### Persistence

CPython-installed packages live in `~/Library/Application Support/<bundle>/python/site-packages` — survives app restarts, deletes when the app is uninstalled.

Pyodide-installed packages live in IndexedDB inside the hidden WebView's data store — also survives app restarts. The bridge mounts an IDBFS-backed Python filesystem at `/persist` so installs land in a dir that's auto-synced back to IDB after every install/uninstall.

Users can delete individual packages from the included `PythonPackageManagerView` — each row has a trash icon. CPython packages wipe their directory; Pyodide packages run `micropip.uninstall` + `shutil.rmtree` on the dist-info.

### Where the bundled resources live

After SwiftPM builds the package, `Bundle.module` for the `Terrarium` target contains:

```
Terrarium_Terrarium.bundle/
├── python-stdlib/            (47 MB — CPython 3.13 standard library)
├── site-packages/            (13 MB — curated pure-Python packages)
├── lib-dynload/              (14 MB — C extension shims)
└── pyodide-host/             (small — host.html + JS bridge for the Pyodide WebView)
```

The Swift code reads from `Bundle.module.url(forResource:withExtension:subdirectory:)`. No host-app folder references required.

---

## Limitations

- **iOS / macOS only.** No Linux, no Windows, no Android.
- **iOS 17+ / macOS 14+.** The package manager UI uses `ContentUnavailableView` (iOS 17 / macOS 14 API).
- **Pyodide is slower than CPython** for pure-Python loops (~2-3×) and roughly equivalent on numpy-heavy code (the inner C is still vectorized inside WASM). For typical "fetch + plot" workloads this is invisible.
- **First Pyodide boot is ~2-4 seconds.** The bridge boots eagerly on app startup to hide this.
- **First package install needs network.** Pyodide downloads from jsDelivr's CDN on first import. Once cached, subsequent uses are offline.
- **No JIT.** Both runtimes use the standard CPython interpreter (compiled to WASM in Pyodide's case). PyPy-style speedups aren't on the table.
- **Some Pyodide-incompatible packages** (anything depending on tkinter, system frameworks, or PyPy specifics) can't be installed even via the Pyodide path. Most of the scientific Python ecosystem works.

---

## License

MIT. See [LICENSE](LICENSE).

Bundled Python 3.13 is licensed under the PSF License Agreement.

Bundled site-packages each retain their original license; consult the package's own metadata.

Pyodide is licensed under the Mozilla Public License 2.0.

---

## Credits

Built by [Haplo](https://haploapp.com). Stands on the shoulders of:

- [BeeWare](https://beeware.org/) — `Python-Apple-support` ships the `Python.xcframework` we link against.
- [Pyodide](https://pyodide.org/) — CPython compiled to WebAssembly + the ~250 pre-built WASM wheels of the scientific Python stack.
- [`ZIPFoundation`](https://github.com/weichsel/ZIPFoundation) — wheel extraction.
