#!/usr/bin/env bash
# tests/pins_quiltgit.sh — FAIL-first pin harness for the quilt-in-git PoC.
#
# Plain bash + git + awk. No bats, no network. Every pin runs in its own
# scratch repo under /tmp (one mktemp -d root, one subdir per pin), so pins
# cannot leak state into each other.
#
#   P1  dial commit  -> .quilt/receipts/<short>.json exists (holds commit
#                       hash + alias) and .quilt/watch.log grows by EXACTLY
#                       one line.
#   P2  freeze       -> dial 15 = 0.8 commits; the NEXT commit touching that
#                       cell is rejected (exit 1, "frozen" in the error,
#                       file/HEAD unchanged).
#   P3  cascade      -> a.dials/1 = 0.9 and b's links say "a 0.5"; ticking a
#                       gives b.dials/14 == 0.45 and a "quilt: cascade after"
#                       commit.
#   P4  rewind       -> change a dial, commit, checkout the previous commit
#                       for cells/<alias>/ -> dial file back to old value.
#   P5  clone        -> in a fresh clone hooks do NOT fire (no receipt, no
#                       watch line); after quilt-init they do.
#   P6  non-cell     -> a README-only commit creates NO receipt and NO
#                       watch.log line.
#   P7  merge        -> a --no-ff merge of a branch that changed cells/
#                       produces a receipt (merge:true, changed_cells
#                       non-empty) and exactly one watch line. This is the pin
#                       the substrate could not have: `diff-tree` without -m
#                       prints nothing for a merge commit, so the old probe
#                       exited 0 having seen nothing.
#   P8  refusal      -> a merge whose result contains two attributed `claim:`
#                       lines for the same key with different values is REFUSED
#                       (non-zero exit, HEAD does not move) and writes
#                       .quilt/adjudications/<short>.json keeping both claims
#                       verbatim, naming a winner, the losers, and a reason.
#                       Two claims from ONE author, and unattributed lines, are
#                       not contradictions and must not be refused.
#   P9  receipt hash -> the watch line's second field is a real, recomputable,
#                       algorithm-prefixed content hash of the receipt this tick
#                       wrote, and it changes when the receipt changes.
#   P10 no drift     -> the hooks quilt-init writes are byte-identical to the
#                       hooks checked into the repo, so the runtime cannot rot
#                       apart from its generator.
#   P11 verdict      -> the verdict table attributes each failing check id to
#                       its own pin. " P10" contains the substring " P1", so
#                       the original `*" $p"*` test would let a P10 failure
#                       flip P1 to FAIL.
#
# Exit 0 iff all pin verdicts are PASS.

set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d /tmp/quilt-pins-XXXXXX)"

PASS=0
FAIL=0
FAILS=" "          # space-padded list of failed check ids, e.g. " P1a P2c "
KEEP_SCRATCH=0

say() { printf '%s\n' "$*"; }
ok()  { PASS=$((PASS + 1)); say "PASS $1"; }
bad() { FAIL=$((FAIL + 1)); KEEP_SCRATCH=1; FAILS="$FAILS$1 "; say "FAIL $1"; }

count_lines() {    # count_lines <file>
  if [ -f "$1" ]; then wc -l < "$1" | tr -d '[:space:]'; else echo 0; fi
}
count_receipts() { # count_receipts <repo>
  ls -1 "$1/.quilt/receipts" 2>/dev/null | wc -l | tr -d '[:space:]'
}

count_adjudications() { # count_adjudications <repo>
  ls -1 "$1/.quilt/adjudications" 2>/dev/null | wc -l | tr -d '[:space:]'
}

# fold_journal <repo>
#
# The post-commit hook appends to .quilt/watch.log on every commit, and that
# file is tracked. So the moment a commit lands, the working tree has a
# modified tracked file, and `git checkout <other-branch>` REFUSES: "Your
# local changes to the following files would be overwritten by checkout".
#
# Measured on git 2.39.5 while writing P8: `git checkout main` failed, the
# script carried on regardless, the next `checkout -b pr33` silently branched
# off pr32 instead of main, and the pin then "passed" against a fixture that
# had quietly become something else. A multi-branch pin has to fold the
# journal before it switches, which is what the substrate's own P5 does.
fold_journal() { # fold_journal <repo>
  git -C "$1" add .quilt >/dev/null 2>&1
  git -C "$1" commit -qm "journal: fold receipts and watch log" >/dev/null 2>&1
}

# on <repo> <branch> : switch branches or die loudly. Never fall through.
on() { # on <repo> <branch>
  fold_journal "$1"
  if ! git -C "$1" checkout -q "$2" 2>/dev/null; then
    bad "checkout $2 failed in $(basename "$1") — a pin ran against the wrong branch"
    return 1
  fi
  return 0
}

