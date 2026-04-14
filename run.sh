#!/usr/bin/env bash
# Convenience launcher. Loads secrets from env.json (gitignored).
# Usage:  ./run.sh          # debug run on default device
#         ./run.sh -d <id>  # pass any extra flutter run args
set -euo pipefail
cd "$(dirname "$0")"
if [ ! -f env.json ]; then
  echo "env.json missing. Copy env.example.json to env.json and fill in keys."
  exit 1
fi
exec flutter run --dart-define-from-file=env.json "$@"
