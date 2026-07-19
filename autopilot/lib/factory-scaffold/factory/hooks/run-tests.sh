#!/usr/bin/env bash
# Product-agnostic test runner. Override with FACTORY_TEST_CMD per product.
set -euo pipefail
[[ -f factory/config.env ]] && source factory/config.env || true

if [[ -n "${FACTORY_TEST_CMD:-}" ]]; then
  exec bash -c "$FACTORY_TEST_CMD"
fi

if [[ -f package.json ]]; then
  npm test
elif [[ -f Cargo.toml ]]; then
  cargo test
elif [[ -f pyproject.toml || -f pytest.ini ]]; then
  pytest
else
  echo "No test runner detected; set FACTORY_TEST_CMD" >&2
  exit 1
fi
