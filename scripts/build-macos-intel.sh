#!/usr/bin/env bash
# Build and install Hermes Agent natively on Intel macOS (x86_64, Ventura 13.x).
#
# Why this script exists: the stock instructions assume an Apple Silicon
# Homebrew (/opt/homebrew) and never touch the one C target Hermes compiles at
# install time. On Intel those two assumptions are what break, in ways that are
# silent rather than loud. This script makes the Intel path explicit, verifies
# every native artifact is x86_64, and fails loudly instead of degrading.
#
# Usage:
#   scripts/build-macos-intel.sh            # build into $HERMES_INTEL_VENV
#   scripts/build-macos-intel.sh --verify   # build, then re-check every artifact
#
# Environment:
#   HERMES_INTEL_VENV   venv path (default: ~/.hermes/venvs/hermes-intel)
#   HERMES_HOME         Hermes state dir (default: ~/.hermes)
#   HERMES_EXTRAS       pip extras (default: "all,dev")
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${HERMES_INTEL_VENV:-$HOME/.hermes/venvs/hermes-intel}"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
EXTRAS="${HERMES_EXTRAS:-all,dev}"
VERIFY_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --verify) VERIFY_ONLY=true ;;
    -h|--help)
      sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ── Preconditions ───────────────────────────────────────────────────────────

say "Checking host"
[ "$(uname -s)" = "Darwin" ] || die "this script targets macOS; uname -s is $(uname -s)"

ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || die "expected an Intel host (x86_64), got '$ARCH'.
On Apple Silicon the stock install path already works — use scripts/install.sh."

# Rosetta check: an x86_64 shell on an arm64 host is exactly the state we must
# not silently accept, because everything it builds is x86_64 that only runs
# under translation.
if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
  die "this shell is running under Rosetta (sysctl.proc_translated=1).
Build from a native arm64 shell, or run this script on an Intel Mac.
A Rosetta-built Hermes is not a native build and is out of scope."
fi

MACOS_VER="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VER%%.*}"
say "Host: macOS $MACOS_VER ($(sw_vers -buildVersion)) on $ARCH"
if [ "$MACOS_MAJOR" -lt 13 ]; then
  warn "macOS $MACOS_VER is older than the tested Ventura 13.x baseline; continuing anyway"
fi

command -v gcc >/dev/null 2>&1 || die "no C compiler. Install Xcode Command Line Tools: xcode-select --install"
command -v uv  >/dev/null 2>&1 || die "uv not found. Install it: curl -LsSf https://astral.sh/uv/install.sh | sh"

# Homebrew is optional for the core build, but report the prefix: the whole
# point of this port is that Intel Homebrew does not live in /opt/homebrew.
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null || echo unknown)"
  say "Homebrew prefix: $BREW_PREFIX"
  case "$BREW_PREFIX" in
    /opt/homebrew) warn "Homebrew reports /opt/homebrew on an Intel host — that is unusual; PATH tables assume both prefixes are probed" ;;
  esac
else
  warn "Homebrew not found; optional for the core build"
fi

# ── Verification helper ─────────────────────────────────────────────────────

# Assert every Mach-O artifact under a tree carries an x86_64 slice. Universal
# binaries are accepted (they run natively here); arm64-only ones are not.
verify_x86_64() {
  local root="$1" bad=0 total=0
  while IFS= read -r -d '' f; do
    case "$(file -b "$f" 2>/dev/null)" in
      *Mach-O*)
        total=$((total + 1))
        case "$(file -b "$f")" in
          *x86_64*) ;;
          *) printf '  NOT x86_64: %s\n' "$f"; bad=$((bad + 1)) ;;
        esac
        ;;
    esac
  done < <(find "$root" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0 2>/dev/null)
  if [ "$bad" -ne 0 ]; then
    return 1
  fi
  say "verified $total Mach-O artifact(s) under $root carry an x86_64 slice"
}

