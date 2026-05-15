# Time travel

Loro keeps every op forever (until you trim with a shallow snapshot), which
means any past state is reachable. LoroEx exposes this via the
`checkout` / `attach` / `detach` family.

This guide covers the three workflows that come up most: **rewind to read**,
**rewind to fork**, and **branch detach**. It also explains the concurrency
contract you need to respect to use these safely from multiple processes.

## TL;DR

```elixir
# Rewind, read, restore.
checkpoint = LoroEx.oplog_frontiers(doc)
# … later, after more edits …
:ok = LoroEx.checkout(doc, checkpoint)   # visible state = checkpoint
old  = LoroEx.get_text(doc, "body")
:ok = LoroEx.attach(doc)                  # back to live state
```

There are six functions. They work in pairs:

| Pair | Purpose |
|---|---|
| `checkout/2` ⇄ `attach/1` (or `checkout_to_latest/1`) | Rewind to a frontier, then return |
| `detach/1` ⇄ `attach/1` | Pause new commits without rewinding |
| `set_detached_editing/2` | Allow new commits while detached (forks history) |
| `detached?/1` | Predicate; useful for rendering "you are viewing history" UI |

## checkout vs revert_to

This trips people up. They do superficially similar things but with very
different sync behavior:

|  | `checkout/2` | `revert_to/2` |
|---|---|---|
| Produces new ops? | No | Yes (inverse ops) |
| Other peers see anything? | No | Yes (the inverse ops sync) |
| Subscriptions fire? | Yes (state changed) | Yes |
| `UndoManager` tracks? | No | Yes |
| Reversible by another `checkout`? | Yes | Yes — but the inverse ops are still in history |

**Use `checkout` when**: you want to *read* the doc as of a past point, e.g.
"show me what this page looked like an hour ago".

**Use `revert_to` when**: you want to *change* the doc back to a past state
and have that change propagate to peers, e.g. an "undo last 10 minutes" button
in a collaborative editor.

## Workflow 1 — Rewind to read

The simplest case. Capture a frontier, do more edits, rewind to read the past
state, restore.

```elixir
doc = LoroEx.new()
:ok = LoroEx.insert_text(doc, "body", 0, "draft 1")
v1  = LoroEx.oplog_frontiers(doc)

:ok = LoroEx.delete_text(doc, "body", 0, 7)
:ok = LoroEx.insert_text(doc, "body", 0, "draft 2")
LoroEx.get_text(doc, "body")
# => "draft 2"

:ok = LoroEx.checkout(doc, v1)
LoroEx.get_text(doc, "body")
# => "draft 1"

:ok = LoroEx.attach(doc)
LoroEx.get_text(doc, "body")
# => "draft 2"
```

For an off-GenServer read pattern, **fork before checkout** so you don't
mutate the canonical doc:

```elixir
forked = LoroEx.fork(state.doc)
:ok    = LoroEx.checkout(forked, v1)
LoroEx.get_text(forked, "body")
# canonical state.doc untouched
```

Even better, `LoroEx.fork_at/2` does both steps in one call:

```elixir
forked = LoroEx.fork_at(state.doc, v1)
LoroEx.get_text(forked, "body")
```

## Workflow 2 — Branch from a past point

Use `set_detached_editing(true)` to write new ops while detached.
The new ops fork off the old frontier and replace whatever happened
after that point.

```elixir
doc = LoroEx.new()
:ok = LoroEx.insert_text(doc, "body", 0, "shared start")
fork_point = LoroEx.oplog_frontiers(doc)

:ok = LoroEx.insert_text(doc, "body", 12, " - main timeline")

:ok = LoroEx.checkout(doc, fork_point)
:ok = LoroEx.set_detached_editing(doc, true)
:ok = LoroEx.insert_text(doc, "body", 12, " - alt timeline")

LoroEx.get_text(doc, "body")
# => "shared start - alt timeline"
```

The "main timeline" branch is still in history; you can `attach/1` to
return to it.

## Workflow 3 — Pause writes without rewinding

`detach/1` doesn't change state — it just refuses new commits until
`attach/1`. Use this as a soft mutex when you want to freeze a doc
during a sensitive operation (e.g. exporting a snapshot you don't want
new ops landing on).

```elixir
:ok = LoroEx.detach(doc)
snap = LoroEx.export_snapshot(doc)
# Other processes that try to mutate the doc here will silently no-op
# unless they explicitly enable detached editing.
:ok = LoroEx.attach(doc)
```

For most use cases, prefer `LoroEx.fork/1` instead — it's cheaper than
detach + attach and doesn't block other processes.

## Concurrency contract

`checkout/2` mutates **visible** state under our internal `Mutex<LoroDoc>`.
The mutex serializes the call itself, but **subsequent reads through the
same handle will see the rewound state**. That's the entire point — but it
means:

- If you have one process owning the doc (the recommended pattern), you're
  fine. Reads coming in through `GenServer.call` are serialized and naturally
  see the post-checkout state.
- If multiple processes share a doc handle and read concurrently with
  someone else's `checkout/2`, you need an explicit lock or you'll see
  inconsistent reads.
- Subscriptions (`subscribe/2`, `subscribe_root/2`) fire on `checkout/2`
  the same way they fire on real edits — useful for triggering a re-render.

The "fork before checkout" pattern from Workflow 1 sidesteps the whole
concurrency issue: a fork is an independent doc handle, so checking out
the fork has zero effect on the canonical doc.

## When detached writes silently no-op

By default, calling `insert_text/4` (or any other mutator) while detached
**does nothing** — Loro accepts the call but discards the result. This
is intentional: it lets read-only views of past state be safe even if
they accidentally try to write.

If you want writes to actually apply, call `set_detached_editing(doc, true)`
explicitly. There's no deferred queue — once you re-attach, those writes
are gone unless `set_detached_editing` was on.

## Patterns to avoid

- **Don't share a handle between unrelated processes and call `checkout/2`
  on it.** Always fork first.
- **Don't rely on `detach/1` to block other writers.** It's a per-handle
  flag, not a doc-level lock.
- **Don't use `checkout/2` as undo.** Use `LoroEx.UndoManager` for that, or
  `LoroEx.revert_to/2` if you need to broadcast the rewind to peers.

## Related reading

- [`LoroEx.fork/1`, `fork_at/2`](`LoroEx.fork/1`) — independent clones for
  off-GenServer reads.
- [`LoroEx.revert_to/2`](`LoroEx.revert_to/2`) — rewind that produces inverse
  ops and syncs to peers.
- [`docs/design.md`](design.md) — internal mutex strategy, scheduler choice.
