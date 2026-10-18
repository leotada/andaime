#!/usr/bin/env bash
# Generates the OpenAPI document of tests/web/openapi_names.d and checks it with openapi-spec-validator
# (pip install openapi-spec-validator). Exits 77 ("skipped") when the validator is not installed.
# Usage: DC=dmd tools/openapi_validate.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DC="${DC:-dmd}"
I="-Isource -Ihttp/source -Iweb/source -Iengine/source -Itests/web"
if ! python3 -c "import openapi_spec_validator" 2> /dev/null; then
    echo "skip: python module openapi_spec_validator not installed (pip install openapi-spec-validator)" >&2
    exit 77
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
$DC -unittest -main $I -i -of"$tmp/gen" tests/web/openapi_names.d > /dev/null
ANDAIME_OPENAPI_OUT="$tmp/openapi.json" "$tmp/gen" > /dev/null
python3 -m openapi_spec_validator "$tmp/openapi.json"