# new_repo <name>: fresh git repo at $SCRATCH/<name> with the .quilt runtime
# from $SRC committed and activated via ./.quilt/bin/quilt-init.
new_repo() {
  local d="$SCRATCH/$1"
  git init -q "$d"                                                || return 1
  git -C "$d" config user.email pins@quilt.local                  || return 1
  git -C "$d" config user.name  quilt-pins                        || return 1
  git -C "$d" config commit.gpgsign false                         || return 1
  cp -R "$SRC/.quilt" "$d/.quilt"                                 || return 1
  git -C "$d" add -A                                              || return 1
  git -C "$d" commit -qm "skeleton: quilt runtime"                || return 1
  ( cd "$d" && ./.quilt/bin/quilt-init ) >/dev/null 2>&1          || return 1
  echo "$d"
}

# seed_cell <repo> <alias>: full dials/{0..15} (all 0.0) + body, committed.
# The commit fires the hooks once (one receipt, one watch line) — pins always
# snapshot baselines AFTER seeding.
seed_cell() {
  local repo=$1 alias=$2 i
  mkdir -p "$repo/cells/$alias/dials"
  echo "seed $alias" > "$repo/cells/$alias/body"
  for i in $(seq 0 15); do echo 0.0 > "$repo/cells/$alias/dials/$i"; done
  git -C "$repo" add cells
  git -C "$repo" commit -qm "cells: seed $alias"
}

# ---------------------------------------------------------------- P1
pin_p1() {
  local d
  if ! d=$(new_repo p1); then bad "P1-0 setup (quilt-init runnable?)"; return; fi
  seed_cell "$d" a
  local wl_before
  wl_before=$(count_lines "$d/.quilt/watch.log")

  if ( cd "$d" && echo 0.42 > cells/a/dials/0 && git add cells/a/dials/0 \
       && git commit -qm "tick: a dial0=0.42" ) >/dev/null 2>&1; then
    ok "P1a dial commit accepted"
  else
    bad "P1a dial commit failed"; return
  fi

  local full short R wl_after last
  full=$(git -C "$d" rev-parse HEAD)
  short=$(git -C "$d" rev-parse --short HEAD)
  R="$d/.quilt/receipts/$short.json"
  if [ -f "$R" ]; then ok "P1b receipt exists (.quilt/receipts/$short.json)"
  else bad "P1b receipt missing: $R"; fi
  if grep -qF "$full" "$R" 2>/dev/null; then ok "P1c receipt contains commit hash"
  else bad "P1c receipt lacks commit hash"; fi
  if grep -q '"a"' "$R" 2>/dev/null; then ok "P1d receipt contains alias a"
  else bad "P1d receipt lacks alias a"; fi
  wl_after=$(count_lines "$d/.quilt/watch.log")
  if [ "$((wl_after - wl_before))" -eq 1 ]; then
    ok "P1e watch.log grew by exactly one line ($wl_before->$wl_after)"
  else
    bad "P1e watch.log delta $wl_before->$wl_after (want +1)"
  fi
  last=$(tail -n 1 "$d/.quilt/watch.log" 2>/dev/null)
  case "$last" in
    tick\ *) ok "P1f watch line starts with 'tick' ($last)" ;;
    *)       bad "P1f malformed watch line: '$last'" ;;
  esac
}

# ---------------------------------------------------------------- P2
pin_p2() {
  local d
  if ! d=$(new_repo p2); then bad "P2-0 setup (quilt-init runnable?)"; return; fi
  seed_cell "$d" fz

  if ( cd "$d" && ./.quilt/bin/quilt-tick fz 15 0.8 ) >/dev/null 2>&1; then
    ok "P2a freeze commit (dial15=0.8) accepted"
  else
    bad "P2a freeze commit rejected"; return
  fi
  local head_frozen headv out rc
  head_frozen=$(git -C "$d" rev-parse HEAD)

  out=$( cd "$d" && ./.quilt/bin/quilt-tick fz 1 0.7 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ]; then ok "P2b next commit touching cell rejected (rc=$rc)"
  else bad "P2b frozen-cell commit NOT rejected (rc=0)"; fi
  case "$out" in
    *frozen*) ok "P2c error mentions frozen" ;;
    *)        bad "P2c error lacks 'frozen': $out" ;;
  esac
  if [ "$(tr -d '[:space:]' < "$d/cells/fz/dials/1")" = "0.7" ]; then
    ok "P2d dial file unchanged by rejected commit (still 0.7 as written)"
  else
    bad "P2d dial file mangled: $(cat "$d/cells/fz/dials/1" 2>/dev/null)"
  fi
  headv=$(git -C "$d" show HEAD:cells/fz/dials/1 2>/dev/null | tr -d '[:space:]')
  if [ "$headv" = "0.0" ]; then ok "P2e committed dial1 still 0.0"
  else bad "P2e committed dial1 is '$headv' (want 0.0)"; fi
  if [ "$(git -C "$d" rev-parse HEAD)" = "$head_frozen" ]; then
    ok "P2f no new commit was created"
  else
    bad "P2f HEAD moved despite rejection"
  fi
}

