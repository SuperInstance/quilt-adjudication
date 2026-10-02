# quilt-in-git — with merge adjudication

**The entire simplified Quilt lives inside a plain Git repository: dials are
files, ticks are commits, rewind is checkout, and Git hooks are the runtime.**
Every cell is a directory under `cells/`; its state is 16 dial files (one
float each) plus a body. Changing a dial and committing it is a *tick*; a
`post-commit` hook turns that tick into a receipt, an entanglement cascade,
and a watch-log line. Because everything is ordinary Git content, the repo is
simultaneously the Sheet, the journal, and the collaboration bus — clone,
push, bundle, branch, and time travel all come free.

This fork takes that substrate unchanged in spirit and adds the one thing it
could not express: **what happens when two people merge two true statements
about the same fact.** It is three commits on top of `6a1ae48`, and the
original six pins still pass.

---

## Run it

You need **git and a POSIX shell**. That is the entire dependency list — no
Node, no Python, no network, no account, no API key, no install step. `awk`,
`sed`, and one of `sha256sum`/`shasum` are used where present, with git itself
as the final fallback.

```bash
git clone <this repo> && cd quilt-in-git
bash tests/pins_quiltgit.sh     # 11 pins, 59 checks. exit 0.
./demo.sh                        # the two-PR refusal, both panes. exit 0.
```

To use it on your own repo, copy the runtime in and activate it once per clone:

```bash
cp -R /path/to/this/.quilt /your/repo/.quilt
cd /your/repo && ./.quilt/bin/quilt-init
```

`quilt-init` prints what it did. It is idempotent.

## What this fork adds

### 1. Merges are journalled — `104f9e0`

The substrate had no `post-merge` hook, and its `post-commit` probe could not
have caught a merge anyway: `git diff-tree` prints nothing for a merge commit
unless you pass `-m`. So the hook exited 0 having seen nothing, and a merge
wrote no receipt, no cascade, and no watch line.

```
$ git diff-tree --root --no-commit-id --name-only -r HEAD -- cells/
[]                                  # a 2-parent merge
$ git show --stat HEAD
 cells/auth/dials/1 | 2 +-         # the change existed
$ git diff-tree -m --root --no-commit-id --name-only -r HEAD -- cells/
cells/auth/dials/1                 # what the fix sees
```

`.quilt/hooks/post-merge` is `post-commit` with one difference, and the
difference is the whole commit. Receipts gained `parents` and `merge` fields
so a merge receipt is distinguishable from a tick receipt. Pinned by P7; the
red against the untouched substrate is in `pins/failfirst-merge.log`.

### 2. The refusal — `dc547b8`

A **claim** is a line in a cell body:

```
claim: <key> = <value>  by <attribution>
```

Two claims **conflict** when they name the same key, carry different values,
and come from different attributions. One author restating a number is a
retraction, not a contradiction (P8k). An unattributed line is not
adjudicable at all (P8l).

When a merge would produce a conflict, the merge is **refused**:

```
$ git merge --no-ff pr33
quilt: REFUSING the merge — the result asserts one key twice with two values.

  key: inbound_edges
    19                           by quilt-tools#32 fb2e041
    21                           by quilt-tools#33 0101409

  Both texts are preserved verbatim in: .quilt/adjudications/177f885.json
  Winner rule: the claim that arrived on the side being merged.
  That is an ordering, not a judgment about which is true.
  No judge ran. If the losing number is the right one:
    git checkout HEAD -- cells/inbox/body && git merge --abort && git merge <branch>
$ echo $?
1
```

No merge commit is created. HEAD does not move, the branch never gains a
second parent, and the contradiction stays a file on disk instead of becoming
history. The record names the winner, keeps **both** losing claims verbatim,
states the reason, and carries the command that takes the other number.

**There is no judge here.** No model is in the loop, by design, and every
record says so in two fields you can read:

```json
"adjudication": "mechanical",
"judge": "none — no model is in this loop, by design"
```

The winner is whichever claim arrived on the side being merged. That is an
*ordering*, not a judgment about truth. It exists so the merge has one
surviving line and a one-command way to change its mind — not because
anything here knows which number is right. The strength of this entry is that
it can say when the judge is not worth running, not that it owns a judge.

The refusal is enforced from **two doors**, because one is not enough. git
runs `pre-merge-commit` on the clean `git merge` path but does **not** run it
when a conflict is resolved by hand and concluded with `git commit` — which is
the common path, and the path the fixture takes. Measured on git 2.39.5: with
only `pre-merge-commit` installed, that merge commit was created and the hook
never ran. `pre-commit` does run there, so it carries the same check whenever
`MERGE_HEAD` is present. P8m pins the `git commit` path specifically.

