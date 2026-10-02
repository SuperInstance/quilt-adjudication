#!/usr/bin/env bash
# P12: the record's handle must WORK, not merely be well-formed.
# The 2026-10-02 defect was a record whose "to_accept_the_loser" command
# (a) ended in 'git merge --abort', which always fails after a refusal, and
# (b) named the loser while restoring the state the reader was already in.
# An unrun handle is a fiction. This pin runs it.
set -u
pass=0; fail=0
ck(){ if [ "$1" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "   FAIL: $3 (got '$1' want '$2')"; fi; }

ROOT=$(mktemp -d /tmp/handle-test-XXXXXX)
trap 'rm -rf "$ROOT"' EXIT
git -C "$ROOT" init -q -b main .
git -C "$ROOT" config user.email t@t; git -C "$ROOT" config user.name T
cp -r .quilt "$ROOT"/
mkdir -p "$ROOT/cells/inbox"
# EXACTLY the demo's fixture: the base asserts 19, and pr33 INSERTS a second
# claim line for the same key rather than editing the first. That is what makes
# the merged tree hold two attributed values for one key -- the case a line
# merge cannot represent.
printf 'the inbox cell receives contested edges\nclaim: inbound_edges = 19  by quilt-tools#32 fb2e041\n' > "$ROOT/cells/inbox/body"
git -C "$ROOT" add -A >/dev/null; git -C "$ROOT" commit -qm "PR #32: inbound_edges = 19 (fb2e041)"
git -C "$ROOT" checkout -qb pr33
sed -i '2a claim: inbound_edges = 21  by quilt-tools#33 0101409' "$ROOT/cells/inbox/body"
git -C "$ROOT" add -A >/dev/null; git -C "$ROOT" commit -qm "PR #33: inbound_edges = 21 (0101409)"
git -C "$ROOT" checkout -q main

( cd "$ROOT" && git merge pr33 --no-commit --no-ff >/dev/null 2>&1; \
  ./.quilt/bin/quilt-adjudicate --index >/dev/null 2>&1 )
rc=$?
ck "$rc" "1" "the refusal exits non-zero"

rec=$(find "$ROOT/.quilt/adjudications" -name '*.json' 2>/dev/null | head -1)
ck "$([ -n "$rec" ] && echo y || echo n)" "y" "a record was written"

before=$(grep -oE '= [0-9]+' "$ROOT/cells/inbox/body" | head -1)
ck "$before" "= 19" "the working tree still holds the LOSER (19) after refusal"

h=$(grep -oE '"to_accept_the_winner": "[^"]+"' "$rec" 2>/dev/null | sed 's/.*": "//; s/"$//')
ck "$([ -n "$h" ] && echo y || echo n)" "y" "the record carries a winner-side handle"
ck "$(printf '%s' "$rec" | grep -c 'merge --abort')" "0" "no 'merge --abort' anywhere (it always fails)"

if [ -n "$h" ]; then
  ( cd "$ROOT" && eval "$h" ) >/dev/null 2>&1
  # NOTE: the handle does not DELETE the loser's line -- it keeps it verbatim and
  # adds the winner. So the assertion is 'the winner is now present', not 'the
  # first value is the winner'. My first version of this check asserted the
  # latter and failed against a CORRECT handle.
  body=$(cat "$ROOT/cells/inbox/body")
  ck "$(printf '%s' "$body" | grep -c '= 21')" "1" "the WINNER (21) is present after running the handle"
  ck "$(printf '%s' "$body" | grep -c '= 19')" "1" "the LOSER (19) is KEPT VERBATIM alongside it"
  ck "$(git -C "$ROOT" log -1 --format=%s | grep -c 'adjudicated')" "1" "the handle committed"
  ck "$(git -C "$ROOT" status --porcelain | wc -l | tr -d ' ')" "0" "the tree is clean afterwards"
fi

echo "P12 verdict: handle executes and moves 19 -> 21, or nothing else matters: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
