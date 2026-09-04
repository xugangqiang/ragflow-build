# ragflow-build

Vendored third-party dependencies and their release pipelines.

Each dependency owns a self-contained directory at the repository root:

```
.
├── .github/workflows/           # release pipelines (GitHub requires this path)
│   └── onnxruntime-release.yml
└── onnxruntime/                 # everything for this dependency
    ├── ORT_VERSION              # pinned upstream tag, e.g. v1.29.0
    ├── build.sh                 # build entry point
    ├── scripts/
    │   ├── init-submodules.sh       # fetch + pin the upstream source
    │   ├── package.sh               # assemble the distribution archive
    │   ├── build-macos-universal.sh # arm64 + x86_64 -> lipo
    │   └── cross-linux-aarch64.sh   # x86_64 -> aarch64 cross build
    ├── build/                   # build trees (git ignored)
    ├── dist/                    # release artifacts (git ignored)
    └── onnxruntime/             # upstream git submodule (microsoft/onnxruntime)
```

Adding another dependency later means adding one more top-level directory plus
one more workflow file — nothing here is onnxruntime specific except the
directory itself.

---

## onnxruntime

Pinned to **v1.29.0** (see `onnxruntime/ORT_VERSION`).

### 1. Get the sources

```bash
git clone <this-repo> ragflow-build
cd ragflow-build
bash onnxruntime/scripts/init-submodules.sh
```

This registers the submodule, checks out exactly the tag in `ORT_VERSION` and
pulls the recursive build dependencies. Use `--full` for an unshallow clone.

### 2. Build

```bash
cd onnxruntime
./build.sh \
    --config Release \
    --cmake_extra_defines onnxruntime_BUILD_SHARED_LIB=OFF \
    --minimal_build \
    --disable_contrib_ops \
    --disable_ml_ops \
    --disable_rtti \
    --disable_exceptions \
    --parallel
```

All of the flags above are already the defaults, so a plain `./build.sh` is
identical. Anything you pass is forwarded to upstream
`tools/ci_build/build.py`; project managed options take precedence:

| Option | Description |
| --- | --- |
| `--target <name>` | `linux-x86_64`, `linux-aarch64`, `osx-arm64`, `osx-x86_64`, `osx-universal`, `windows-x64`, `windows-arm64`. Default: detected from the host. |
| `--build-dir <path>` | Build root. Default `onnxruntime/build/<target>`. |
| `--dist-dir <path>` | Where the archive lands. Default `onnxruntime/dist`. |
| `--update` | Run `git submodule update --init --recursive` first. |
| `--clean` | Wipe the build directory for this target first. |
| `--no-package` | Build only, skip the tarball/zip. |
| `-h`, `--help` | Full help. |

Extra defaults applied on top:

- `--skip_tests` — upstream `build.py` runs ctest by default, which downloads
  hundreds of MB of ONNX test data. Pass `--test` to opt back in.
- `--cmake_generator Ninja` — unix only, and only when ninja is installed.
  Windows keeps the Visual Studio generator.
- `--compile_no_warning_as_error` — new compilers trip `-Werror` upstream.
- `--allow_running_as_root` — only when running as root.

Build trees are platform specific: `onnxruntime/build/<target>` for most
targets, and `onnxruntime/build/osx-universal/{arm64,x86_64,universal}` for the
universal build.

### 3. Artifacts

`onnxruntime/dist/onnxruntime-<version>-<target>.tar.gz` (`.zip` on Windows)
plus a `.sha256` file:

```
onnxruntime-v1.29.0-linux-x86_64/
├── BUILD_INFO.txt        # version, target, commit, configuration
├── LICENSE
├── include/              # public headers, flattened like upstream packages
│   ├── onnxruntime_c_api.h
│   ├── onnxruntime_cxx_api.h
│   ├── cpu_provider_factory.h
│   └── ...
└── lib/
    └── libonnxruntime.a  # single fat static library
```

Windows produces `lib/onnxruntime.lib` and a `.zip` instead of a `.tar.gz`.

A static build has no single self-contained `libonnxruntime.a`: the
`onnxruntime` CMake target is an `INTERFACE` library that pulls in the
component libs listed in `onnxruntime_INTERNAL_LIBRARIES` (session, optimizer,
providers, framework, graph, util, mlas, common, flatbuffers) plus the external
deps (abseil, onnx, onnx_proto, protobuf, re2, ...). `scripts/package.sh`
collects every archive in the build tree and merges them into one fat library
(`ar -M` MRI script on Linux, `libtool -static` on macOS, MSVC `lib.exe` on
Windows), so consumers only need:

```bash
g++ app.cc -I<pkg>/include <pkg>/lib/libonnxruntime.a -lpthread -ldl -lm -o app
```

Because everything lives in one archive, the linker rescans it until all
symbols resolve — no manual link order is needed. Use `g++` (or add
`-lstdc++`): this is a C++ library even when your own code is C.

---

## Releasing

`.github/workflows/onnxruntime-release.yml` builds all six targets in parallel
and publishes them to a GitHub release.

Triggers:

| Trigger | Behaviour |
| --- | --- |
| push tag `v*` | Build all targets, publish a **public** release on that tag. |
| `workflow_dispatch` | Manual run. Optional `ort_version` overrides `ORT_VERSION`; `draft` (default on) and `dry_run` are available. |

```bash
git tag v1.29.0 && git push origin v1.29.0
```

Runner mapping:

| Target | Runner | Notes |
| --- | --- | --- |
| `linux-x86_64` | `ubuntu-latest` | native |
| `linux-aarch64` | `ubuntu-24.04-arm` | native arm64 |
| `osx-arm64` | `macos-latest` | native arm64 |
| `osx-universal` | `macos-latest` | two slices merged with `lipo` |
| `windows-x64` | `windows-latest` | Visual Studio generator |
| `windows-arm64` | `windows-latest` | MSVC `amd64_arm64` cross tools |

### Notes

- **linux-aarch64 without an arm runner.** `ubuntu-24.04-arm` requires a
  public repository or a paid plan. On `ubuntu-latest` the build script detects
  the mismatched host and falls back to `scripts/cross-linux-aarch64.sh`, which
  installs `crossbuild-essential-arm64` and cross compiles. Change `os` in the
  workflow matrix to switch.
- **Windows generator.** The script deliberately keeps the default Visual
  Studio generator on Windows; ninja is only auto-selected on unix where the
  toolchain is already on `PATH`. Pass `--cmake_generator Ninja` from a
  developer prompt to override.
- **Reproducibility.** `build.sh` re-checks out the pinned tag whenever the
  submodule work tree is clean, so a stale checkout cannot silently end up in a
  release.