`post-merge` re-runs the check for a `--no-verify` merge and says plainly
that it is **too late to refuse** — it does not pretend an exit code can take
back a commit git has already written.

### 3. The receipt is hashed — `01197a0`

The README has documented `tick <short> <receipt-hash> <cells>` since the
first commit, and field 2 has never been a hash. It has been a second copy of
field 1 — the substrate's own committed pin log shows it: `tick 7ed5c9f
7ed5c9f a`. There was no hash computation anywhere in the repository.

Field 2 is now the content hash of the receipt that tick wrote, computed by
`.quilt/bin/quilt-hash` and **prefixed with its algorithm** (`sha256:…`,
`sha1:…`). The prefix is not decoration: the preferred implementation is
sha256, but a machine with no `sha256sum` and no `shasum` falls back to
`git hash-object`, which is sha1 and always available, because this runtime is
git hooks. A bare 40-hex and a bare 64-hex in one column would be
indistinguishable without counting characters.

```
tick a6e0266 sha256:a22bb4dac80d7d99e34be7ab81e40a3e47034b9631e53051ec9bef15aff024a8 a
```

P9 recomputes the digest with coreutils rather than with `quilt-hash`, so it
is a check and not a tautology; then it mutates the receipt and requires the
hash to change, because a hash that survives a changed input is decoration.

### A fourth defect, found by doing the work

The generated journal — `watch.log`, `receipts/` — was **tracked**, and hooks
rewrite it on every commit. The moment a second branch exists, every merge
text-conflicts on the journal before it ever reaches the cells:

```
Auto-merging .quilt/watch.log
CONFLICT (content): Merge conflict in .quilt/watch.log
```

The substrate is single-writer by construction, and a journal that conflicts
on contact cannot survive contact with a second writer. `quilt-init` now
writes `.quilt/.gitignore` and the journal is untracked. It is still a
journal, still on disk, still growing; it is derived state that history can
regenerate, so it does not belong in the index a merge has to reconcile.

**This is the one change here that alters a substrate property**, and it is
what made merging possible at all.

---

## Layout

```
cells/<alias>/dials/0..15   16 dials, one float per file
cells/<alias>/body          the cell's content; may carry `claim:` lines
cells/<alias>/links         optional; lines of "<src_alias> <weight>"
.quilt/bin/quilt-init       bootstrap (run once per clone)
.quilt/bin/quilt-tick       convenience: set one dial + commit
.quilt/bin/quilt-cascade    recompute dial 14 from links
.quilt/bin/quilt-receipt    write .quilt/receipts/<short>.json
.quilt/bin/quilt-adjudicate refuse contradictory merges; write the record
.quilt/bin/quilt-hash       content hash of a file, algorithm-prefixed
.quilt/hooks/               pre-commit, post-commit, post-merge,
                            pre-merge-commit (all generated by quilt-init)
.quilt/receipts/            one JSON receipt per tick or merge commit
.quilt/adjudications/       one JSON record per refused merge
.quilt/watch.log            one "tick <short> <receipt-hash> <cells>" line
```

`quilt-init` generates the hooks, and **P10 pins that the generated hooks are
byte-identical to the checked-in ones** — the substrate's own claim that they
"cannot rot apart" was true but untested, and it is now tested.

## Dial map

| dial | name          | meaning                                                        |
|------|---------------|----------------------------------------------------------------|
| 0–13 | generic       | free per-cell knobs (budget, health, …)                        |
| 1    | OBSTRUCTION   | friction of the cell; feeds linked cells' entanglement          |
| 14   | ENTANGLEMENT  | derived: `max(src dial 1 × weight)` over the cell's links       |
| 15   | FREEZE        | `> 0.5` = frozen; pre-commit rejects changes to that cell       |

## The minimal loop

```bash
git init q && cd q
# bring in the runtime (or clone this repo) and activate it
/path/to/quilt-in-git/.quilt/bin/quilt-init     # sets core.hooksPath

mkdir -p cells/auth/dials && echo 0.11 > cells/auth/dials/1
git add cells && git commit -m "cells: seed auth"   # already a tick

echo 0.42 > cells/auth/dials/0
git add cells/auth/dials/0
git commit -m "tick: lower auth budget"          # receipt + watch line appear

