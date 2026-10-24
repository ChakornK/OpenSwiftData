#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift test -Xswiftc -warnings-as-errors

swift_files=()
if (($#)); then
    for file in "$@"; do
        if [[ "$file" != *.swift ]]; then
            printf 'error: not a Swift file: %s\n' "$file" >&2
            exit 1
        fi
        swift_files+=("$file")
    done
else
    while IFS= read -r -d '' file; do
        swift_files+=("$file")
    done < <(find Sources Tests -type f -name '*.swift' -print0)
fi

if ((${#swift_files[@]})); then
    swift format lint --strict "${swift_files[@]}"
fi
