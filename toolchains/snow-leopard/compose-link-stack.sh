#!/bin/sh

set -eu

usage() {
	echo "usage: $0 [--stack-dir DIR] [--format lines] --stack NAME [--stack NAME ...]" >&2
	echo "stacks: apple-system-frameworks llvm16-libcxx-static macports-legacy-support snow-leopard" >&2
	exit 64
}

script_dir=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
stack_dir=$script_dir/stacks
format=lines
stacks=

emit_stack() {
	name=$1
	case "$name" in
	apple-system-frameworks)
		sh "$stack_dir/apple-system-frameworks.sh"
		;;
	llvm16-libcxx-static)
		sh "$stack_dir/llvm16-libcxx-static.sh"
		;;
	macports-legacy-support)
		sh "$stack_dir/macports-legacy-support.sh"
		;;
	snow-leopard)
		emit_stack apple-system-frameworks
		emit_stack llvm16-libcxx-static
		emit_stack macports-legacy-support
		;;
	*)
		echo "unknown link stack: $name" >&2
		exit 65
		;;
	esac
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--stack-dir)
		[ "$#" -ge 2 ] || usage
		stack_dir=$2
		shift 2
		;;
	--format)
		[ "$#" -ge 2 ] || usage
		format=$2
		shift 2
		;;
	--stack)
		[ "$#" -ge 2 ] || usage
		case "$2" in
		*[!A-Za-z0-9_-]*) echo "invalid stack name: $2" >&2; exit 64 ;;
		esac
		stacks="$stacks $2"
		shift 2
		;;
	--list)
		printf '%s\n' apple-system-frameworks llvm16-libcxx-static macports-legacy-support snow-leopard
		exit 0
		;;
	--help|-h)
		usage
		;;
	*)
		usage
		;;
	esac
done

[ -n "$stacks" ] || usage
[ "$format" = lines ] || {
	echo "unsupported format: $format (only 'lines' is stable)" >&2
	exit 64
}

for name in $stacks; do
	emit_stack "$name"
done
