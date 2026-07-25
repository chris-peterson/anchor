# Staying in changeset scope

Once a change enters review — an open CR, a branch you're iterating on, a diff
you're walking through in `/anchor:commit`'s review or resolving with
`/anchor:resolve-feedback` — the goal is **minimal churn**: change as few lines
as you can. Be surgical. Keep edits within the changeset's existing scope and
resist pulling in pre-existing code unrelated to the change's purpose, even when
a piece of feedback sits right next to it. Perfect scope isn't always reachable,
but fewer touched lines is always the target. anchor's review skills consult
this guide whenever feedback would touch code the diff doesn't already own.

## Feedback invites overreach two ways

- **Fix-now comments with reasons** — moor's sidecar, fed back through
  `/anchor:resolve-feedback`. Fix the lines the comment targets, not the adjacent
  pre-existing code they happen to sit next to.
- **A direct ask while iterating** — "while you're in there, also change X." If
  X is pre-existing code the diff doesn't otherwise touch, that's a scope
  expansion, not a fix.

## Surface the expansion; let the author choose

If a request would require touching code **outside** the current scope — a
pre-existing method the diff doesn't otherwise touch, an unrelated file —
surface the scope expansion and confirm before acting: fold it into this
changeset, or make it a separate change? The author can always say "fold it
in," but they get the choice rather than discovering the extra edit in the
diff.

## Why minimal churn matters under review

Silently pulling pre-existing code into a changeset under review inflates it
and mixes concerns. The reviewer relying on the "changes since you last looked"
diff now has to untangle "why is this unrelated method in a change about X?" —
and a surprising, unbundled edit is the kind of thing that gets a whole CR sent
back.
