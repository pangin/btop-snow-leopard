#!/bin/bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
	echo "usage: $0 SOURCE_DIR TAG RESULT_DIR" >&2
	exit 64
fi

source_dir=$1
tag=$2
result_dir=$3

case "$tag" in
	v[0-9]*.[0-9]*.[0-9]*) ;;
	*)
		echo "invalid release tag: $tag" >&2
		exit 64
		;;
esac

version=${tag#v}
binary="$source_dir/bin/btop"
package_root="$result_dir/package"

if [[ ! -x "$binary" ]]; then
	echo "[$tag] executable bin/btop is missing from $source_dir" >&2
	exit 66
fi

mkdir -p "$result_dir"
"$binary" --version > "$result_dir/version.txt"
file "$binary" > "$result_dir/file.txt"
otool -L "$binary" > "$result_dir/otool.txt"
/usr/bin/openssl dgst -sha256 "$binary" > "$result_dir/binary.sha256"

if ! grep -q "Mach-O executable i386" "$result_dir/file.txt"; then
	echo "[$tag] binary is not a 32-bit i386 Mach-O executable" >&2
	cat "$result_dir/file.txt" >&2
	exit 65
fi

if grep -Eq '/opt/local/.*/libc\+\+|/opt/local/lib/libc\+\+' "$result_dir/otool.txt"; then
	echo "[$tag] binary unexpectedly depends on a MacPorts libc++ dylib" >&2
	cat "$result_dir/otool.txt" >&2
	exit 65
fi

if ! grep -q "$version" "$result_dir/version.txt"; then
	echo "[$tag] --version output does not contain $version" >&2
	cat "$result_dir/version.txt" >&2
	exit 65
fi

mkdir -p "$package_root/bin"
cp "$binary" "$package_root/bin/btop"
if [[ -d "$source_dir/themes" ]]; then
	cp -R "$source_dir/themes" "$package_root/themes"
fi
for document in README.md SNOW_LEOPARD.md LICENSE; do
	if [[ -f "$source_dir/$document" ]]; then
		cp "$source_dir/$document" "$package_root/$document"
	fi
done

asset="$result_dir/btop-$version-snow-leopard-i386.tar.gz"
tar -czf "$asset" -C "$package_root" .
/usr/bin/openssl dgst -sha256 "$asset" > "$result_dir/asset.sha256"

echo "[$tag] PASS"
cat "$result_dir/version.txt"
cat "$result_dir/file.txt"
cat "$result_dir/otool.txt"
cat "$result_dir/binary.sha256"
cat "$result_dir/asset.sha256"
echo "[$tag] results: $result_dir"
