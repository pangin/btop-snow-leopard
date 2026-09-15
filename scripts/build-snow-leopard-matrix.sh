#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "usage: $0 SOURCE_MANIFEST_TSV [WORK_ROOT]" >&2
	exit 64
fi

manifest=$1
work_root=${2:-/Users/pangin/btop-backport-matrix}
script_dir=$(cd "$(dirname "$0")" && pwd)

if [[ ! -f "$manifest" ]]; then
	echo "manifest not found: $manifest" >&2
	exit 66
fi

archive_root=$(cd "$(dirname "$manifest")" && pwd)
manifest="$archive_root/$(basename "$manifest")"
run_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
status_dir="$work_root/status"
status_file="$status_dir/matrix-$run_id.tsv"
mkdir -p "$status_dir"
: > "$status_file"

echo "[matrix] manifest: $manifest"
echo "[matrix] status: $status_file"

count=0
while IFS=$'\t' read -r tag archive_name expected_sha256; do
	[[ -z "$tag" ]] && continue
	archive="$archive_root/$archive_name"
	if [[ ! -f "$archive" ]]; then
		echo -e "$tag\tFAIL\tarchive missing" >> "$status_file"
		echo "[$tag] archive missing: $archive" >&2
		exit 66
	fi

	actual_sha256=$(openssl dgst -sha256 "$archive" | awk '{print $NF}')
	if [[ "$actual_sha256" != "$expected_sha256" ]]; then
		echo -e "$tag\tFAIL\tsource sha256 mismatch" >> "$status_file"
		echo "[$tag] source SHA256 mismatch" >&2
		exit 65
	fi

	echo "[$tag] source SHA256 verified: $actual_sha256"
	pointer="$status_dir/latest-$tag.txt"
	if [[ -f "$pointer" ]]; then
		prior_result=$(cat "$pointer")
		if [[ -d "$prior_result" ]] \
			&& [[ -f "$prior_result/source.sha256" ]] \
			&& [[ "$(cat "$prior_result/source.sha256")" == "$expected_sha256" ]] \
			&& [[ -f "$prior_result/asset.sha256" ]] \
			&& [[ -f "$prior_result/smoke-test.log" ]] \
			&& grep -q '"exit_code": 0' "$prior_result/smoke-test.log"; then
			echo "[$tag] already verified: $prior_result"
			echo -e "$tag\tSKIP\t$archive_name" >> "$status_file"
			count=$((count + 1))
			continue
		fi
	fi

	if BTOP_SOURCE_SHA256="$expected_sha256" "$script_dir/build-snow-leopard-matrix-item.sh" "$archive" "$tag" "$work_root"; then
		echo -e "$tag\tPASS\t$archive_name" >> "$status_file"
		count=$((count + 1))
	else
		result=$?
		echo -e "$tag\tFAIL\texit $result" >> "$status_file"
		echo "[$tag] failed with exit code $result" >&2
		exit "$result"
	fi
done < "$manifest"

echo "[matrix] PASS: $count release(s)"