# ---------------------------------------------------------------- P3
pin_p3() {
  local d v
  if ! d=$(new_repo p3); then bad "P3-0 setup (quilt-init runnable?)"; return; fi
  seed_cell "$d" a
  seed_cell "$d" b
  printf 'a 0.5\n' > "$d/cells/b/links"
  git -C "$d" add cells/b/links
  git -C "$d" commit -qm "cells: b links a 0.5" || { bad "P3a links commit failed"; return; }

  if ( cd "$d" && ./.quilt/bin/quilt-tick a 1 0.9 ) >/dev/null 2>&1; then
    ok "P3a tick a dial1=0.9 committed"
  else
    bad "P3a tick a dial1=0.9 failed"; return
  fi
  v=$(tr -d '[:space:]' < "$d/cells/b/dials/14")
  if awk -v x="$v" 'BEGIN{exit !(x+0 == 0.45)}'; then
    ok "P3b b.dials/14 == $v (== 0.45)"
  else
    bad "P3b b.dials/14 == '$v' (want 0.45)"
  fi
  if git -C "$d" log --format=%s | grep -q '^quilt: cascade after'; then
    ok "P3c 'quilt: cascade after' commit exists"
  else
    bad "P3c no 'quilt: cascade after' commit"
  fi
}

# ---------------------------------------------------------------- P4
pin_p4() {
  local d prev
  if ! d=$(new_repo p4); then bad "P4-0 setup (quilt-init runnable?)"; return; fi
  seed_cell "$d" a

  ( cd "$d" && ./.quilt/bin/quilt-tick a 7 0.11 ) >/dev/null 2>&1 \
    || { bad "P4a first tick failed"; return; }
  prev=$(git -C "$d" rev-parse HEAD)
  ( cd "$d" && ./.quilt/bin/quilt-tick a 7 0.99 ) >/dev/null 2>&1 \
    || { bad "P4b second tick failed"; return; }
  if [ "$(tr -d '[:space:]' < "$d/cells/a/dials/7")" = "0.99" ]; then
    ok "P4c new dial value 0.99 committed"
  else
    bad "P4c dial not at 0.99"; return
  fi

  git -C "$d" checkout -q "$prev" -- cells/a/
  if [ "$(tr -d '[:space:]' < "$d/cells/a/dials/7")" = "0.11" ]; then
    ok "P4d rewind (checkout prev -- cells/a/) restores 0.11"
  else
    bad "P4d rewind got '$(cat "$d/cells/a/dials/7" 2>/dev/null)' (want 0.11)"
  fi
}

# ---------------------------------------------------------------- P5
pin_p5() {
  local d c wl0 rc0 s1 s2
  if ! d=$(new_repo p5); then bad "P5-0 setup (quilt-init runnable?)"; return; fi
  seed_cell "$d" a
  # fold the journal into history so the clone carries receipts + watch.log
  git -C "$d" add .quilt && git -C "$d" commit -qm "journal" >/dev/null 2>&1

  c="$SCRATCH/p5-clone"
  git clone -q "$d" "$c" || { bad "P5a clone failed"; return; }
  git -C "$c" config user.email pins@quilt.local
  git -C "$c" config user.name  quilt-pins
  git -C "$c" config commit.gpgsign false

  wl0=$(count_lines "$c/.quilt/watch.log")
  rc0=$(count_receipts "$c")

  ( cd "$c" && echo 0.5 > cells/a/dials/2 && git add cells/a/dials/2 \
    && git commit -qm "tick: clone pre-init" ) >/dev/null 2>&1 \
    || { bad "P5b pre-init commit failed"; return; }
  s1=$(git -C "$c" rev-parse --short HEAD)
  if [ ! -f "$c/.quilt/receipts/$s1.json" ] \
     && [ "$(count_receipts "$c")" = "$rc0" ] \
     && [ "$(count_lines "$c/.quilt/watch.log")" = "$wl0" ]; then
    ok "P5c fresh clone: no receipt, no watch line (hooks inert)"
  else
    bad "P5c hooks fired in fresh clone before quilt-init"
  fi

  ( cd "$c" && ./.quilt/bin/quilt-init ) >/dev/null 2>&1 \
    || { bad "P5d quilt-init failed in clone"; return; }
  if [ "$(git -C "$c" config core.hooksPath)" = ".quilt/hooks" ]; then
    ok "P5e quilt-init set core.hooksPath=.quilt/hooks"
  else
    bad "P5e core.hooksPath is '$(git -C "$c" config core.hooksPath)'"
  fi

  ( cd "$c" && echo 0.6 > cells/a/dials/3 && git add cells/a/dials/3 \
    && git commit -qm "tick: clone post-init" ) >/dev/null 2>&1 \
    || { bad "P5f post-init commit failed"; return; }
  s2=$(git -C "$c" rev-parse --short HEAD)
  if [ -f "$c/.quilt/receipts/$s2.json" ]; then
    ok "P5g receipt appears after quilt-init ($s2.json)"
  else
    bad "P5g no receipt after quilt-init"
  fi
  if [ "$(count_lines "$c/.quilt/watch.log")" -gt "$wl0" ]; then
    ok "P5h watch.log grew after quilt-init"
  else
    bad "P5h watch.log did not grow after quilt-init"
  fi
}

