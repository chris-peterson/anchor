# Events

anchor announces two facts about a change request on its own stdout, so another
plugin can react to them without anchor knowing that plugin exists. Nothing in
anchor reads them back, and a session where nothing is listening pays nothing
for them.

An announcement is one line: a key, then a compact JSON object.

```text
codes.bridgeai.anchor/cr.created {"uri":"https://github.com/o/r/pull/3533","title":"Announce the CR anchor opens"}
```

Two events, and **a run announces one of them or the other, never both** —
setting up a change request anchor just opened is part of creating it, not an
update to it:

- [`cr.created`](#cr-created)
- [`cr.updated`](#cr-updated)

## `cr.created` :id=cr-created

```text
codes.bridgeai.anchor/cr.created
```

`/anchor:prepare-review` opened a change request. The script that creates it
emits this, so it fires whether or not the skill runs to completion.

| Field | Value | Meaning |
|---|---|---|
| `uri` | always set | the change request's web address |
| `title` | always set | its title, as anchor set it on creation |

`title` is never empty here: opening a CR requires one, so the script refuses to
run without it.

## `cr.updated` :id=cr-updated

```text
codes.bridgeai.anchor/cr.updated
```

`/anchor:prepare-review` changed a change request that already existed. A re-run
on the same CR fires it again.

| Field | Value | Meaning |
|---|---|---|
| `uri` | always set | the change request's web address |
| `title` | may be empty | its title, as the forge reports it |

**One announcement covers the whole phase, not each mutation.** A run that writes
the description, applies labels, attaches a milestone, and records an ordering
dependency has changed one thing as far as a subscriber is concerned, so it
announces once. Nothing downstream has to debounce four events.

`title` is read back from the forge on this path rather than set by anchor, so a
CR the forge reports without one arrives with the field present and empty.

## Neither event carries the number

It is in the `uri`, and both forges put it last: `…/pull/3533`,
`…/-/merge_requests/17`. A subscriber that wants `#3533` derives it rather than
trusting a second field to agree with the first.

## Reacting to one

An announcement reaches a `PostToolUse` hook on `Bash` as
`tool_response.stdout`. Match the key anchored, then parse what follows it:

```bash
input=$(cat)
output=$(printf '%s' "$input" | jq -r '.tool_response.stdout // empty' 2>/dev/null) || exit 0
line=$(printf '%s' "$output" | grep -m1 '^codes\.bridgeai\.anchor/cr\.created[[:space:]]') || exit 0
uri=$(printf '%s' "${line#* }" | jq -r '.uri // empty' 2>/dev/null) || exit 0
```

Register that in your own plugin's `hooks.yml`. anchor gains no entry, no
config, and no knowledge that you subscribed, which is what lets either side
ship without the other.

Two obligations come with subscribing, and both matter more than they look:

- **Exit 0 on every path**, a body that won't parse included. The hook runs on
  every Bash call in every session where your plugin is enabled.
- **Strip control characters from a value before you render it.** The line is
  guaranteed to be one line; a value decoded out of it is not guaranteed to be
  safe. `title` reaches you from a forge, so treat it as text a stranger wrote.

## The rules

The grammar, the reserved field names, what a subscriber owes, and why a parsed
value still needs sanitizing are the suite's, not anchor's:
[the plugin interop contract](https://github.com/chris-peterson/claude-marketplace/blob/main/authoring/plugin-contract.md).

anchor declares both events in its own `plugin.yml`, under `events.publishes`,
which is the source this page is checked against.
