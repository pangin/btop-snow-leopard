#!/bin/sh

set -eu

MACPORTS_PREFIX=${MACPORTS_PREFIX:-/opt/local}
LLVM_PREFIX=${LLVM_PREFIX:-$MACPORTS_PREFIX/libexec/llvm-16}

printf '%s\n' \
	-nostdlib++ \
	"$LLVM_PREFIX/lib/libc++/libc++.a" \
	"$LLVM_PREFIX/lib/libc++/libc++abi.a"
