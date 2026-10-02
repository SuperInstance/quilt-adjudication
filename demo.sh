#!/bin/sh
# demo.sh — the two-pane demo, runnable from a clone.
#
#   git clone <this repo> && cd <clone> && ./demo.sh
#
# The fixture is the real one: SuperInstance/quilt-tools PRs #32 and #33 each
# independently assert the same counter, both were correct against main at the
# time they were written, and a blind keep-both merge puts two different values
# for one key in the same tree. In the source repo that produced invalid
# syntax; here it produces two `claim:` lines for one key, which is the same
# defect wearing a different dialect.
#
# PANE 1 (left)  plain git, no hooks: both merges succeed, the tree now
#                asserts inbound_edges twice with two different values, and
#                git is perfectly happy. It exits 0.
# PANE 2 (right) this runtime: the same second merge is REFUSED. No merge
#                commit is created, the branch keeps one parent, and
#                .quilt/adjudications/<short>.json names the winner, keeps the
#                losing claim verbatim, and gives the reason.
#
# No judge, no model, no network, no account. The winner is an ordering rule,
# and the record says so in a field you can read.
#
# Exit 0 iff both panes behaved as described.

set -u
SRC=$(cd "$(dirname "$0")" && pwd)
SCRATCH=$(mktemp -d /tmp/quilt-demo-XXXXXX)
rc=0
say() { printf '%s\n' "$*"; }
rule() { say "------------------------------------------------------------------"; }

# pane <name> <gitdir> : build the same two-PR fixture in a repo
#   $2 = "plain" -> do not install the runtime
pane() {
  name=$1; dir=$2; mode=$3
  mkdir -p "$dir"
  git init -q -b main "$dir"
  git -C "$dir" config user.email demo@quilt.local
  git -C "$dir" config user.name  quilt-demo
  git -C "$dir" config commit.gpgsign false
  if [ "$mode" = quilt ]; then
    cp -R "$SRC/.quilt" "$dir/.quilt"
    ( cd "$dir" && ./.quilt/bin/quilt-init >/dev/null 2>&1 )
    # The hook-generated journal is a live append-only working file. Two
    # branches that both ticked it will text-conflict on it, and that conflict
    # is not the story this demo is telling — it would mask the refusal behind
    # a merge error about .quilt/watch.log. So the generated paths are
    # untracked here. The substrate's own pins fold them into history instead
    # (P5); that is a journalkeeping choice, not a runtime requirement.
    printf '.quilt/watch.log\n.quilt/receipts/\n.quilt/adjudications/\n' \
      > "$dir/.gitignore"
  fi
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -qm "skeleton" >/dev/null 2>&1

  mkdir -p "$dir/cells/inbox/dials"
  i=0
  while [ $i -le 15 ]; do echo 0.0 > "$dir/cells/inbox/dials/$i"; i=$((i + 1)); done
  cat > "$dir/cells/inbox/body" <<'BODY'
# fleet referral counter — the real quilt-tools fixture
verified: 15
pending: 4
notes: recounted from merged main
BODY
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -qm "cells: seed inbox" >/dev/null 2>&1

  # PR #32 — appends its claim at the end of the body
  git -C "$dir" checkout -qb pr32 >/dev/null 2>&1
  printf 'claim: inbound_edges = 19  by quilt-tools#32 fb2e041\n' \
    >> "$dir/cells/inbox/body"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -qm "PR #32: inbound_edges = 19 (fb2e041)" >/dev/null 2>&1

  # PR #33 — asserts the same key, at a DIFFERENT line, so git's line merge
  # succeeds cleanly. The text is fine. The meaning is not.
  git -C "$dir" checkout -q main >/dev/null 2>&1
  git -C "$dir" checkout -qb pr33 >/dev/null 2>&1
  sed -i '2a claim: inbound_edges = 21  by quilt-tools#33 0101409' \
    "$dir/cells/inbox/body"
  git -C "$dir" add -A >/dev/null 2>&1
  git -C "$dir" commit -qm "PR #33: inbound_edges = 21 (0101409)" >/dev/null 2>&1
  git -C "$dir" checkout -q main >/dev/null 2>&1
}

# ==================================================================== PANE 1
say ""
rule
say "PANE 1 — plain git, no hooks"
rule
D1="$SCRATCH/plain"
pane plain "$D1" plain