# ---------------------------------------------------------------- P6
pin_p6() {
  local d wl0 rc0
  if ! d=$(new_repo p6); then bad "P6-0 setup (quilt-init runnable?)"; return; fi
  seed_cell "$d" a
  wl0=$(count_lines "$d/.quilt/watch.log")
  rc0=$(count_receipts "$d")

  ( cd "$d" && echo "# scratch readme" > README.md && git add README.md \
    && git commit -qm "docs: readme" ) >/dev/null 2>&1 \
    || { bad "P6a readme commit failed"; return; }

  if [ "$(count_receipts "$d")" = "$rc0" ]; then
    ok "P6b non-cell commit created NO receipt"
  else
    bad "P6b receipt created by non-cell commit"
  fi
  if [ "$(count_lines "$d/.quilt/watch.log")" = "$wl0" ]; then
    ok "P6c non-cell commit added NO watch.log line"
  else
    bad "P6c watch.log grew on non-cell commit"
  fi
}

# ---------------------------------------------------------------- P7
pin_p7() {
  local d
  if ! d=$(new_repo p7); then bad "P7-0 setup (quilt-init runnable?)"; return; fi
  seed_cell "$d" a

  # main moves a dial, the branch moves the body: a CLEAN merge that still
  # changes cells/. If the probe cannot see merges, this merge is invisible.
  git -C "$d" checkout -qb pr
  printf 'from the branch\n' > "$d/cells/a/body"
  git -C "$d" add cells/a/body
  git -C "$d" commit -qm "pr: body" >/dev/null 2>&1
  on "$d" main || return
  printf '0.5\n' > "$d/cells/a/dials/3"
  git -C "$d" add cells/a/dials/3
  git -C "$d" commit -qm "main: dial3" >/dev/null 2>&1

  local wl_before rc_before
  wl_before=$(count_lines "$d/.quilt/watch.log")
  rc_before=$(count_receipts "$d")
  fold_journal "$d"     # a dirty tracked watch.log blocks the merge itself

  if ! git -C "$d" merge --no-ff pr -m "merge: pr" >/dev/null 2>&1; then
    bad "P7a clean merge failed"; return
  fi
  ok "P7a clean merge of a cells/ branch committed"

  if [ "$(git -C "$d" rev-list --parents -n1 HEAD | wc -w)" -lt 3 ]; then
    bad "P7b HEAD is not a 2-parent merge commit"; return
  fi
  ok "P7b HEAD is a 2-parent merge commit"

  local s R
  s=$(git -C "$d" rev-parse --short HEAD)
  R="$d/.quilt/receipts/$s.json"
  if [ -f "$R" ]; then ok "P7c merge produced a receipt ($s.json)"
  else bad "P7c merge produced NO receipt (expected $R)"; return; fi

  if grep -q '"merge": true' "$R"; then ok "P7d receipt records merge: true"
  else bad "P7d receipt lacks 'merge: true'"; fi

  if grep -q '"parents": 2' "$R"; then ok "P7e receipt records parents: 2"
  else bad "P7e receipt lacks 'parents: 2'"; fi

  if grep -q '"a"' "$R"; then ok "P7f receipt names the changed cell a"
  else bad "P7f receipt changed_cells empty (the merge was invisible)"; fi

  if [ "$(( $(count_receipts "$d") - rc_before ))" -ge 1 ]; then
    ok "P7g receipt count grew on merge"
  else bad "P7g no receipt added by merge"; fi

  if [ "$(( $(count_lines "$d/.quilt/watch.log") - wl_before ))" -eq 1 ]; then
    ok "P7h watch.log grew by exactly one line on merge"
  else bad "P7h watch.log delta on merge != +1"; fi
}

