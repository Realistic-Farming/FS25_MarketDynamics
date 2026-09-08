#!/usr/bin/env bash
# Run the FS25_MarketDynamics self-test suite (Lua 5.1 syntax + offline logic tests).
# Usage:  bash tools/test/run.sh   (or: cd tools/test && npm run all)
set -e
cd "$(dirname "$0")"
if [ ! -d node_modules ]; then
  echo "Installing test deps (first run)…"
  npm install --silent
fi
npm run --silent all