git -C "$D1" merge --no-ff pr32 -m "merge #32" >/dev/null 2>&1
say "  \$ git merge --no-ff pr32        -> exit 0"
git -C "$D1" merge --no-ff pr33 -m "merge #33" >/dev/null 2>&1
m1=$?
say "  \$ git merge --no-ff pr33        -> exit $m1"
say ""
say "  parents of HEAD : $(git -C "$D1" rev-list --parents -n1 HEAD | wc -w) (commit + 2 parents = merged)"
say ""
say "  cells/inbox/body now reads:"
sed 's/^/    | /' "$D1/cells/inbox/body"
n=$(grep -c '^claim: inbound_edges' "$D1/cells/inbox/body")
say ""
say "  claims for key 'inbound_edges': $n"
if [ "$m1" -eq 0 ] && [ "$n" -eq 2 ]; then
  say "  PANE 1: git merged both PRs and exited 0 over a tree that asserts one"
  say "          fact twice with two different values. It never noticed."
else
  say "  PANE 1: UNEXPECTED (merge exit=$m1, claims=$n)"; rc=1
fi

# ==================================================================== PANE 2
say ""
rule
say "PANE 2 — this runtime, same two PRs"
rule
D2="$SCRATCH/quilt"
pane quilt "$D2" quilt

git -C "$D2" merge --no-ff pr32 -m "merge #32" >/dev/null 2>&1
say "  \$ git merge --no-ff pr32        -> exit 0   (one claim, no contradiction)"
head_before=$(git -C "$D2" rev-parse HEAD)

say ""
say "  \$ git merge --no-ff pr33"
mout=$(git -C "$D2" merge --no-ff pr33 -m "merge #33" 2>&1)
m2=$?
printf '%s\n' "$mout" | sed 's/^/  /'
say ""
say "  \$ echo \$?                       -> $m2"

par=$(git -C "$D2" rev-list --parents -n1 HEAD | wc -w)
head_after=$(git -C "$D2" rev-parse HEAD)
say "  HEAD before the merge : ${head_before%${head_before#????????}}"
say "  HEAD after  the merge : ${head_after%${head_after#????????}}"
if [ "$m2" -ne 0 ] && [ "$head_before" = "$head_after" ]; then
  say "  PANE 2: REFUSED. HEAD did not move: no merge commit was created, so"
  say "          the branch never gained a second parent and the contradiction"
  say "          is not history. It is only a file on disk."
else
  say "  PANE 2: UNEXPECTED (exit=$m2, HEAD moved: $head_before -> $head_after)"; rc=1
fi

adj=$(ls -1 "$D2/.quilt/adjudications" 2>/dev/null | head -n1)
say ""
if [ -n "$adj" ]; then
  say "  .quilt/adjudications/$adj:"
  sed 's/^/    /' "$D2/.quilt/adjudications/$adj"
else
  say "  NO ADJUDICATION RECORD — expected one under .quilt/adjudications/"; rc=1
fi

# Did the refusal write anything under cells/? The merged tree is still sitting
# in the working tree (that is what a pending merge means), so the honest
# question is narrower: did it write to a cell file, and did it touch a dial?
dials=$(git -C "$D2" status --porcelain -- 'cells/*/dials' | wc -l | tr -d ' ')
say ""
say "  dial files changed by the refusal: $dials (want 0 — the check reads bodies, never dials)"
[ "$dials" = "0" ] || rc=1
newcells=$(git -C "$D2" status --porcelain -- cells/ | grep -c '^??' || true)
say "  new files it created under cells/:  $newcells (want 0 — it only writes the record)"
[ "$newcells" = "0" ] || rc=1

say ""
rule
if [ "$rc" -eq 0 ]; then
  say "DEMO: both panes behaved as described."
  say ""
  say "Left  : two PRs merged, exit 0, tree asserts one key twice."
  say "Right : same merge refused, exit $m2, both claims kept verbatim,"
  say "        one merge parent, and a record that names the rule it used."
  say ""
  say "The rule is an ordering, not a judgment. No judge ran. The record says so:"
  say "  \"adjudication\": \"mechanical\""
  say "  \"judge\": \"none — no model is in this loop, by design\""
  rm -rf "$SCRATCH"
  exit 0
fi
say "DEMO: FAILED — see above. scratch kept: $SCRATCH"
exit 1
