#!/bin/bash

set -euo pipefail

if [[ $# -lt 3 || $# -gt 20 ]]; then
	echo "usage: $0 OUTPUT_DIR WORK_ROOT SOURCE_MANIFEST [SOURCE_MANIFEST ...]" >&2
	exit 64
fi

output_dir=$1
work_root=$2
shift 2
script_dir=$(cd "$(dirname "$0")" && pwd)
collector="$script_dir/collect-snow-leopard-results.sh"

if [[ -e "$output_dir" ]]; then
	echo "output already exists: $output_dir" >&2
	exit 73
fi

mkdir -p "$output_dir/assets" "$output_dir/evidence"
verified_manifest="$output_dir/verified-manifest.tsv"
: > "$verified_manifest"
stages=()
cleanup() {
	for stage in "${stages[@]}"; do
		rm -rf "$stage"
	done
}
trap cleanup EXIT HUP INT TERM

for manifest in "$@"; do
	stage=$(mktemp -d "${TMPDIR:-/tmp}/btop-collect.XXXXXX")
	stages+=("$stage")
	"$collector" "$manifest" "$stage" "$work_root"
	cp -R "$stage/assets/." "$output_dir/assets/"
	cp -R "$stage/evidence/." "$output_dir/evidence/"
	cat "$stage/verified-manifest.tsv" >> "$verified_manifest"
done

count=$(wc -l < "$verified_manifest" | tr -d ' ')
echo "[collect-all] PASS: $count verified release(s)"
echo "[collect-all] manifest: $verified_manifest"
