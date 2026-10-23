"""Directories where tools install outside PATH, grouped by the ecosystem that owns them.

Every table in Hermes lives here. A directory literal outside this module fails the ratchet in
`tests/test_managed_runtime_resolution.py`. Each table is empty on an OS where the ecosystem
does not install there, so callers compose tables without OS branches.
"""

from __future__ import annotations

import sys

_POSIX = sys.platform != "win32"
_WIN = sys.platform == "win32"


def homebrew_dirs() -> tuple[str, ...]:
    """Homebrew ``bin`` dirs, both prefixes, on macOS.

    Homebrew installs to ``/opt/homebrew`` on Apple Silicon and ``/usr/local``
    on Intel, so both are listed on every macOS host: the wrong one is simply a
    directory that does not exist, and callers already probe for presence. A
    table naming only ``/opt/homebrew`` makes every Intel host resolve
    Homebrew-installed tools through the ambient PATH or not at all.

    ``/usr/local/Homebrew/bin`` is where a Homebrew clone that was not linked
    into ``/usr/local`` keeps its own commands (``brew`` itself, ``cmake``,
    ``pkg-config``); it is a normal layout on Intel and is absent elsewhere.
    """
    if sys.platform != "darwin":
        return ()
    return ("/opt/homebrew/bin", "/usr/local/bin", "/usr/local/Homebrew/bin")


def user_local_bin() -> tuple[str, ...]:
    return ("~/.local/bin",) if _POSIX else ("%USERPROFILE%/.local/bin",)


def rust_tool_dirs() -> tuple[str, ...]:
    return ("~/.cargo/bin",) if _POSIX else ("%USERPROFILE%/.cargo/bin",)


def node_tool_dirs() -> tuple[str, ...]:
    return ("~/.npm-global/bin", "~/.bun/bin", "~/.volta/bin") if _POSIX else ("%APPDATA%/npm", "%USERPROFILE%/.bun/bin", "%LOCALAPPDATA%/Volta/bin")


def hermes_vendored_dirs() -> tuple[str, ...]:
    return ("~/.hermes/bin",) if _POSIX else ("%USERPROFILE%/.hermes/bin",)


def windows_user_program_dirs() -> tuple[str, ...]:
    if not _WIN:
        return ()
    return (
        "%LOCALAPPDATA%/Programs",
        "%USERPROFILE%/scoop/shims",
        "%LOCALAPPDATA%/Microsoft/WinGet/Links",
    )
