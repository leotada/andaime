#!/usr/bin/env bash
# JSON benchmark: andaime's own reader/writer against std.json (speed, GC bytes per operation, compile time of the import).
# For justifying the design and comparing before/after a change, not a gate: the numbers depend on the machine.
#
# Usage: tools/json_bench.sh        DC=ldmd2 by default (DC=dmd works, slower code)
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-ldmd2}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source -Itests/bench"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

$DC -O -release -inline -boundscheck=off $I -i tests/bench/json_bench.d -of"$work/json_bench" > /dev/null
"$work/json_bench"

# Compile time of the module that does the work, alone (no -O, as in a normal build).
cat > "$work/ours.d" <<'EOF'
module ours 2025;
import andaime.web.json : decodeJson;
struct P { long id; string name; }
void main() { P p; import andaime.web.dto : FieldErrors; FieldErrors e; decodeJson(`{"id":1,"name":"x"}`, p, e); }
EOF
cat > "$work/theirs.d" <<'EOF'
module theirs 2025;
import std.json : parseJSON;
void main() { auto j = parseJSON(`{"id":1,"name":"x"}`); auto s = j.toString; }
EOF
ms() { local t0=$(date +%s%N); "$@" > /dev/null; echo $(( ($(date +%s%N) - t0) / 1000000 )); }
echo "compile time (-c, no optimization):"
echo "  andaime json.d : $(ms $DC -c $I -i "$work/ours.d" -of"$work/ours.o") ms"
echo "  std.json       : $(ms $DC -c "$work/theirs.d" -of"$work/theirs.o") ms"