if [ "$VERIFY_ONLY" = true ]; then
  [ -d "$VENV" ] || die "no venv at $VENV — run without --verify first"
  verify_x86_64 "$VENV" || die "found non-x86_64 native artifacts (see above)"
  exit 0
fi

# ── Python environment ──────────────────────────────────────────────────────

# The venv lives OUTSIDE the source tree on purpose: a venv inside the
# directory the agent operates from can be destroyed by a relative-path command
# the agent runs against its own checkout.
say "Creating venv at $VENV (Python 3.11)"
mkdir -p "$(dirname "$VENV")"
uv venv "$VENV" --python 3.11 --allow-existing

export VIRTUAL_ENV="$VENV"
export PATH="$VENV/bin:$PATH"

say "Installing Hermes with extras [$EXTRAS]"
# --no-build-isolation is not used: uv resolves wheels for x86_64 darwin from
# the lockfile and only falls back to a source build for packages with no
# Intel macOS wheel, which is the case this script is designed to surface.
uv pip install -e "$REPO_ROOT[$EXTRAS]"

# ── Native tokenizer (the one C target built at install time) ───────────────

say "Building the CJK FTS5 tokenizer"
# native/fts5_cjk/build.sh probes whether the SYSTEM sqlite3ext.h is *usable*,
# not merely present. Apple's SDK header defines SQLITE_OMIT_LOAD_EXTENSION,
# which strips the sqlite3_* macro redirection a loadable extension needs, so
# a presence-only probe passes and the link then fails with undefined
# sqlite3_* symbols. The vendored header in native/fts5_cjk/vendor is used
# instead whenever the system one is poisoned.
mkdir -p "$HERMES_HOME_DIR/lib"
( cd "$REPO_ROOT/native/fts5_cjk" && bash build.sh "$HERMES_HOME_DIR/lib" )

CJK_SO="$HERMES_HOME_DIR/lib/libfts5_cjk.so"
[ -f "$CJK_SO" ] || die "tokenizer build produced no $CJK_SO"

say "Probing the tokenizer"
"$VENV/bin/python" - "$CJK_SO" <<'PY'
import sqlite3, sys
path = sys.argv[1]
conn = sqlite3.connect(":memory:")
conn.enable_load_extension(True)
try:
    conn.load_extension(path)
    conn.execute("CREATE VIRTUAL TABLE t USING fts5(body, tokenize='cjk_unicode61')")
    conn.execute("INSERT INTO t VALUES ('日本語テスト hello')")
    rows = conn.execute("SELECT * FROM t WHERE t MATCH '日本'").fetchall()
except Exception as exc:  # noqa: BLE001 - any failure here means a broken artifact
    raise SystemExit(f"tokenizer unusable: {exc}")
if not rows:
    raise SystemExit("tokenizer loaded but returned no match for a 2-char CJK term")
print(f"cjk_unicode61 OK ({len(rows)} match)")
PY

# ── Node / TUI (optional, only if the workspace deps are installed) ─────────

if command -v npm >/dev/null 2>&1 && [ -d "$REPO_ROOT/ui-tui/node_modules" ]; then
  say "Building the TUI"
  ( cd "$REPO_ROOT/ui-tui" && npm run build )
else
  warn "skipping the TUI build (run 'npm install --workspace ui-tui' to enable it)"
fi

# ── Architecture verification ───────────────────────────────────────────────

say "Verifying every native artifact is x86_64"
verify_x86_64 "$VENV" || die "found non-x86_64 native artifacts (see above)"

# ── Smoke test ──────────────────────────────────────────────────────────────

say "Smoke testing the CLI"
"$VENV/bin/python" -m hermes_cli.main --version

say "Done"
cat <<EOF

Hermes is installed natively for x86_64 at:
  venv:  $VENV
  state: $HERMES_HOME_DIR

Run it with:
  $VENV/bin/hermes

If you have not configured a provider yet:
  $VENV/bin/hermes setup

EOF
