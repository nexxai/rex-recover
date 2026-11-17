#!/bin/sh
# Deliberately skip before binary discovery, even when CODEX_REAL=1.
# The old title-based probe is retired; repository coverage uses mocks.
set -eu
echo 'SKIP: The legacy live Codex probe is retired; the automated suite uses mock Codex only.'
