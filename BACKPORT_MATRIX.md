# Release backport matrix

The upstream project has 55 GitHub release tags from v1.0.0 through v1.4.7.
They fall into three compatibility groups for Snow Leopard:

| Upstream releases | Count | Upstream macOS backend | Current state |
| --- | ---: | --- | --- |
| v1.0.0-v1.0.24 | 25 | No | Backend transplant generated and statically audited; target builds pending |
| v1.1.0-v1.4.6 | 29 | Yes | Source matrix generated and statically audited; target builds in progress |
| v1.4.7 | 1 | Yes | Built, runtime-tested, installed, and published |

The v1.0.0-v1.4.6 source matrix is generated with:

```powershell
./scripts/New-SourceMatrix.ps1 -OutputPath ../artifacts/source-matrix
```

The generator checks every prepared tree for the Snow Leopard VM field,
process-I/O guard, 32-bit disk-size widening, unavailable IOReport linkage,
Clang runner signalling, terminal input, C++23 flag spelling, and
`ranges::to` use in macOS-compiled sources. It writes JSON and tab-separated
SHA-256 source manifests alongside the generated archives.

Version-specific binaries and tags are published only after compiling and
running them on the actual Mac OS X 10.6.8 i386 target. A generated source
archive alone is not counted as a completed backport.

The v1.0.x line predates upstream macOS releases. Its generator retains each
historical tag's core and transplants the official macOS backend merged just
after v1.0.24 in upstream commit `c0e17a6`; it does not relabel a later binary.
Every release still has to compile and run independently on the 10.6.8 Mac.

## New-release detection

`.github/workflows/detect-upstream-release.yml` checks the official btop
latest release daily and can also be started manually with a specific tag. If
the matching `*-snow-leopard.1` tag is not present in this repository, it
fetches the upstream tag, prepares the Snow Leopard source archive, uploads it
as a workflow artifact, and opens a tracking issue. The workflow stops at the
source/evidence hand-off: binary publication remains gated on a real Mac OS X
10.6.8 i386 build and TUI test.
