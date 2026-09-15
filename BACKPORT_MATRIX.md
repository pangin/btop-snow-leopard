# Release backport matrix

The upstream project has 55 GitHub release tags from v1.0.0 through v1.4.7.
They fall into three compatibility groups for Snow Leopard:

| Upstream releases | Count | Upstream macOS backend | Current state |
| --- | ---: | --- | --- |
| v1.0.0-v1.0.24 | 25 | No | Backend transplant generated and statically audited; target builds pending |
| v1.1.0-v1.4.6 | 29 | Yes | v1.1.0 target build/TUI passed; remaining target matrix queued |
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
