#!/bin/sh

set -eu

# One linker argument per line keeps paths and flags unambiguous when the
# composition is consumed by another project.
printf '%s\n' \
	-framework \
	IOKit \
	-framework \
	CoreFoundation
