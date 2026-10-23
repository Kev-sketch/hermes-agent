---
sidebar_position: 7
title: "macOS on Intel (x86_64)"
description: "Build and run Hermes Agent natively on an Intel Mac running macOS Ventura 13.x"
---

# macOS on Intel (x86_64)

:::warning Fork-only
Upstream lists **macOS on x86 (Intel) processors** as
[unsupported](./platform-support.md#unsupported) and states that PRs to fix it
will not be accepted. This page documents a **fork-only** path: it works, but it
is not an upstream commitment, and upstream may remove the compatibility it
depends on at any time. Nothing here requires Rosetta.
:::

Hermes runs natively on Intel Macs. Two things in the stock install assume
Apple Silicon, and both fail *quietly* rather than loudly — which is why this
page exists instead of a one-line note.

## What was actually broken

### 1. The CJK tokenizer build (`native/fts5_cjk/build.sh`)

The only C target Hermes compiles at install time failed to link on macOS:

```
Undefined symbols for architecture x86_64:
  "_sqlite3_bind_pointer", referenced from:
      _sqlite3_ftscjk_init in fts5_cjk-....o
  "_sqlite3_finalize", referenced from:
      ...
ld: symbol(s) not found for architecture x86_64
clang: error: linker command failed with exit code 1
```

The script probed for the *presence* of the system `sqlite3ext.h`:

```bash
if ! echo '#include <sqlite3ext.h>' | gcc -E -xc - >/dev/null 2>&1; then
  CFLAGS_EXTRA="-Ivendor"
fi
```

Apple's SDK ships that header, so the probe passed and the vendored copy was
skipped. But the Apple header opens with:

```c
#ifndef SQLITE_OMIT_LOAD_EXTENSION
# define SQLITE_OMIT_LOAD_EXTENSION
#endif
```

Defining `SQLITE_OMIT_LOAD_EXTENSION` suppresses the
`sqlite3_* → sqlite3_api->...` macro redirection that a *loadable* extension
needs. The header still preprocesses cleanly, so the probe cannot see the
problem; every `sqlite3_*` call compiles into an undefined symbol and the link
fails. Presence is not usability.

**Fix:** probe for usability — only prefer the system header when it does *not*
define `SQLITE_OMIT_LOAD_EXTENSION`. The vendored header never does, which is
what makes the Intel build work. This is upstreamable as a straight bug fix.

### 2. Homebrew assumed to be Apple Silicon

Intel Homebrew installs to `/usr/local`; Apple Silicon uses `/opt/homebrew`.
Two tables only knew the Apple Silicon prefix:

- `hermes_platform/resolver/known_dirs.py::homebrew_dirs()` returned
  `("/opt/homebrew/bin", "/usr/local/bin")`, which misses a Homebrew clone that
  was not linked into `/usr/local` (a normal Intel layout — `brew` and the
  tools it installs live under `/usr/local/Homebrew/bin`).
- `tools/browser_tool_install.py::_discover_homebrew_node_dirs()` scanned only
  `/opt/homebrew/opt`, so a versioned `node@NN` installed by Intel Homebrew was
  never found.

**Fix:** both now probe every macOS Homebrew prefix. The prefix that does not
exist simply yields nothing, so the tables stay OS-branch-free.

### 3. What was *not* broken

Worth stating plainly, because the failure list is short:

- `pyproject.toml` has no arm64-only dependency. `nemo-relay` is gated
  `sys_platform == 'darwin' and platform_machine == 'arm64'`, so on Intel it is
  simply not installed — no resolution failure.
- `uv` resolves `cpython-3.11-macos-x86_64` and Intel wheels for every core
  dependency. No source builds, no Rosetta.
- `hermes_platform.host.facts.native_arch()` reports `amd64` correctly.
- The TUI (`ui-tui`) and the Python CLI both build and run natively.

## Prerequisites

| Requirement | Notes |
| --- | --- |
| macOS 13.x (Ventura) on x86_64 | Tested on 13.7.8. Older releases are untested. |
| Xcode Command Line Tools | `xcode-select --install`. Provides `gcc`/`clang` for the tokenizer. |
| [uv](https://docs.astral.sh/uv/) | Installs Python 3.11 and resolves Intel wheels. |
| Git | To clone the fork. |
| Node.js 22.22+, 24.11+, or 26+ | Optional — only needed for the TUI and browser tools. |
| Homebrew | Optional. Either prefix works (`/usr/local` or `/opt/homebrew`). |

Confirm you are on native Intel, not a translated shell:

```bash
uname -m                              # x86_64
sysctl -n sysctl.proc_translated      # 0 (1 means Rosetta)
sw_vers -productVersion               # 13.x
```

If `sysctl.proc_translated` prints `1`, you are in a Rosetta shell. Open a
native terminal before building — a translated shell produces a build that only
runs under translation.

## Build

From a clean clone of this fork:

```bash
git clone <fork-url> hermes-agent
cd hermes-agent
git checkout fix/macos-ventura-intel

./scripts/build-macos-intel.sh
```

The script creates a venv at `~/.hermes/venvs/hermes-intel`, installs the
`all,dev` extras, builds and probes the CJK tokenizer, builds the TUI when its
Node deps are present, and then asserts that **every** Mach-O artifact in the
venv carries an `x86_64` slice. Universal binaries pass; arm64-only ones fail
the build.

Environment overrides:

| Variable | Default | Purpose |
| --- | --- | --- |
| `HERMES_INTEL_VENV` | `~/.hermes/venvs/hermes-intel` | venv location (kept outside the source tree) |
| `HERMES_HOME` | `~/.hermes` | Hermes state directory |
| `HERMES_EXTRAS` | `all,dev` | pip extras to install |

Re-check an existing install without rebuilding:

```bash
./scripts/build-macos-intel.sh --verify
```

## Verify the build is native

```bash
VENV=~/.hermes/venvs/hermes-intel

# Python and the interpreter itself
"$VENV/bin/python" -c "import platform; print(platform.machine())"   # x86_64

# The tokenizer must be an x86_64 Mach-O bundle
file ~/.hermes/lib/libfts5_cjk.so
# -> Mach-O 64-bit bundle x86_64

# Nothing may link against an arm64-only library
otool -L ~/.hermes/lib/libfts5_cjk.so

# The compiled native extension with the most moving parts
file "$VENV"/lib/python3.11/site-packages/uvloop/loop.cpython-311-darwin.so
# -> Mach-O 64-bit bundle x86_64
```

A dependency that ships a *universal* binary (e.g. `charset_normalizer`,
`httptools`) is fine: `file` prints both slices and the x86_64 one is used.

## Smoke test

Three checks, cheapest first:

```bash
VENV=~/.hermes/venvs/hermes-intel

# 1. The CLI starts and reports its version.
"$VENV/bin/python" -m hermes_cli.main --version

# 2. Platform facts identify this host correctly.
"$VENV/bin/python" - <<'PY'
from hermes_platform.host import facts
assert facts.native_arch() == "amd64", facts.native_arch()
print("native_arch OK:", facts.native_arch())
PY

# 3. The tokenizer loads into SQLite and indexes CJK text.
"$VENV/bin/python" - <<'PY'
import sqlite3, os
conn = sqlite3.connect(":memory:")
conn.enable_load_extension(True)
conn.load_extension(os.path.expanduser("~/.hermes/lib/libfts5_cjk.so"))
conn.execute("CREATE VIRTUAL TABLE t USING fts5(body, tokenize='cjk_unicode61')")
conn.execute("INSERT INTO t VALUES ('日本語テスト hello')")
assert conn.execute("SELECT * FROM t WHERE t MATCH '日本'").fetchall()
print("cjk_unicode61 OK")
PY
```

Then the interactive checks:

```bash
"$VENV/bin/hermes doctor      # environment diagnosis
"$VENV/bin/hermes             # interactive CLI
```

`hermes doctor` will report missing API keys and optional tool dependencies on a
fresh install. That is expected and unrelated to architecture.

## Tests

Run the suites that cover the code this fork touches:

```bash
VENV=~/.hermes/venvs/hermes-intel
"$VENV/bin/python" -m pytest \
  tests/hermes_platform/ \
  tests/test_managed_runtime_resolution.py \
  tests/tools/test_browser_homebrew_paths.py \
  tests/hermes_state/test_fts_cjk_bigram.py \
  -q
```

Upstream's canonical runner is `scripts/run_tests.sh`, but it probes for a venv
named `.venv`/`venv` inside the checkout; point it at this venv explicitly if you
want full CI parity:

```bash
VIRTUAL_ENV=~/.hermes/venvs/hermes-intel ./scripts/run_tests.sh tests/hermes_platform/
```

## Upstream vs fork-only

| Change | File | Upstreamable? |
| --- | --- | --- |
| Probe `sqlite3ext.h` usability, not presence | `native/fts5_cjk/build.sh` | **Yes** — plain macOS link bug, affects Apple Silicon too when the system header is present |
| Probe both Homebrew prefixes | `hermes_platform/resolver/known_dirs.py` | **Yes** — no OS branch, wrong prefix is an absent dir |
| Scan both Homebrew `opt` trees for `node@NN` | `tools/browser_tool_install.py` | **Yes** — same reasoning |
| `scripts/build-macos-intel.sh` | new file | **Fork-only** — upstream rejects Intel macOS PRs |
| This page | `website/docs/getting-started/macos-ventura-intel.md` | **Fork-only** |

The three code fixes are genuine cross-platform bugs: each one also changes
behaviour on Apple Silicon when the Apple SDK header is in play or when a
versioned Node lives under a non-default prefix. They are kept as separate,
minimal diffs so they can be lifted upstream independently of the fork.

## Known limitations

- **Desktop app.** This page covers the CLI, TUI, and gateway. The Electron
  desktop app is not covered by `build-macos-intel.sh`; upstream ships it
  Apple Silicon only, and packaging it for Intel is out of scope here.
- **`hermes update`.** The fork is a git checkout; `hermes update` tracks
  upstream and will discard these patches. Re-apply or rebase after updating.
- **Wake word.** `tools/wake_word.py` selects the tflite backend only on
  macOS arm64 and onnx everywhere else. On Intel that is the correct default
  (the arm64 workaround does not apply), so this is noted, not patched.
- **Upstream churn.** Upstream may drop the vendored-header fallback or change
  the tokenizer build entirely. Re-run `--verify` after rebasing.
