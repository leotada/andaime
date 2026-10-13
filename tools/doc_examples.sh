#!/usr/bin/env bash
# Compiles (type-checks) the code examples of the docs: every fenced ```d block whose FIRST line is `// check` in README.md
# and docs/*.md. The block must be a complete program. Keeps the documentation honest: an example that no longer compiles
# fails the build. Usage: DC=dmd tools/doc_examples.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source -Idrivers/pg/source"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

n=0
for doc in README.md docs/*.md; do
    awk -v doc="$doc" -v out="$tmp" '
        /^```d$/ { inblock = 1; first = 1; keep = 0; buf = ""; start = NR; next }
        /^```$/ && inblock {
            if (keep) { name = doc; gsub(/[^A-Za-z0-9]/, "_", name); f = out "/" name "_line" start ".d"; printf "%s", buf > f; close(f) }
            inblock = 0; next
        }
        inblock {
            if (first) { first = 0; if ($0 == "// check") { keep = 1; next } }
            buf = buf $0 "\n"
        }' "$doc"
done

fail=0
for f in "$tmp"/*.d; do
    [[ -e "$f" ]] || continue
    n=$((n + 1))
    name=$(basename "$f" .d)
    if ! out=$($DC $I -o- -c "$f" 2>&1); then
        echo "FAILED: example $name (see the line number in its file name)"
        echo "$out" | head -8
        fail=1
    fi
done
if [[ $n -eq 0 ]]; then echo "FAILED: no '// check' examples found"; exit 1; fi
(( fail )) || echo "ok  $n documentation examples compile"
exit $fail
