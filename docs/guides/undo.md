# Undo

`LoroEx.UndoManager` is how you implement `Ctrl+Z` / `Ctrl+Shift+Z`
in a collaborative editor. It's a deliberately scoped primitive:
**local-only per-peer undo**. It rewinds operations made by *this
doc's current peer*, never remote edits from other users.

That's the right semantics for an editor. When Alice hits `Ctrl+Z`,
she wants her last action undone — not Bob's. A CRDT that tried to
globally rewind would surprise users by undoing someone else's
ongoing work.

For *global* rollback (e.g. "restore this page as of yesterday"),
use time-travel APIs (`checkout`, `revert_to`) — on the roadmap but
not yet exposed.

## Basic usage

```elixir
iex> doc = LoroEx.new(1)
iex> undo = LoroEx.UndoManager.new(doc)

iex> :ok = LoroEx.insert_text(doc, "body", 0, "hello")
iex> :ok = LoroEx.UndoManager.record_new_checkpoint(undo)

iex> :ok = LoroEx.insert_text(doc, "body", 5, " world")
iex> :ok = LoroEx.UndoManager.record_new_checkpoint(undo)

iex> LoroEx.get_text(doc, "body")
"hello world"

iex> true = LoroEx.UndoManager.undo(undo)
iex> LoroEx.get_text(doc, "body")
"hello"

iex> true = LoroEx.UndoManager.undo(undo)
iex> LoroEx.get_text(doc, "body")
""

iex> true = LoroEx.UndoManager.redo(undo)
iex> LoroEx.get_text(doc, "body")
"hello"
```

## The peer identity rule

**Use a deterministic peer id.** The `UndoManager` is bound to the
doc's peer id at construction; if the doc's peer id ever changes, the
manager loses track of what's undoable.

For server-side docs this means **always** using `LoroEx.new/1` with
a stable peer id:

```elixir
peer_id = :erlang.phash2({node(), doc_id})
doc = LoroEx.new(peer_id)
undo = LoroEx.UndoManager.new(doc)
```

For browser-side docs where each session is effectively a new peer,
generate a peer id once per session and persist it in local storage.

## Checkpoints: controlling undo granularity

By default, every local commit is its own undo step. That's too
granular for typing — `Ctrl+Z` undoing one character at a time is
awful UX. You want a whole word (or sentence) per undo step.

Two options:

### Option 1: Explicit `record_new_checkpoint/1`

Call it on a debounced timer when the user pauses:

```elixir
defmodule MyApp.Editor do
  def on_input(doc, undo, text) do
    :ok = LoroEx.insert_text(doc, "body", cursor_pos(), text)
    # Restart the idle timer — when it fires, commit a checkpoint
    restart_idle_timer()
  end

  def on_idle(undo) do
    # 500ms since last keystroke — commit a checkpoint
    :ok = LoroEx.UndoManager.record_new_checkpoint(undo)
  end
end
```

This gives you undo-per-burst-of-typing.

### Option 2: Merge interval

Let the manager auto-merge successive edits within a time window:

```elixir
# Merge edits within 1 second into a single undo step
:ok = LoroEx.UndoManager.set_merge_interval(undo, 1000)
```

With merge interval, you don't need to call `record_new_checkpoint/1`
manually — the manager starts a new step whenever a gap > 1s passes.
Simpler for the common case; the explicit approach is better if your
notion of "undo group" isn't purely time-based.

### Option 3: Both (recommended)

Set a generous merge interval as a safety net, and use explicit
checkpoints at natural boundaries — end of a paragraph, before a
structural change, etc.

```elixir
:ok = LoroEx.UndoManager.set_merge_interval(undo, 1000)

# Later, for a discrete action (paste, format change, block insert):
:ok = LoroEx.UndoManager.record_new_checkpoint(undo)
:ok = LoroEx.text_mark(doc, "body", 0, 5, "bold", true)
:ok = LoroEx.UndoManager.record_new_checkpoint(undo)
```

## Wiring to button state

Your "Undo" and "Redo" buttons should be enabled only when there's
something to do. LiveView-style:

```elixir
def render(assigns) do
  ~H"""
  <button disabled={not @can_undo} phx-click="undo">Undo</button>
  <button disabled={not @can_redo} phx-click="redo">Redo</button>
  """
end

def handle_event("undo", _, socket) do
  _ = LoroEx.UndoManager.undo(socket.assigns.undo)
  {:noreply, update_button_state(socket)}
end

def handle_event("redo", _, socket) do
  _ = LoroEx.UndoManager.redo(socket.assigns.undo)
  {:noreply, update_button_state(socket)}
end

defp update_button_state(socket) do
  assign(socket,
    can_undo: LoroEx.UndoManager.can_undo(socket.assigns.undo),
    can_redo: LoroEx.UndoManager.can_redo(socket.assigns.undo)
  )
end
```

