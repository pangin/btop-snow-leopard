#!/bin/bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
	echo "usage: $0 ARCHIVE TAG [WORK_ROOT]" >&2
	exit 64
fi

archive=$1
tag=$2
work_root=${3:-/Users/pangin/btop-backport-matrix}

case "$tag" in
	v[0-9]*.[0-9]*.[0-9]*) ;;
	*)
		echo "invalid release tag: $tag" >&2
		exit 64
		;;
esac

if [[ ! -f "$archive" ]]; then
	echo "archive not found: $archive" >&2
	exit 66
fi

run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
run_dir="$work_root/builds/$tag-$run_id"
source_dir="$run_dir/source"
result_dir="$work_root/results/$tag-$run_id"
script_dir=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$source_dir" "$result_dir"
if [[ -n "${BTOP_SOURCE_SHA256:-}" ]]; then
	printf '%s\n' "$BTOP_SOURCE_SHA256" > "$result_dir/source.sha256"
fi
tar -xzf "$archive" -C "$source_dir"

if [[ ! -f "$source_dir/build-snow-leopard.sh" ]]; then
	echo "prepared build script is missing from $archive" >&2
	exit 65
fi

chmod +x "$source_dir/build-snow-leopard.sh"
cd "$source_dir"

echo "[$tag] build directory: $run_dir"
echo "[$tag] compiling on $(sw_vers -productVersion) $(uname -m)"
./build-snow-leopard.sh 2>&1 | tee "$result_dir/build.log"

"$script_dir/verify-snow-leopard-build.sh" "$source_dir" "$tag" "$result_dir"

python "$script_dir/smoke-test-snow-leopard.py" \
	"$source_dir/bin/btop" \
	"$result_dir/runtime-config" \
	"$result_dir/runtime.log" \
	8 2>&1 | tee "$result_dir/smoke-test.log"

mkdir -p "$work_root/status"
pointer_tmp="$work_root/status/latest-$tag.txt.tmp-$$"
printf '%s\n' "$result_dir" > "$pointer_tmp"
mv "$pointer_tmp" "$work_root/status/latest-$tag.txt"