# ---------------------------------------------------------------- P10
# The substrate's own design choice is that hooks are GENERATED from
# quilt-init, "so they cannot rot apart". Nothing tested that. This does.
pin_p10() {
  local d
  if ! d=$(new_repo p10); then bad "P10-0 setup (quilt-init runnable?)"; return; fi
  local h diff
  for h in pre-commit post-commit post-merge pre-merge-commit; do
    if [ ! -f "$d/.quilt/hooks/$h" ]; then
      bad "P10 quilt-init did not write $h"; return
    fi
  done
  ok "P10a quilt-init wrote all four hooks"
  for h in pre-commit post-commit post-merge pre-merge-commit; do
    if ! diff -q "$SRC/.quilt/hooks/$h" "$d/.quilt/hooks/$h" >/dev/null 2>&1; then
      bad "P10 $h generated by quilt-init DIFFERS from the checked-in copy"
      diff "$SRC/.quilt/hooks/$h" "$d/.quilt/hooks/$h" | head -20
      return
    fi
    if [ ! -x "$d/.quilt/hooks/$h" ]; then
      bad "P10 $h is not executable"; return
    fi
  done
  ok "P10b generated hooks are byte-identical to the checked-in copies"
  ok "P10c all four hooks are executable"
}

# verdict_of <pin> -> PASS | FAIL
#
# A pin FAILS if any recorded check id belongs to it: either the bare pin id
# ("P1"), or that pin id followed by a LETTER or DASH ("P1a", "P1-0").
#
# The obvious spelling — case "$FAILS" in *" $1"*) — is wrong the moment the pin
# count reaches ten, because " P10" CONTAINS the substring " P1". Under it a
# P10 failure silently flips P1 to FAIL, and the table lies. A digit is what
# separates a check suffix from another pin's name, so a check id may continue
# with a letter or a dash but never a digit. P11 pins that distinction.
verdict_of() {
  local p=$1 w
  for w in $FAILS; do
    [ "$w" = "$p" ] && { echo FAIL; return; }
    case "$w" in
      "$p"[A-Za-z-]*) echo FAIL; return ;;
    esac
  done
  echo PASS
}

# selftest_verdict — the verdict table is the only thing a reader trusts, so it
# gets its own test rather than being assumed correct.
selftest_verdict() {
  local rc=0
  local save=$FAILS            # this function fakes failures; it must not leak
  FAILS=" P1a P7c P10 "
  [ "$(verdict_of P1)"  = FAIL ] || { say "FAIL P11a P1 should FAIL on P1a";   rc=1; }
  [ "$(verdict_of P7)"  = FAIL ] || { say "FAIL P11b P7 should FAIL on P7c";   rc=1; }
  [ "$(verdict_of P10)" = FAIL ] || { say "FAIL P11c P10 should FAIL on P10";  rc=1; }
  [ "$(verdict_of P2)"  = PASS ] || { say "FAIL P11d P2 should PASS";          rc=1; }
  FAILS=" P10 "
  [ "$(verdict_of P1)"  = PASS ] || { say "FAIL P11e P10 must not steal P1";    rc=1; }
  FAILS=" P10a "
  [ "$(verdict_of P10)" = FAIL ] || { say "FAIL P11f P10a belongs to P10";      rc=1; }
  [ "$(verdict_of P1)"  = PASS ] || { say "FAIL P11g P10a must not steal P1";  rc=1; }
  FAILS=$save
  return $rc
}