## What counts as "local"?

Only ops produced by **this doc handle** via direct mutation are
undoable. Ops imported via `apply_update/2` — even if they came from
another instance of the same peer — are **remote** from the
manager's perspective and never undone.

Practical consequence: each client process should own its own
`UndoManager`. Don't share one across a server that applies peer
updates; the server's undo stack will be empty because it never
performs local edits.

## Undo and concurrent edits

The manager transforms undoable ops against concurrent remote
changes. Concretely:

1. Alice types "hello" at position 0.
2. Bob (concurrently) inserts "ABC" at position 0.
3. After sync, the text is "ABChello".
4. Alice hits `Ctrl+Z`.

What Alice expects: her "hello" is gone, leaving "ABC". That's what
Loro does. The undo op is transformed so it deletes the right
characters — not just "positions 0..5" (which would delete "ABC
he"), but "the characters I originally inserted."

This transformation is automatic; you don't handle it yourself.

## Restoring selection on undo

An editor UX nicety: when you `Ctrl+Z`, the cursor should jump back
to where it was before the undone action. Use stable cursors for
this:

```elixir
defmodule MyApp.UndoWithSelection do
  def snapshot_selection(doc, pres, peer_id, sel_start, sel_end) do
    start_cursor = LoroEx.text_get_cursor(doc, "body", sel_start, :left)
    end_cursor = LoroEx.text_get_cursor(doc, "body", sel_end, :right)
    :ok = LoroEx.Presence.set(pres, "\#{peer_id}/sel_snapshot", %{
      "start" => Base.encode64(start_cursor),
      "end"   => Base.encode64(end_cursor)
    })
  end

  def undo(doc, undo, pres, peer_id) do
    _ = LoroEx.UndoManager.undo(undo)

    case LoroEx.Presence.get(pres, "\#{peer_id}/sel_snapshot") do
      %{"start" => b64s, "end" => b64e} ->
        {s, _} = LoroEx.cursor_resolve(doc, Base.decode64!(b64s))
        {e, _} = LoroEx.cursor_resolve(doc, Base.decode64!(b64e))
        {:ok, {s, e}}

      _ ->
        {:ok, :no_selection}
    end
  end
end
```

## Capacity and cost

Each undo step retains enough info to replay. Default max is 100
steps:

```elixir
# Make the stack larger for heavy-use editors
:ok = LoroEx.UndoManager.set_max_undo_steps(undo, 500)

# Or smaller for memory-constrained environments
:ok = LoroEx.UndoManager.set_max_undo_steps(undo, 30)
```

Memory cost: roughly O(N * avg_diff_size). For text editors this is
small; for docs with large ops (bulk imports), cap aggressively.

## When the manager disappears

Dropping the last reference to the undo manager cancels its
subscription to the doc. No way to "resume" the undo stack after
that — it's gone. Treat it as tied to the lifetime of the editor
session.

## What about redo after a new edit?

Standard editor behavior: making a new edit after an undo clears the
redo stack. LoroEx follows this:

```elixir
:ok = LoroEx.insert_text(doc, "body", 0, "A")
:ok = LoroEx.UndoManager.record_new_checkpoint(undo)
:ok = LoroEx.insert_text(doc, "body", 1, "B")
:ok = LoroEx.UndoManager.record_new_checkpoint(undo)

true = LoroEx.UndoManager.undo(undo)  # now "A"
true = LoroEx.UndoManager.can_redo(undo)

# New edit — redo is cleared
:ok = LoroEx.insert_text(doc, "body", 1, "C")
:ok = LoroEx.UndoManager.record_new_checkpoint(undo)
false = LoroEx.UndoManager.can_redo(undo)
```

## Current limitations

- `set_on_push` and `set_on_pop` listeners (for custom metadata on
  undo items) aren't yet exposed.
- `undo_count` / `redo_count` aren't yet exposed; use `can_undo` /
  `can_redo` only.
- `group_start` / `group_end` (for manually bundling several ops into
  one undo step) aren't yet exposed. For the grouping use case, use
  `record_new_checkpoint/1` boundaries instead.

These are on the roadmap; the basic pattern (checkpoint, undo, redo,
can_undo, can_redo, set_merge_interval, set_max_undo_steps) covers
the 90% case.
