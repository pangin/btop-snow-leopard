# Reusable Snow Leopard link stacks

This directory is a project-independent linker kit for Mac OS X 10.6.8 i386
projects built with MacPorts Clang 16. Each compatibility layer is a separate
stack fragment, and `relink.sh` composes the selected fragments into one final
link command.

Available stacks:

- `apple-system-frameworks` — IOKit and CoreFoundation.
- `llvm16-libcxx-static` — Clang 16's static libc++ and libc++abi archives.
- `macports-legacy-support` — the LegacySupport library and MacPorts library path.
- `snow-leopard` — the three stacks above in the tested btop order.

Use it from another project by copying this directory or consuming it as a
git subtree:

```sh
LINK_STACK=/path/to/btop-snow-leopard-v1.4.7/toolchains/snow-leopard

"$LINK_STACK/relink.sh" \
  --compiler /opt/local/bin/clang++-mp-16 \
  --stack snow-leopard \
  --output bin/example \
  --object obj/main.o \
  --object obj/worker.o \
  --validate
```

Set `MACPORTS_PREFIX` and `LLVM_PREFIX` when the toolchain is installed
somewhere other than `/opt/local`. Use `--dry-run` to inspect the exact link
command, or pass individual `--stack` options when a project needs only part
of the compatibility layer.

The composer emits one token per line and the relinker appends each token as a
separate argv entry. It does not use `eval`, so the stack composition remains
safe to reuse from other build systems.