# ---------------------------------------------------------------- P8
# The entry. A merge whose result asserts one key twice with two values, from
# two different attributions, is REFUSED: no merge commit, non-zero exit, and
# an adjudication record that keeps BOTH claims verbatim.
pin_p8() {
  local d
  if ! d=$(new_repo p8); then bad "P8-0 setup (quilt-init runnable?)"; return; fi
  seed_cell "$d" inbox

  # two PRs, one key, two values, placed so git's line merge SUCCEEDS. The
  # text merges cleanly. The meaning does not. (P8m below covers the other
  # door, where the two PRs do text-conflict and the merge is concluded by
  # hand with `git commit`.)
  cat > "$d/cells/inbox/body" <<'BODY'
# fleet referral counter
verified: 15
pending: 4
notes: recounted from merged main
BODY
  git -C "$d" add -A && git -C "$d" commit -qm "cells: seed inbox body" >/dev/null 2>&1

  git -C "$d" checkout -qb pr32
  printf 'claim: inbound_edges = 19  by quilt-tools#32 fb2e041\n' \
    >> "$d/cells/inbox/body"
  git -C "$d" add -A && git -C "$d" commit -qm "PR #32" >/dev/null 2>&1
  on "$d" main || return
  git -C "$d" checkout -qb pr33
  sed -i '2a claim: inbound_edges = 21  by quilt-tools#33 0101409' \
    "$d/cells/inbox/body"
  git -C "$d" add -A && git -C "$d" commit -qm "PR #33" >/dev/null 2>&1
  on "$d" main || return

  # PR #32 alone must still merge: one claim is not a contradiction.
  fold_journal "$d"     # a dirty tracked watch.log blocks the merge itself
  if git -C "$d" merge --no-ff pr32 -m "merge #32" >/dev/null 2>&1; then
    ok "P8a single-claim merge accepted"
  else bad "P8a single-claim merge was wrongly refused"; return; fi

  local head_before
  head_before=$(git -C "$d" rev-parse HEAD)
  fold_journal "$d"

  local mout
  mout=$(git -C "$d" merge --no-ff pr33 -m "merge #33" 2>&1)
  local rc=$?
  if [ "$rc" -ne 0 ]; then ok "P8b contradictory merge refused (rc=$rc)"
  else bad "P8b contradictory merge was ALLOWED (rc=0)"; fi

  # A non-zero exit is not enough on its own: a merge can also fail because the
  # tree is dirty, and that would make this pin green for the wrong reason. The
  # refusal has to be the thing that stopped it.
  case "$mout" in
    *"REFUSING the merge"*) ok "P8b2 the refusal is what stopped the merge" ;;
    *) bad "P8b2 merge failed but not by refusal: $mout"; return ;;
  esac

  if [ "$(git -C "$d" rev-parse HEAD)" = "$head_before" ]; then
    ok "P8c HEAD did not move — no merge commit was created"
  else bad "P8c HEAD moved: the merge landed despite the refusal"; fi

  local A
  A=$(ls -1 "$d/.quilt/adjudications" 2>/dev/null | head -n1)
  if [ -n "$A" ]; then ok "P8d adjudication record written ($A)"
  else bad "P8d no record under .quilt/adjudications/"; return; fi

  if grep -q 'claim: inbound_edges = 19  by quilt-tools#32 fb2e041' "$d/.quilt/adjudications/$A"; then
    ok "P8e losing claim kept VERBATIM in the record"
  else bad "P8e record does not carry the losing claim verbatim"; fi

  if grep -q 'claim: inbound_edges = 21  by quilt-tools#33 0101409' "$d/.quilt/adjudications/$A"; then
    ok "P8f winning claim kept VERBATIM in the record"
  else bad "P8f record does not carry the winning claim verbatim"; fi

  if grep -q '"winner"' "$d/.quilt/adjudications/$A" \
     && grep -q '"losers"' "$d/.quilt/adjudications/$A"; then
    ok "P8g record names a winner and a losers list"
  else bad "P8g record lacks winner/losers"; fi

  if grep -q '"reason"' "$d/.quilt/adjudications/$A"; then
    ok "P8h record states a reason"
  else bad "P8h record lacks a reason"; fi

  if grep -q '"adjudication": "mechanical"' "$d/.quilt/adjudications/$A" \
     && grep -q '"judge": "none' "$d/.quilt/adjudications/$A"; then
    ok "P8i record declares the adjudication mechanical and judge-free"
  else bad "P8i record does not declare itself mechanical/judge-free"; fi

  # The refusal must not have written a single dial file.
  if [ "$(git -C "$d" status --porcelain -- 'cells/*/dials' | wc -l | tr -d ' ')" = "0" ]; then
    ok "P8j refusal touched no dial file"
  else bad "P8j refusal modified a dial file"; fi

  # Two claims, ONE author, is a retraction, not a contradiction.
  git -C "$d" merge --abort >/dev/null 2>&1
  git -C "$d" checkout -qb solo
  printf 'claim: inbound_edges = 99  by quilt-tools#32 fb2e041\n' \
    >> "$d/cells/inbox/body"
  git -C "$d" add -A && git -C "$d" commit -qm "solo restatement" >/dev/null 2>&1
  fold_journal "$d"
  if git -C "$d" merge --no-ff solo -m "merge solo" >/dev/null 2>&1; then
    ok "P8k one author restating a key is NOT treated as a contradiction"
  else bad "P8k same-author restatement was wrongly refused"; fi

  # An unattributed line is not adjudicable either.
  on "$d" main || return
  git -C "$d" checkout -qb bare
  printf 'claim: ungrounded = 1\n' >> "$d/cells/inbox/body"
  git -C "$d" add -A && git -C "$d" commit -qm "bare assertion" >/dev/null 2>&1
  fold_journal "$d"
  if git -C "$d" merge --no-ff bare -m "merge bare" >/dev/null 2>&1; then
    ok "P8l an unattributed assertion is not adjudicable"
  else bad "P8l unattributed assertion was wrongly refused"; fi

  # ---------------------------------------------------------------- P8m
  # THE OTHER DOOR. git does not run pre-merge-commit when a conflict was
  # resolved by hand and concluded with `git commit` — measured on git 2.39.5:
  # with only pre-merge-commit installed that merge commit was created and the
  # hook never fired. pre-commit is the only hook git runs on that path, so the
  # refusal has to be enforced from there too or the common case walks past it.
  git -C "$d" checkout -qb c32
  printf 'claim: share = 7  by pr#32 aaaaaaa\n' > "$d/cells/inbox/body"
  git -C "$d" add -A && git -C "$d" commit -qm "PR #32 same line" >/dev/null 2>&1
  on "$d" main || return
  git -C "$d" checkout -qb c33
  printf 'claim: share = 9  by pr#33 bbbbbbb\n' > "$d/cells/inbox/body"
  git -C "$d" add -A && git -C "$d" commit -qm "PR #33 same line" >/dev/null 2>&1
  on "$d" main || return

  git -C "$d" merge --no-ff c32 -m "merge c32" >/dev/null 2>&1
  local head_c
  head_c=$(git -C "$d" rev-parse HEAD)

  if git -C "$d" merge --no-ff c33 -m "merge c33" >/dev/null 2>&1; then
    bad "P8m fixture did not conflict — the other door was not exercised"; return
  fi
  ok "P8m1 two PRs on the same line really do conflict"

  # Resolve the way "keep both" resolves it: concatenate the two claims.
  printf 'claim: share = 7  by pr#32 aaaaaaa\nclaim: share = 9  by pr#33 bbbbbbb\n' \
    > "$d/cells/inbox/body"
  git -C "$d" add cells/inbox/body >/dev/null 2>&1

  local cout croc
  cout=$(git -C "$d" commit -m "merge c33, keep both" 2>&1)
  croc=$?
  if [ "$croc" -ne 0 ]; then ok "P8m2 hand-resolved contradiction refused (rc=$croc)"
  else bad "P8m2 git commit of a contradictory merge was ALLOWED"; fi

  case "$cout" in
    *"REFUSING the merge"*) ok "P8m3 the refusal came from pre-commit" ;;
    *) bad "P8m3 commit failed but not by refusal: $cout" ;;
  esac

  if [ "$(git -C "$d" rev-parse HEAD)" = "$head_c" ]; then
    ok "P8m4 HEAD did not move on the git-commit path either"
  else bad "P8m4 HEAD moved — the merge commit was written anyway"; fi

  local m
  m=$(grep -l 'claim: share = 9  by pr#33 bbbbbbb' "$d"/.quilt/adjudications/*.json 2>/dev/null | head -n1)
  if [ -n "$m" ]; then ok "P8m5 adjudication record written on the git-commit path"
  else bad "P8m5 no record written on the git-commit path"; fi
}

# ---------------------------------------------------------------- P9
# The README has always documented `tick <short> <receipt-hash> <cells>`, and
# field 2 has always been a second copy of field 1. It must now be the content
# hash of the receipt, and a third party must be able to recompute it.
pin_p9() {
  local d
  if ! d=$(new_repo p9); then bad "P9-0 setup (quilt-init runnable?)"; return; fi
  seed_cell "$d" a

  ( cd "$d" && echo 0.42 > cells/a/dials/0 && git add cells/a/dials/0 \
     && git commit -qm "tick: a dial0=0.42" ) >/dev/null 2>&1 \
    || { bad "P9a tick commit failed"; return; }

  local line f1 f2
  line=$(tail -n 1 "$d/.quilt/watch.log")
  f1=$(printf '%s\n' "$line" | cut -d' ' -f2)
  f2=$(printf '%s\n' "$line" | cut -d' ' -f3)
  say "    watch line: $line"

  if [ "$f1" = "$f2" ]; then
    bad "P9b field 2 is still a duplicate of field 1 ($f1)"
  else ok "P9b field 2 differs from field 1"; fi

  if [ -f "$d/.quilt/receipts/$f1.json" ]; then
    ok "P9c field 1 names the receipt this tick wrote ($f1.json)"
  else bad "P9c no receipt named $f1"; return; fi

  # Recompute independently of the runtime, with coreutils rather than
  # .quilt/bin/quilt-hash, so this is a check and not a tautology.
  local expect algo
  algo=${f2%%:*}
  digest=${f2#*:}
  if [ "$f2" = "$digest" ]; then
    bad "P9d field 2 carries no algorithm prefix: $f2"; return
  fi
  ok "P9d field 2 is algorithm-prefixed ($algo)"

  case "$algo" in
    sha256) expect=$(sha256sum "$d/.quilt/receipts/$f1.json" | cut -d' ' -f1) ;;
    sha1)   expect=$(git hash-object -t blob --no-filters "$d/.quilt/receipts/$f1.json") ;;
    *) bad "P9d unknown algorithm '$algo'"; return ;;
  esac

  if [ "$digest" = "$expect" ]; then
    ok "P9e field 2 == independently recomputed hash of the receipt"
  else bad "P9e field 2 '$digest' != recomputed '$expect'"; fi

  # A hash that does not detect a change is decoration. Change the receipt and
  # the hash must stop matching.
  local before after
  before=$f2
  printf 'x' >> "$d/.quilt/receipts/$f1.json"
  after=$("$d/.quilt/bin/quilt-hash" "$d/.quilt/receipts/$f1.json")
  if [ "$before" != "$after" ]; then
    ok "P9f the hash changes when the receipt changes (it is a content hash)"
  else bad "P9f hash did NOT change after mutating the receipt"; fi

  # And it must agree with itself across runs — no wall clock, no salt.
  if [ "$("$d/.quilt/bin/quilt-hash" "$d/.quilt/receipts/$f1.json")" = "$after" ]; then
    ok "P9g the hash is stable across runs (deterministic)"
  else bad "P9g hash is not deterministic"; fi
}

# ---------------------------------------------------------------- P11
pin_p11() {
  if selftest_verdict; then ok "P11a verdict_of attributes each check to its own pin"
  else bad "P11a verdict_of misattributes a check id"; fi
}

# ---------------------------------------------------------------- main
# PIN_LIST drives the run order and the verdict table together, so adding a pin
# is one line here and nothing else below has to change. pin_name keeps the
# human-readable half of the old table.
PIN_LIST="P1 P2 P3 P4 P5 P6 P7 P8 P9 P11 P10"

pin_name() {
  case "$1" in
    P1)  echo "receipt+watch on dial commit" ;;
    P2)  echo "freeze enforcement" ;;
    P3)  echo "cascade" ;;
    P4)  echo "rewind" ;;
    P5)  echo "clone needs quilt-init" ;;
    P6)  echo "non-cell commit silent" ;;
    P7)  echo "merge is journalled" ;;
    P8)  echo "contradiction refuses merge" ;;
    P9)  echo "watch field 2 is a content hash" ;;
    P10) echo "no hook/generator drift" ;;
    P11) echo "verdict table attributes correctly" ;;
    *)   echo "?" ;;
  esac
}

main() {
  say "# quilt-in-git pins  src=$SRC"
  say "# scratch=$SCRATCH  git=$(git --version | cut -d' ' -f3)"
  say ""
  local p
  for p in $PIN_LIST; do
    # A pin that is listed but not implemented must be a HARD FAIL. Without
    # this, `"pin_p8"` on a shell with no such function prints "command not
    # found", records nothing in FAILS, and the verdict below defaults to
    # PASS — the harness would report green for a pin it never ran. That is
    # fail-open, and it is the one way this file could lie to you.
    if ! declare -f "pin_$(printf '%s' "$p" | tr 'A-Z' 'a-z')" >/dev/null 2>&1; then
      bad "$p pin listed in PIN_LIST but pin_$(printf '%s' "$p" | tr 'A-Z' 'a-z') is not defined"
      continue
    fi
    "pin_$(printf '%s' "$p" | tr 'A-Z' 'a-z')"
  done
  say ""
  say "# ---- per-pin verdicts ----"
  local v n=0 total=0 pname
  for p in $PIN_LIST; do
    v=$(verdict_of "$p")
    total=$((total + 1))
    if [ "$v" = PASS ]; then n=$((n + 1)); fi
    pname=$(pin_name "$p")
    say "$(printf '%s %-32s: %s' "$p" "$pname" "$v")"
  done
  say ""
  say "PINS: $n/$total pins pass ($PASS checks pass, $FAIL checks fail)"
  if [ "$n" -eq "$total" ]; then
    say "PINS: ALL PASS"
    rm -rf "$SCRATCH"
    exit 0
  fi
  say "PINS: FAILURES PRESENT (scratch kept for inspection: $SCRATCH)"
  exit 1
}

main "$@"
