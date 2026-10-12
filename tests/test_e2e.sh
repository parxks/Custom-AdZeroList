#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

MOCKBIN="$TMP/bin"
FIX="$TMP/fixtures"
mkdir -p "$MOCKBIN" "$FIX" "$TMP/out"

cat > "$MOCKBIN/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
url="${@: -1}"
case "$url" in
  https://source.invalid/one) cat "$TEST_FIXTURES/one.txt" ;;
  https://source.invalid/two) cat "$TEST_FIXTURES/two.txt" ;;
  https://source.invalid/fail) exit 22 ;;
  *) echo "unexpected mock URL: $url" >&2; exit 22 ;;
esac
MOCK
chmod +x "$MOCKBIN/curl"
printf '%s\n' 'example.com' 'a.example.com' 'one.example.org' 'A.Example.com.' > "$FIX/one.txt"
printf '%s\n' 'example.com' 'b.example.com' 'two.example.org' > "$FIX/two.txt"
printf '%s\n' 'https://source.invalid/one' 'https://source.invalid/two' > "$FIX/sources.list"

PATH="$MOCKBIN:$PATH" \
TEST_FIXTURES="$FIX" \
SOURCES_FILE="$FIX/sources.list" \
CUSTOM_FILE="$TMP/no-custom" \
OUTPUT_DIR="$TMP/out" \
OUTPUT_FILE="$TMP/out/domains.txt" \
PARALLEL_DOWNLOADS=2 \
SORT_PARALLEL=1 \
  "$ROOT/scripts/build.sh" > "$TMP/log" 2>&1

cat > "$TMP/expected.txt" <<'EXPECTED'
example.com
one.example.org
two.example.org
EXPECTED
cmp -s "$TMP/expected.txt" "$TMP/out/domains.txt" || {
  echo 'FAIL: end-to-end output differs' >&2
  diff -u "$TMP/expected.txt" "$TMP/out/domains.txt" >&2 || true
  cat "$TMP/log" >&2 || true
  exit 1
}
grep -q 'Done' "$TMP/log"
! grep -Eq '[[:space:]]|^[#;!]|^[0-9]+\.' "$TMP/out/domains.txt"

cp "$TMP/out/domains.txt" "$TMP/prior.txt"
printf '%s\n' 'https://source.invalid/one' 'https://source.invalid/fail' > "$FIX/sources.list"
set +e
PATH="$MOCKBIN:$PATH" \
TEST_FIXTURES="$FIX" \
SOURCES_FILE="$FIX/sources.list" \
CUSTOM_FILE="$TMP/no-custom" \
OUTPUT_DIR="$TMP/out" \
OUTPUT_FILE="$TMP/out/domains.txt" \
PARALLEL_DOWNLOADS=2 \
SORT_PARALLEL=1 \
  "$ROOT/scripts/build.sh" > "$TMP/fail-log" 2>&1
rc=$?
set -e
((rc != 0)) || { echo 'FAIL: broken source did not fail the build' >&2; exit 1; }
cmp -s "$TMP/prior.txt" "$TMP/out/domains.txt" || { echo 'FAIL: failed build modified prior output' >&2; exit 1; }

echo 'PASS: end-to-end offline build and failure-safe output handling'
