# MediaRemoteAdapter (vendored)

- **Upstream:** https://github.com/ungive/mediaremote-adapter
- **Commit:** `797729d9b16316dc313844476c153d7a107ca0df` (2026-10-10)
- **Licence:** BSD 3-Clause, see `LICENSE`
- **Modifications:** none. `scripts/`, `Makefile`, `README.md` and the CI files were left out.

Built by `tools/build-mediaremote-adapter.sh` from an Xcode Run Script phase, rather than by
CMake. `CMakeLists.txt` is kept only as the reference for which sources and flags upstream uses.

At runtime the app runs `/usr/bin/perl bin/mediaremote-adapter.pl <framework> <command>`. The
framework is never linked into the app. Perl is Apple-signed, so `mediaremoted` answers it.

To update: replace `src/`, `include/`, `bin/`, `LICENSE` and `CMakeLists.txt` from a new upstream
commit, update the hash above, and diff `CMakeLists.txt` for new sources or flags.
