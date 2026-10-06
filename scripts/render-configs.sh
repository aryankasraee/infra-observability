#!/usr/bin/env bash
# Render the *.tftpl config templates to build/ exactly as Terraform would,
# so promtool / amtool / alloy can check them without a server.
#   scripts/render-configs.sh [var-file]   (default: terraform.tfvars.example)
set -euo pipefail
cd "$(dirname "$0")/.."
VARFILE=${1:-terraform.tfvars.example}
rm -rf build && mkdir -p build
for tpl in $(cd config && find . -name '*.tftpl'); do
  out="build/${tpl#./}"; out="${out%.tftpl}"
  mkdir -p "$(dirname "$out")"
  echo "jsonencode(templatefile(\"../config/${tpl#./}\", local.tpl))" \
    | terraform -chdir=terraform console -var-file="$VARFILE" \
    | python3 -c 'import json,sys; print(json.loads(json.loads(sys.stdin.read())), end="")' > "$out"
  echo "rendered $out"
done
