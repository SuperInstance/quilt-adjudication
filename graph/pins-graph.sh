#!/bin/sh
# pins-graph.sh — REFERRAL_GRAPH booking-unit pins.
#
#   G1  schema_version == 1, exactly one booked edge, both endpoints cited
#       (source: repo + ref + as_of_commit; target: repo + ref).
#   G2  every boundary string from PR #1's doc is present verbatim in the
#       edge's boundaries array.
#   G3  every mapped source verb exists in quilt-query's actual usage
#       string, fetched live from SuperInstance/quilt-in-git @ 43f10b2
#       (the #9 wave4-query merge commit — receipted, not assumed).
#
# Usage: sh graph/pins-graph.sh [path-to-JSON]
#   default JSON: graph/REFERRAL_GRAPH.json (repo root as CWD).
# Exit 0 = all gates green; 1 = at least one red.

set -u
JSON=${1:-graph/REFERRAL_GRAPH.json}
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $*"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $*"; }

if [ ! -f "$JSON" ]; then
    echo "FAIL - $JSON absent (no graph booked yet)"
    echo
    echo "pins-graph: 0 ok, 1 FAIL"
    exit 1
fi

# ---------------------------------------------------------------- G1
sv=$(jq -r '.schema_version // empty' "$JSON")
if [ "$sv" = "1" ]; then
    ok "G1 schema_version == 1"
else
    bad "G1 schema_version (want 1, got '${sv:-ABSENT}')"
fi

n=$(jq -r '.edges | length' "$JSON")
if [ "$n" = "1" ]; then
    ok "G1 exactly one booked edge"
else
    bad "G1 edge count (want 1, got '${n:-ABSENT}')"
fi

uncited=$(jq -r '[.edges[0].source.repo, .edges[0].source.ref, .edges[0].source.as_of_commit, .edges[0].target.repo, .edges[0].target.ref] | map(select(. == null or . == "")) | length' "$JSON")
if [ "$uncited" = "0" ]; then
    ok "G1 both endpoints cited (source repo+ref+as_of_commit, target repo+ref)"
else
    bad "G1 uncited endpoint fields: $uncited"
fi

# ---------------------------------------------------------------- G2
# Boundary strings from PR #1 docs/REFERRAL-quilt-in-git-wave4-query.md,
# "Honest boundaries" section. Canonical short forms; the .md maps them
# back to the doc sentences.
B_MISSES=""
for b in \
    "committed-tree-only reads" \
    "receipted ≠ true" \
    "substring coverage advisory" \
    "referral-not-dependency"
do
    if ! jq -e --arg b "$b" '.edges[0].boundaries | index($b) != null' "$JSON" >/dev/null 2>&1; then
        B_MISSES="${B_MISSES}${b}; "
    fi
done
if [ -z "$B_MISSES" ]; then
    ok "G2 all four PR #1 boundary strings present verbatim"
else
    bad "G2 missing boundaries: ${B_MISSES%'; '}"
fi

# ---------------------------------------------------------------- G3
Q=$(mktemp)
trap 'rm -f "$Q"' EXIT
if gh api "repos/SuperInstance/quilt-in-git/contents/.quilt/bin/quilt-query?ref=43f10b2b77c67809e7afe865179b6e9c7dbf4081" --jq '.content' 2>/dev/null | base64 -d >"$Q" 2>/dev/null && [ -s "$Q" ]; then
    # Usage lines look like:  #   .quilt/bin/quilt-query <verb> <args...>
    verbs=$(awk '/^#[[:space:]][[:space:]][[:space:]]\.quilt\/bin\/quilt-query /{print $3}' "$Q" | sort -u)
    mapped=$(jq -r '.edges[0].verbs // [] | map(.source_verb) | .[]' "$JSON")
    if [ -z "$mapped" ]; then
        bad "G3 edge maps no source verbs (verbs array absent or empty)"
    else
        V_MISSES=""
        for v in $mapped; do
            if ! echo "$verbs" | grep -qx "$v"; then
                V_MISSES="${V_MISSES}${v}; "
            fi
        done
        if [ -z "$V_MISSES" ]; then
            ok "G3 all mapped source verbs in quilt-query usage @43f10b2: $(echo "$verbs" | tr '\n' ' ')"
        else
            bad "G3 mapped verbs not in quilt-query usage: ${V_MISSES%'; '}"
        fi
    fi
else
    bad "G3 could not fetch .quilt/bin/quilt-query from SuperInstance/quilt-in-git @ 43f10b2"
fi

echo
echo "pins-graph: $PASS ok, $FAIL FAIL"
[ "$FAIL" = "0" ]
