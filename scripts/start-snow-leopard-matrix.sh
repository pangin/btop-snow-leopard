#!/bin/bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
	echo "usage: $0 SOURCE_MANIFEST_TSV [WORK_ROOT]" >&2
	exit 64
fi

manifest=$1
work_root=${2:-/Users/pangin/btop-backport-matrix}
script_dir=$(cd "$(dirname "$0")" && pwd)
status_dir="$work_root/status"
pid_file="$status_dir/matrix-build.pid"
mkdir -p "$status_dir"

if [[ -f "$pid_file" ]]; then
	old_pid=$(cat "$pid_file")
	if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
		echo "matrix build already running as PID $old_pid" >&2
		exit 73
	fi
fi

run_id=$(date -u +%Y%m%dT%H%M%SZ)
log_file="$status_dir/matrix-$run_id.log"
(
	trap '' HUP
	exec "$script_dir/build-snow-leopard-matrix.sh" "$manifest" "$work_root"
) > "$log_file" 2>&1 < /dev/null &
pid=$!
echo "$pid" > "$pid_file"

echo "PID=$pid"
echo "LOG=$log_file"
