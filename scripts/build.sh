#!/usr/bin/env bash
# AdZeroList - domains-only builder
# Purpose: download domain-only DNS blocklists, normalize, deduplicate,
#          remove redundant subdomains, and publish one clean domains.txt.
set -Eeuo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LISTS_DIR="${LISTS_DIR:-$PROJECT_ROOT/lists}"
SOURCES_FILE="${SOURCES_FILE:-$LISTS_DIR/sources.list}"
CUSTOM_FILE="${CUSTOM_FILE:-$LISTS_DIR/custom.list}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/outputs}"
OUTPUT_FILE="${OUTPUT_FILE:-$OUTPUT_DIR/domains.txt}"

PARALLEL_DOWNLOADS="${PARALLEL_DOWNLOADS:-8}"
SORT_PARALLEL="${SORT_PARALLEL:-$(nproc 2>/dev/null || printf '1')}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-10}"
DOWNLOAD_TIMEOUT="${DOWNLOAD_TIMEOUT:-120}"
CURL_RETRY="${CURL_RETRY:-3}"
MAX_FILE_SIZE="${MAX_FILE_SIZE:-100000000}"

TMP_DIR=''
cleanup() {
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT INT TERM

log() { printf '[AdZeroList] %s\n' "$*"; }
die() { printf '[AdZeroList] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# Canonicalize a domain-only input file.
# Accepted v1 input: one ASCII domain per line, optional '#' comment lines.
# Output: one lowercase domain per line; malformed/special-use names are dropped.
normalize_domains() {
    local input="$1"

    awk '
    function valid_label(s) {
        if (length(s) < 1 || length(s) > 63) return 0
        return (s ~ /^[a-z0-9]$/ || s ~ /^[a-z0-9][a-z0-9-]*[a-z0-9]$/)
    }
    {
        sub(/\r$/, "")
        d = $0
        sub(/^[[:space:]]+/, "", d)
        sub(/[[:space:]]+$/, "", d)

        if (d == "" || d ~ /^#/) next
        if (d ~ /[[:space:]]/) next

        # Accept a normal FQDN spelling with one trailing root dot.
        sub(/\.$/, "", d)
        d = tolower(d)

        # Domain-only input must not contain URL/filter/wildcard syntax.
        if (d == "" || d ~ /\// || d ~ /:/ || d ~ /\*/ || d ~ /_/) next
        if (d ~ /^[0-9.]+$/) next
        if (length(d) > 253) next

        n = split(d, labels, ".")
        if (n < 2) next

        ok = 1
        for (i = 1; i <= n; i++) {
            if (!valid_label(labels[i])) {
                ok = 0
                break
            }
        }
        if (!ok) next

        # Do not let a public blocklist accidentally sink reverse-DNS trees.
        if (d ~ /(^|\.)(in-addr|ip6)\.arpa$/) next

        print d
    }
    ' "$input"
}

# Remove exact duplicates, then remove every domain whose parent domain is
# already present. Reverse-label sorting makes parent domains precede their
# descendants while keeping the operation streaming and memory-light.
optimize_domains() {
    local input="$1"
    local reversed
    reversed="$TMP_DIR/reversed.txt"

    awk -F '.' '{
        for (i = NF; i > 0; i--)
            printf "%s%s", $i, (i > 1 ? "." : "\n")
    }' "$input" |
        sort -u --parallel="$SORT_PARALLEL" > "$reversed"

    awk '
        NR == 1 {
            previous = $0
            print
            next
        }
        {
            if (substr($0, 1, length(previous)) == previous &&
                substr($0, length(previous) + 1, 1) == ".")
                next
            print
            previous = $0
        }
    ' "$reversed" |
        awk -F '.' '{
            for (i = NF; i > 0; i--)
                printf "%s%s", $i, (i > 1 ? "." : "\n")
        }' |
        sort -u --parallel="$SORT_PARALLEL"
}

read_sources() {
    local line
    local -a parsed=()
    declare -A seen=()

    [[ -f "$SOURCES_FILE" ]] || die "source list not found: $SOURCES_FILE"

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line//$'\r'/}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        [[ -z "$line" ]] && continue
        [[ "${line:0:1}" == "#" ]] && continue

        [[ "$line" =~ ^https://[^[:space:]]+$ ]] || \
            die "invalid source entry (v1 accepts HTTPS URLs only): $line"

        [[ -n "${seen[$line]+x}" ]] && continue
        seen["$line"]=1
        parsed+=("$line")
    done < "$SOURCES_FILE"

    ((${#parsed[@]} > 0)) || die "no active sources in $SOURCES_FILE"
    printf '%s\n' "${parsed[@]}"
}

# Download each source to its own file, in bounded parallel batches.
download_sources() {
    local -a urls=()
    mapfile -t urls < "$1"
    local total="${#urls[@]}"
    local batch_start batch_end i pid rc failed

    log "Downloading $total source(s) with up to $PARALLEL_DOWNLOADS concurrent transfers"

    ((PARALLEL_DOWNLOADS >= 1)) || die "PARALLEL_DOWNLOADS must be >= 1"

    for ((batch_start = 0; batch_start < total; batch_start += PARALLEL_DOWNLOADS)); do
        batch_end=$((batch_start + PARALLEL_DOWNLOADS))
        ((batch_end > total)) && batch_end=$total
        pids=()
        failed=0

        for ((i = batch_start; i < batch_end; i++)); do
            curl \
                --fail \
                --silent \
                --show-error \
                --location \
                --proto '=https' \
                --proto-redir '=https' \
                --compressed \
                --connect-timeout "$CONNECT_TIMEOUT" \
                --max-time "$DOWNLOAD_TIMEOUT" \
                --max-filesize "$MAX_FILE_SIZE" \
                --retry "$CURL_RETRY" \
                --retry-delay 2 \
                "${urls[$i]}" > "$TMP_DIR/raw-$i.txt" &
            pids+=("$!")
        done

        for ((i = 0; i < ${#pids[@]}; i++)); do
            pid="${pids[$i]}"
            if wait "$pid"; then
                :
            else
                rc=$?
                printf '[AdZeroList] ERROR: download failed: %s (exit %s)\n' \
                    "${urls[$((batch_start + i))]}" "$rc" >&2
                failed=1
            fi
        done

        ((failed == 0)) || die "one or more source downloads failed; keeping the previous output untouched"
    done
}

process_sources() {
    local urls_file="$1"
    local combined="$TMP_DIR/combined.txt"
    local -a urls=()
    local i normalized count

    : > "$combined"
    mapfile -t urls < "$urls_file"

    for i in "${!urls[@]}"; do
        normalized="$TMP_DIR/normalized-$i.txt"
        normalize_domains "$TMP_DIR/raw-$i.txt" > "$normalized"
        count="$(wc -l < "$normalized")"

        [[ "$count" -gt 0 ]] || die "source produced zero valid domains (format may have changed): ${urls[$i]}"
        cat "$normalized" >> "$combined"
        printf '[AdZeroList] Source %2d/%2d: %8s valid domains — %s\n' \
            "$((i + 1))" "${#urls[@]}" "$count" "${urls[$i]}" >&2
    done

    if [[ -f "$CUSTOM_FILE" ]]; then
        normalized="$TMP_DIR/custom.txt"
        normalize_domains "$CUSTOM_FILE" > "$normalized"
        count="$(wc -l < "$normalized")"
        cat "$normalized" >> "$combined"
        printf '[AdZeroList] Custom domains: %s valid entries\n' "$count" >&2
    fi

    printf '%s\n' "$combined"
}

main() {
    require_cmd curl
    require_cmd awk
    require_cmd sort
    require_cmd wc
    require_cmd mktemp
    require_cmd nproc

    mkdir -p -- "$OUTPUT_DIR"
    TMP_DIR="$(mktemp -d)"

    log "Building domains-only blocklist"
    log "Sources: $SOURCES_FILE"
    log "Output : $OUTPUT_FILE"

    local urls_file combined final_tmp optimized_count
    urls_file="$TMP_DIR/urls.txt"
    read_sources > "$urls_file"

    download_sources "$urls_file"
    combined="$(process_sources "$urls_file")"

    log "Optimizing exact duplicates and redundant subdomains..."

    # Create the final temporary file in the destination directory so the final
    # rename is atomic on normal filesystems.
    final_tmp="$(mktemp "$OUTPUT_DIR/.domains.txt.XXXXXX")"
    optimize_domains "$combined" > "$final_tmp"
    optimized_count="$(wc -l < "$final_tmp")"
    [[ "$optimized_count" -gt 0 ]] || die "optimization produced an empty output"

    # Atomic replacement: a failed build can never leave a truncated domains.txt.
    mv -f -- "$final_tmp" "$OUTPUT_FILE"

    printf '[AdZeroList] Final domains:     %s\n' "$optimized_count"
    printf '[AdZeroList] Output size:        %s bytes\n' "$(wc -c < "$OUTPUT_FILE")"
    log "Done"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
