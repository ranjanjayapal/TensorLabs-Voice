#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required but not installed."
  echo "Install: brew install xcodegen"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

xcodegen generate --spec project.yml
echo "Generated: $ROOT_DIR/TensorLabsVoice.xcodeproj"
