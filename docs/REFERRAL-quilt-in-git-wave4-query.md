# REFERRAL EDGE — quilt-in-git wave4-query → quilt-adjudication

**Status: CANDIDATE** (per fleet weight law — upgrades on merge, never self-upgraded)
**Filed by:** snowball pulse, 2026-10-02
**Direction:** SuperInstance/quilt-in-git @ `43f10b2` (PR #9, wave4-query — MERGED) **→** this repo (SuperInstance/quilt-adjudication, fork of quilt-in-git @ `6a1ae48`)

## The edge

This fork adds what the substrate could not express: a merge that records
its disputes. The substrate's wave-4 query layer (`.quilt/bin/quilt-query`
+ the `LEDGER.md` doubt convention, quilt-in-git #9) is the natural
**query instrument** for exactly the questions an adjudicating merge must
answer before it records what it disputes:

- `quilt-query divergence <refA> <refB>` — the two true statements about
  the same fact live here. An adjudication merge is a divergence query
  whose answer was written down instead of discarded.
- `quilt-query trusted-but-unaudited [--ref R]` — cf-native-backend design
  Q3 ("show me everything currently trusted-but-unaudited"). A dispute is
  only worth recording against a surface someone currently trusts; this
  subcommand enumerates that surface at any ref.
- `quilt-query attest <agent> [ref]` — names who held the ref an
  adjudicated claim came from.
- `LEDGER.md` coverage entries — the doubt grammar
  (`stopped / covered_by / revisit / status`) is the same shape as a
  recorded dispute: what stopped being checked, what now covers it, what
  event reopens it. "Discharge requires a reason" is this repo's thesis in
  one line: a merge committed silently is an unreasoned discharge.

**Consume, don't rival:** this repo should not grow its own
coverage/divergence reporting. It records disputes; quilt-query answers
questions about the recorded state. The fork relationship already makes
the substrate free — the referral is about which layer owns which verb.

## Concrete adoption path (smallest first)

1. After a dispute-recording merge, point `quilt-query coverage <cell>`
   at the ref and include its output (or its absence — an empty result is
   a receipt too) in the dispute record.
2. Use `quilt-query divergence` in the pre-merge probe as the
   machine-generated list of contested dials; the human/agent dispute note
   annotates that list rather than re-deriving it.
3. If this fork ever ports the wave-4 layer into its own tree, keep the
   verbs byte-identical and let the LEDGER convention travel with it.

## Honest boundaries

- The query layer reads the **committed tree only** at the queried ref;
  uncommitted dispute notes are invisible to it. Receipt first, query
  second — the order is load-bearing.
- "Trusted" in quilt-query means **receipted-in-tree and reachable**,
  never *true*. A recorded dispute does not become trustworthy because a
  receipt exists for it.
- `coverage` cross-referencing is substring-based and advisory; precise
  cell paths keep false joins rare but not impossible.
- This edge is a referral, not a dependency claim: no code here calls
  quilt-query yet, and nothing in quilt-in-git knows this repo exists.

## Why this is adoption, not collision

Both repos descend from quilt-in-git `6a1ae48`. The wave-4 layer answers
questions about recorded state; this fork records what merges usually
erase. Same substrate, disjoint verbs — the edge binds them at the
grammar level (receipt → query → dispute → ledger), which is where fleet
interoperability has been paying off all along.
