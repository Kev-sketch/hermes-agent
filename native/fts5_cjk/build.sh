#!/bin/bash
# Build libfts5_cjk.so and install to ~/.hermes/lib/ (or $1).
#
# Uses the system sqlite3ext.h when it is USABLE, else the vendored copy in
# vendor/ (public-domain SQLite amalgamation headers) so the build works
# without libsqlite3-dev installed.
#
# "Present" is not "usable". Apple's SDK ships sqlite3ext.h, but it opens with
#
#     #ifndef SQLITE_OMIT_LOAD_EXTENSION
#     # define SQLITE_OMIT_LOAD_EXTENSION
#     #endif
#
# which suppresses the `sqlite3_*  ->  sqlite3_api->...` macro redirection that
# a loadable extension needs. The header compiles fine on its own, so a
# "does #include <sqlite3ext.h> work?" probe says yes, and the build then dies at
# link time with undefined symbols for every sqlite3_* call on macOS:
#
#     Undefined symbols for architecture x86_64:
#       "_sqlite3_bind_pointer", referenced from:
#           _sqlite3_ftscjk_init in fts5_cjk-....o
#     ld: symbol(s) not found for architecture x86_64
#
# So probe for usability, not existence: the system header only wins when it
# does NOT define SQLITE_OMIT_LOAD_EXTENSION. The vendored header never does,
# which is what makes the Intel/Ventura build work.
set -euo pipefail
cd "$(dirname "$0")"

CFLAGS_EXTRA=""
if ! printf '#include <sqlite3ext.h>\n#ifdef SQLITE_OMIT_LOAD_EXTENSION\n#error system sqlite3ext.h disables loadable extensions\n#endif\n' \
     | gcc -E -xc - >/dev/null 2>&1; then
  CFLAGS_EXTRA="-Ivendor"
fi

gcc -shared -fPIC -O2 -Wall -Wextra $CFLAGS_EXTRA fts5_cjk.c -o libfts5_cjk.so
dest="${1:-$HOME/.hermes/lib}"
mkdir -p "$dest"
install -m 0644 libfts5_cjk.so "$dest/libfts5_cjk.so"
echo "installed: $dest/libfts5_cjk.so"
