#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/build.sh
source "$ROOT/scripts/build.sh"

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT

input="$ROOT/tests/fixtures/mixed-domains.txt"
normalized="$TMP/normalized.txt"
optimized="$TMP/optimized.txt"

normalize_domains "$input" | sort -u --parallel=1 > "$normalized"
TMP_DIR="$TMP" SORT_PARALLEL=1 optimize_domains "$normalized" > "$optimized"

cat > "$TMP/expected-normalized.txt" <<'EXPECTED'
a-b.good-example.net
a.example.com
b.example.com
example.com
foo.a.example.com
foo.internal
foo.local
other.com
sub.other.com
x.home.arpa
xn--example-9d0b.com
EXPECTED

cat > "$TMP/expected-optimized.txt" <<'EXPECTED'
a-b.good-example.net
example.com
foo.internal
foo.local
other.com
x.home.arpa
xn--example-9d0b.com
EXPECTED

cmp -s "$normalized" "$TMP/expected-normalized.txt" || {
    echo 'FAIL: normalized output differs' >&2
    diff -u "$TMP/expected-normalized.txt" "$normalized" >&2 || true
    exit 1
}

cmp -s "$optimized" "$TMP/expected-optimized.txt" || {
    echo 'FAIL: optimized output differs' >&2
    diff -u "$TMP/expected-optimized.txt" "$optimized" >&2 || true
    exit 1
}

grep -qx 'example.com' "$optimized"
! grep -qx 'a.example.com' "$optimized"
! grep -qx 'b.example.com' "$optimized"
! grep -qx 'foo.a.example.com' "$optimized"
grep -qx 'a-b.good-example.net' "$optimized"
grep -qx 'foo.internal' "$optimized"

echo 'PASS: AdZeroList domains-only normalization and hierarchical optimization'
