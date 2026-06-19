#!/bin/sh
# Install git hooks for this repo. Run once after cloning.
set -e
REPO_ROOT="$(git rev-parse --show-toplevel)"
mkdir -p "$REPO_ROOT/.githooks"
cp "$REPO_ROOT/scripts/hooks/pre-commit" "$REPO_ROOT/.githooks/pre-commit"
chmod +x "$REPO_ROOT/.githooks/pre-commit"
git config core.hooksPath .githooks
echo "Hooks installed. Pre-commit will run fmt, clippy, and tests."
