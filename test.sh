#!/usr/bin/env bash
# Runs the full WatchNext automated test matrix:
#   1. flutter analyze           — static Dart checks
#   2. flutter test              — 179 unit / widget / routing / rules-sanity
#   3. functions tsc --noEmit    — Cloud Functions typecheck
#   4. test-rules (emulator)     — 43 Firestore security-rules E2E tests
#
# Requires: flutter, node, npm, java (for Firestore emulator).
set -euo pipefail
cd "$(dirname "$0")"

echo "==> flutter analyze"
flutter analyze --no-pub

echo "==> flutter test"
flutter test

echo "==> functions tsc --noEmit"
(cd functions && npx tsc --noEmit)

echo "==> firestore rules emulator tests"
if [ ! -d test-rules/node_modules ]; then
  (cd test-rules && npm install)
fi
(cd test-rules && npx firebase emulators:exec \
  --only firestore \
  --project watchnext-rules-test \
  'npx jest --runInBand')

echo "==> all green"
