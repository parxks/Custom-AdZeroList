# AdZeroList — domains-only DNS blocklist

This fork is intentionally narrow: it builds **one file, `outputs/domains.txt`**, for use as a domain-list source with OpenWrt `adblock-fast`, especially the Unbound backend.

## Pipeline

```text
HTTPS domain sources
        ↓
parallel download to isolated temp files
        ↓
strict domain normalization
        ↓
exact deduplication
        ↓
parent/subdomain elimination
        ↓
outputs/domains.txt
```

The generated file contains **only one lowercase ASCII domain per line**. There are no headers, comments, hosts mappings, Adblock rules, dnsmasq directives, Unbound directives, YAML, or browser filters in the published output.

## Optimization

The builder performs the DNS-safe transformations that matter for this format:

- lowercase normalization because DNS names are case-insensitive
- removal of a single trailing FQDN root dot
- removal of exact duplicates
- validation of DNS host labels and length limits
- rejection of malformed/wildcard/filter/URL syntax
- rejection of single-label names and numeric-only IP-like entries
- rejection of reverse-DNS namespaces (`in-addr.arpa` and `ip6.arpa`)
- hierarchical deduplication: when `example.com` exists, `a.example.com` and deeper descendants are removed
- deterministic `LC_ALL=C` sorting

It deliberately does **not** rewrite `www.example.com` to `example.com`, infer wildcards, or otherwise guess that two different domains are equivalent. Those transformations can change blocking semantics.

## Input contract

Version 1 expects each remote source to be a **domains.txt-style list**:

```text
example.com
ads.example.net
tracker.example.org
```

Comment lines beginning with `#` and blank lines are accepted. Other filter syntaxes are intentionally rejected rather than heuristically converted. The normalization function is isolated in `scripts/build.sh`, so another parser can be added later without contaminating the optimization pipeline.

Edit `lists/sources.list` to choose your DNS sources. An optional `lists/custom.list` can contain additional domains.

A failed download or a downloaded source containing zero valid domains aborts the build, leaving the previous published `domains.txt` untouched.

## Why no hosts.txt?

This fork does not generate hosts files. A packed hosts line such as:

```text
0.0.0.0 a.example.com b.example.com c.example.com
```

is a hosts-file serialization optimization, not a domain-list optimization. It is irrelevant to the `domains.txt` handoff and adds another parser/format that can introduce errors.

## adblock-fast

Use the generated file as a `domains` source. Current `adblock-fast` explicitly supports remote domain lists and hosts files, and its Unbound backend formats domain entries as Unbound `local-zone` rules. It also performs its own subdomain optimization, so this fork pre-optimizes the file to reduce the amount of data that must be transferred and processed on the router.

Recommended raw URL after the GitHub Action has produced the first commit:

```text
https://raw.githubusercontent.com/OWNER/REPO/main/outputs/domains.txt
```

Replace `OWNER/REPO` with your fork.

## Local build

```bash
./scripts/build.sh
```

Useful overrides:

```bash
PARALLEL_DOWNLOADS=4 SORT_PARALLEL=4 CONNECT_TIMEOUT=10 DOWNLOAD_TIMEOUT=180 ./scripts/build.sh
```

The builder uses temporary files and atomically replaces `outputs/domains.txt` only after every configured source has downloaded and the final list is non-empty.

## Tests

The repository includes an offline regression test for normalization and hierarchical optimization:

```bash
./tests/test_build.sh
./tests/test_e2e.sh
```

## License

MIT. This fork retains the upstream license.
