#!/bin/bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
	echo "usage: $0 SOURCE_MANIFEST_TSV OUTPUT_DIR [WORK_ROOT]" >&2
	exit 64
fi

manifest=$1
output_dir=$2
work_root=${3:-/Users/pangin/btop-backport-matrix}

if [[ ! -f "$manifest" ]]; then
	echo "manifest not found: $manifest" >&2
	exit 66
fi
if [[ -e "$output_dir" ]]; then
	echo "output already exists: $output_dir" >&2
	exit 73
fi

archive_root=$(cd "$(dirname "$manifest")" && pwd)
manifest="$archive_root/$(basename "$manifest")"
mkdir -p "$output_dir/assets" "$output_dir/evidence"
verified_manifest="$output_dir/verified-manifest.tsv"
: > "$verified_manifest"

count=0
while IFS=$'\t' read -r tag source_name expected_source_sha256; do
	[[ -z "$tag" ]] && continue
	pointer="$work_root/status/latest-$tag.txt"
	if [[ ! -f "$pointer" ]]; then
		echo "[$tag] verified-result pointer is missing" >&2
		exit 65
	fi
	result_dir=$(cat "$pointer")
	version=${tag#v}
	source_archive="$archive_root/$source_name"
	binary_name="btop-$version-snow-leopard-i386.tar.gz"
	binary_archive="$result_dir/$binary_name"

	for required in \
		"$source_archive" \
		"$binary_archive" \
		"$result_dir/source.sha256" \
		"$result_dir/binary.sha256" \
		"$result_dir/asset.sha256" \
		"$result_dir/version.txt" \
		"$result_dir/file.txt" \
		"$result_dir/otool.txt" \
		"$result_dir/smoke-test.log"; do
		if [[ ! -f "$required" ]]; then
			echo "[$tag] evidence missing: $required" >&2
			exit 65
		fi
	done

	if [[ "$(cat "$result_dir/source.sha256")" != "$expected_source_sha256" ]]; then
		echo "[$tag] recorded source SHA256 mismatch" >&2
		exit 65
	fi
	actual_source_sha256=$(openssl dgst -sha256 "$source_archive" | awk '{print $NF}')
	actual_binary_asset_sha256=$(openssl dgst -sha256 "$binary_archive" | awk '{print $NF}')
	recorded_binary_asset_sha256=$(awk '{print $NF}' "$result_dir/asset.sha256")
	recorded_binary_sha256=$(awk '{print $NF}' "$result_dir/binary.sha256")
	if [[ "$actual_source_sha256" != "$expected_source_sha256" ]]; then
		echo "[$tag] source archive SHA256 mismatch" >&2
		exit 65
	fi
	if [[ "$actual_binary_asset_sha256" != "$recorded_binary_asset_sha256" ]]; then
		echo "[$tag] binary archive SHA256 mismatch" >&2
		exit 65
	fi
	if ! grep -q '"exit_code": 0' "$result_dir/smoke-test.log"; then
		echo "[$tag] successful TUI smoke-test evidence is missing" >&2
		exit 65
	fi

	cp "$source_archive" "$output_dir/assets/$source_name"
	cp "$binary_archive" "$output_dir/assets/$binary_name"
	mkdir -p "$output_dir/evidence/$tag"
	cp "$result_dir/source.sha256" \
		"$result_dir/binary.sha256" \
		"$result_dir/asset.sha256" \
		"$result_dir/version.txt" \
		"$result_dir/file.txt" \
		"$result_dir/otool.txt" \
		"$result_dir/smoke-test.log" \
		"$output_dir/evidence/$tag/"

	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$tag" "$source_name" "$expected_source_sha256" \
		"$binary_name" "$recorded_binary_sha256" \
		"$recorded_binary_asset_sha256" "$result_dir" >> "$verified_manifest"
	count=$((count + 1))
done < "$manifest"

echo "[collect] PASS: $count verified release(s)"
echo "[collect] manifest: $verified_manifest"
