# SDL2 source archive

- Upstream: `https://www.libsdl.org/release/SDL2-2.26.5.tar.gz`
- Version: `2.26.5`
- Release tag: `release-2.26.5`
- Tag commit: `ac13ca9ab691e13e8eebe9684740ddcb0d716203`
- Archive SHA-256: `AD8FEA3DA1BE64C83C45B1D363A6B4BA8FD60F5BDE3B23EC73855709EC5EABF7`
- License: Zlib; `COPYING.txt` is included inside the upstream archive.
- Imported: 2026-08-26

The Mac native host verifies and extracts this pinned archive into `out` during
CMake configuration, then links SDL2 statically. The existing Windows host keeps
using the organizer-supplied SDL 2.26.5 development package under
`src/common/egfx/test/sdl/sdl2`.
