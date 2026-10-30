#!/usr/bin/env bash

set -euo pipefail

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
mapfile -t test_files < <(
    printf '%s\n' "$test_dir"/*.test | LC_ALL=C sort
)

if ((${#test_files[@]} == 0)); then
    printf 'No Tcl test files found in %s\n' "$test_dir" >&2
    exit 1
fi

for test_file in "${test_files[@]}"; do
    printf '\n=== %s ===\n' "${test_file##*/}"
    if ! output=$(tclsh "$test_file" 2>&1); then
        printf '%s\n' "$output"
        exit 1
    fi

    printf '%s\n' "$output"
    if grep -Eq 'Failed[[:space:]]+[1-9][0-9]*' <<<"$output"; then
        exit 1
    fi
done
