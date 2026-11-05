#!/bin/sh
# All checks that need no network and touch no real data.
set -eu
cd "$(dirname "$0")/.."
swift build --product ClipProbe
.build/debug/ClipProbe --selftest
deno test --quiet supabase/functions/api/clean.test.ts
