#!/bin/sh

set -eu

MACPORTS_PREFIX=${MACPORTS_PREFIX:-/opt/local}

printf '%s\n' \
	"-L$MACPORTS_PREFIX/lib" \
	-lMacportsLegacySupport