cat .quilt/receipts/*.json                       # proof of what happened
tail -f .quilt/watch.log                         # live tick stream
git log -p -- cells/auth/                        # history of nudges
git checkout <old-hash> -- cells/auth/           # rewind just that organ
```

Or with the helper: `.quilt/bin/quilt-tick auth 0 0.42`.

## Runtime semantics

- **Receipts.** `post-commit` and `post-merge` write
  `.quilt/receipts/<short>.json`:
  `{commit, parents, merge, changed_cells, key_dials{<alias>{obstruction,freeze}}, ts}`.
  `ts` is the git commit time (`git log -1 --format=%ct`), never wall clock,
  so receipts reproduce deterministically from history. The changed-cell probe
  is `diff-tree -m`; on a single-parent commit `-m` is a no-op, so ticks are
  unaffected.
- **Cascade.** For every `cells/<alias>/links`, dial 14 becomes
  `max(src.dial1 × weight)` over its lines, rounded to 4 decimals (awk).
  Missing sources count as 0. One pass, sorted glob order, no transitive
  propagation — deterministic. If cascade changed any dial file, the hook
  auto-commits `quilt: cascade after <short>` with `--no-verify`.
- **Freeze.** `pre-commit` reads the *committed* dial 15 of each staged
  cell; `> 0.5` rejects the commit with `ERROR: cell <alias> is frozen`.
  Staged paths that are only `dials/15` are exempt, so freeze/unfreeze is
  always possible (as its own commit). Cascade auto-commits bypass the
  check (`--no-verify`), like the design doc's auto-freeze pattern.
- **Adjudication.** `pre-merge-commit` (and `pre-commit` when `MERGE_HEAD` is
  set) runs `quilt-adjudicate` over the would-be merged tree. On conflict it
  writes `.quilt/adjudications/<short>.json` and exits 1. Before the commit
  exists the record is named for the **tree** the merge would have produced;
  afterwards it is named for the commit, like a receipt. It reads bodies and
  never dials, and writes nothing under `cells/` (P8j).
- **Watch.** One line per tick or merge:
  `tick <short> <receipt-hash> <cells>`, where the hash is the content hash
  of the receipt that commit wrote. Commits touching no `cells/` path produce
  nothing — the journal stays quiet.

## Honest limits

1. **`core.hooksPath` is local config.** Hooks travel with the repo but are
   inert in a fresh clone; every clone must re-run `.quilt/bin/quilt-init`.
2. **Receipts use git commit time, not wall clock.** Deterministic, but a
   rebased/amended history gets new receipt times for free.
3. **Freeze is a convention enforced at pre-commit, not security.**
   `git commit --no-verify` (and the cascade path) bypasses it. The same is
   true of the refusal: `git merge --no-verify` skips `pre-merge-commit`
   entirely. `post-merge` catches that case and records it, but by then the
   commit exists and the record is a receipt, not a veto.
4. **The cascade commit sweeps any dirty `cells/` files** that were left
   uncommitted when a tick lands.
5. **The journal is untracked now** (`.quilt/.gitignore`), because a tracked
   hook-written journal conflicts on every branch merge. You lose "the journal
   is in git" for multi-writer use; single-writer use is unaffected, and
   nothing is lost from disk.
6. **The winner rule is an ordering, not a truth.** It resolves the merge
   mechanically and records both sides. It does not know which claim is
   correct, and the record does not pretend otherwise.
7. **Adjudication reads one line shape.** Only `claim: <key> = <value>  by
   <attribution>` in `cells/<alias>/body` is adjudicable. A contradiction
   expressed any other way is invisible to it, exactly as it was invisible
   before.
8. **No CI.** There is no `.github/` in this repo either. The pins are run by
   a human and their output committed to `pins/`, which is the substrate's
   arrangement and this fork did not change it.

## Pins

`tests/pins_quiltgit.sh` — plain bash + git, no network, scratch repos under
`/tmp`. **11 pins, 59 checks.** The original six are unchanged.

| pin | what it pins |
|-----|--------------|
| P1–P6 | the substrate's own: receipt+watch, freeze, cascade, rewind, clone-needs-init, non-cell silence |
| P7 | a merge produces a receipt, `merge: true`, `parents: 2` |
| P8 | a contradictory merge is refused; both claims kept verbatim; winner/losers/reason present; no dial touched; one author and unattributed lines are *not* contradictions |
| P8m | the same refusal on the `git commit`-concludes-a-merge path |
| P9 | field 2 is a recomputable, algorithm-prefixed content hash that changes when the receipt changes |
| P10 | the hooks `quilt-init` writes are byte-identical to the checked-in hooks |
| P11 | the verdict table attributes each check to its own pin |

`pins/failfirst-merge.log`, `pins/failfirst-refusal.log` and
`pins/failfirst-hash.log` are the same harness run against the untouched
substrate `6a1ae48`. They are red, and they are committed, for the same
reason the substrate committed its own `pins/failfirst.log`.
