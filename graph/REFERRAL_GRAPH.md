# REFERRAL_GRAPH — booking units for observed referral edges

A booking unit is the machine-readable record of ONE referral edge between
two fleet repos: cited at both ends, explicit about its boundaries, and
booked — not assumed. It exists so referral edges stop living only in
prose (PR bodies, pulse notes) and start living somewhere pins can guard.

`REFERRAL_GRAPH.json` is the graph. `pins-graph.sh` is its gate.
`pins/failfirst.log` and `pins/final.log` are the receipts that the gate
ran RED against absent/empty graphs before it ever went GREEN.

## What a booking unit IS

- **id** — stable slug (`e1-…`, `e2-…`).
- **source** — repo owning the capability, cited `{repo, ref, as_of_commit}`.
  The commit is mandatory: a referral to "main" rots; a referral to a
  commit is checkable forever.
- **target** — repo adopting the capability, cited `{repo, ref}`.
- **verbs** — mapped pairs `source_verb → target_semantic`: which verb is
  borrowed and what it means in the target's vocabulary.
- **boundaries** — honest limits, verbatim short canonical forms from the
  documenting PR: `committed-tree-only reads` (the query layer reads the
  committed tree only at the queried ref), `receipted ≠ true` ("trusted"
  means receipted-in-tree and reachable, never *true*), `substring coverage
  advisory` (coverage cross-referencing is substring-based), and
  `referral-not-dependency` (a referral, not a dependency claim).
- **booked_by / date / receipt** — who booked it, when, and the PR that
  argued the edge exists.

## The first booked edge (e1)

quilt-in-git @ `43f10b2` (PR #9, wave4-query — MERGED) → quilt-adjudication
@ main. Documented and argued in PR #1 (open as of 2026-10-02). The four
quilt-query subcommands, verified against the usage string in
`.quilt/bin/quilt-query` at `43f10b2`: `divergence`,
`trusted-but-unaudited`, `coverage`, `attest`.

## How to add the next edge

1. Get the documenting PR merged or at least cited; a booking without a
   receipt string is gossip.
2. `gh pr view <N> --repo <source-repo> --json mergeCommit` and cite the
   merge commit — never invent or half-remember a SHA.
3. Append the edge to `edges[]` using exactly the fields above;
   schema_version stays 1 until the shape itself changes.
4. Extend `pins-graph.sh` if the new edge adds boundaries or verbs; G1–G3
   gate all edges. Run RED first (temporarily empty `edges[]` suffices),
   then GREEN; keep both logs under `graph/pins/`.

## Honest limit

A booking records that a referral was **observed and argued** — never that
it was **exercised**. As of 2026-10-02 no cross-repo query has run: nothing
in quilt-adjudication has invoked `quilt-query`, and nothing in
quilt-in-git knows quilt-adjudication exists. When the first real query
happens, book THAT as a separate receipt — an exercised-edge unit is a
different artifact from a referral-edge unit; do not upgrade this one in
place.
