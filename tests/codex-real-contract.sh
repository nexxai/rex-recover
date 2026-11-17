#!/bin/sh
# The retired probe must not discover or invoke Codex, even with old opt-in.
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${REX_TEST_TMPDIR:-${TMPDIR:-/tmp}}/codex-real-contract.XXXXXX")
trap 'echo "Codex probe contract artifacts: $temporary"' EXIT
mkdir "$temporary/bin"
cat >"$temporary/bin/codex" <<'SH'
#!/bin/sh
echo unexpected-binary-execution >"$CODEX_CONTRACT_SENTINEL"
exit 99
SH
chmod +x "$temporary/bin/codex"
cp "$temporary/bin/codex" "$temporary/bin/rex"
for mode in unset 1; do
  (
    if [ "$mode" = unset ]; then unset CODEX_REAL; else export CODEX_REAL=1; fi
    PATH="$temporary/bin:$PATH" CODEX_BIN="$temporary/bin/codex" REX_BIN="$temporary/bin/rex" \
      CODEX_CONTRACT_SENTINEL="$temporary/executed" \
      sh "$root/tests/codex-real.sh"
  ) >"$temporary/output-$mode" 2>&1
  grep -Fq 'SKIP: The legacy live Codex probe is retired; the automated suite uses mock Codex only.' \
    "$temporary/output-$mode"
  test ! -e "$temporary/executed"
done
echo "ok - retired real Codex probe skips without binary execution for unset and CODEX_REAL=1"
