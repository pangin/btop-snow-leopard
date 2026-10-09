#!/bin/sh

set -eu

usage() {
	echo "usage: $0 --output FILE --stack NAME [--stack NAME ...] --object FILE [--object FILE ...]" >&2
	echo "       [--objects-file FILE] [--compiler CXX] [--dry-run] [--validate]" >&2
	exit 64
}

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
composer=$script_dir/compose-link-stack.sh
compiler=${CXX:-clang++}
output=
stack_dir=$script_dir/stacks
stack_names=
objects_file=$(mktemp "${TMPDIR:-/tmp}/snow-leopard-objects.XXXXXX")
extra_file=$(mktemp "${TMPDIR:-/tmp}/snow-leopard-extra.XXXXXX")
flags_file=
cleanup() {
	rm -f "$objects_file" "$extra_file"
	if [ -n "${flags_file:-}" ]; then rm -f "$flags_file"; fi
}
trap cleanup 0 1 2 3 15
dry_run=false
validate=false

while [ "$#" -gt 0 ]; do
	case "$1" in
	--output)
		[ "$#" -ge 2 ] || usage
		output=$2
		shift 2
		;;
	--stack)
		[ "$#" -ge 2 ] || usage
		case "$2" in
		*[!A-Za-z0-9_-]*) echo "invalid stack name: $2" >&2; exit 64 ;;
		esac
		stack_names="$stack_names $2"
		shift 2
		;;
	--stack-dir)
		[ "$#" -ge 2 ] || usage
		stack_dir=$2
		shift 2
		;;
	--compiler)
		[ "$#" -ge 2 ] || usage
		compiler=$2
		shift 2
		;;
	--object)
		[ "$#" -ge 2 ] || usage
		printf '%s\n' "$2" >> "$objects_file"
		shift 2
		;;
	--objects-file)
		[ "$#" -ge 2 ] || usage
		cat "$2" >> "$objects_file"
		shift 2
		;;
	--extra)
		[ "$#" -ge 2 ] || usage
		printf '%s\n' "$2" >> "$extra_file"
		shift 2
		;;
	--dry-run)
		dry_run=true
		shift
		;;
	--validate)
		validate=true
		shift
		;;
	--help|-h)
		usage
		;;
	*)
		usage
		;;
	esac
done

[ -n "$output" ] || usage
[ -n "$stack_names" ] || usage
[ -s "$objects_file" ] || {
	echo "at least one object is required" >&2
	exit 64
}

case "$compiler" in
/*) compiler_path=$compiler ;;
*) compiler_path=$(command -v "$compiler" || true) ;;
esac
if [ "$validate" = true ] && [ -z "$compiler_path" ]; then
	echo "compiler not found: $compiler" >&2
	exit 66
fi

validate_stack_inputs() {
	name=$1
	case "$name" in
	apple-system-frameworks)
		;;
	llvm16-libcxx-static)
		macports_prefix=${MACPORTS_PREFIX:-/opt/local}
		llvm_prefix=${LLVM_PREFIX:-$macports_prefix/libexec/llvm-16}
		[ -f "$llvm_prefix/lib/libc++/libc++.a" ] || {
			echo "missing libc++ archive under $llvm_prefix" >&2
			exit 66
		}
		[ -f "$llvm_prefix/lib/libc++/libc++abi.a" ] || {
			echo "missing libc++abi archive under $llvm_prefix" >&2
			exit 66
		}
		;;
	macports-legacy-support)
		macports_prefix=${MACPORTS_PREFIX:-/opt/local}
		[ -f "$macports_prefix/lib/libMacportsLegacySupport.dylib" ] || {
			echo "missing MacPorts LegacySupport dylib under $macports_prefix" >&2
			exit 66
		}
		;;
	snow-leopard)
		validate_stack_inputs llvm16-libcxx-static
		validate_stack_inputs macports-legacy-support
		;;
	*)
		echo "unknown link stack: $name" >&2
		exit 65
		;;
	esac
}

if [ "$validate" = true ]; then
	for name in $stack_names; do
		validate_stack_inputs "$name"
	done
fi

flags_file=$(mktemp "${TMPDIR:-/tmp}/snow-leopard-flags.XXXXXX")
trap cleanup 0 1 2 3 15
stack_args=
for name in $stack_names; do
	stack_args="$stack_args --stack $name"
done
# Stack names are restricted above to shell-safe identifiers. File paths remain
# line-delimited and are appended as individual argv entries below.
# shellcheck disable=SC2086
"$composer" --stack-dir "$stack_dir" $stack_args > "$flags_file"

if [ "$validate" = true ]; then
	while IFS= read -r object; do
		[ -n "$object" ] || continue
		[ -f "$object" ] || { echo "object not found: $object" >&2; exit 66; }
	done < "$objects_file"
	while IFS= read -r flag; do
		case "$flag" in
		*.a|*.dylib) [ -f "$flag" ] || { echo "link input not found: $flag" >&2; exit 66; } ;;
		esac
	done < "$flags_file"
fi

shell_quote() {
	value=$1
	value=$(printf '%s' "$value" | sed "s/'/'\\\\''/g")
	printf "'%s'" "$value"
}

set -- "$compiler" -o "$output"
while IFS= read -r object; do
	[ -n "$object" ] && set -- "$@" "$object"
done < "$objects_file"
while IFS= read -r flag; do
	[ -n "$flag" ] && set -- "$@" "$flag"
done < "$flags_file"
while IFS= read -r flag; do
	[ -n "$flag" ] && set -- "$@" "$flag"
done < "$extra_file"

if [ "$dry_run" = true ]; then
	first=true
	for argument in "$@"; do
		if [ "$first" = true ]; then first=false; else printf ' '; fi
		shell_quote "$argument"
	done
	printf '\n'
	exit 0
fi

exec "$@"
