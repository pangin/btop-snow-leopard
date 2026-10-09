#!/bin/sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
stack_root=$repo_root/toolchains/snow-leopard
actual=$(MACPORTS_PREFIX=/opt/local LLVM_PREFIX=/opt/local/libexec/llvm-16 "$stack_root/compose-link-stack.sh" --stack snow-leopard)

printf '%s\n' "$actual" | grep -Fx -- '-framework' >/dev/null
printf '%s\n' "$actual" | grep -Fx -- 'IOKit' >/dev/null
printf '%s\n' "$actual" | grep -Fx -- '-nostdlib++' >/dev/null
printf '%s\n' "$actual" | grep -Fx -- '/opt/local/libexec/llvm-16/lib/libc++/libc++.a' >/dev/null
printf '%s\n' "$actual" | grep -Fx -- '-lMacportsLegacySupport' >/dev/null

dry_run=$(MACPORTS_PREFIX=/opt/local LLVM_PREFIX=/opt/local/libexec/llvm-16 "$stack_root/relink.sh" --compiler clang++ --stack snow-leopard --output bin/example --object obj/main.o --dry-run)
printf '%s\n' "$dry_run" | grep -F -- "'clang++' '-o' 'bin/example' 'obj/main.o'" >/dev/null
printf '%s\n' 'snow leopard relinker checks passed'
