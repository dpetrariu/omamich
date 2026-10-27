#!/usr/bin/env bash
# Hand files to Omamich for upload: used by the "Upload to Immich" desktop entry.
set -euo pipefail
[[ $# -gt 0 ]] || exit 0
payload=$(python3 -I -c 'import json,os,sys; print(json.dumps({"upload": [os.path.abspath(p) for p in sys.argv[1:]]}))' "$@")
exec omarchy-shell shell summon dpetrariu.omamich "$payload"
