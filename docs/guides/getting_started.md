# Getting started

This guide walks you from `LoroEx.new()` to a two-peer sync in about
ten minutes. By the end you'll know:

- How to create and edit a doc
- How snapshots and deltas differ, and when to use each
- The error shape and how to handle common failure modes
- Where to go next

## Install

Add to `mix.exs`:

```elixir
def deps do
  [
    {:loro_ex,
     git: "https://github.com/bmalum/loro_ex.git",
     tag: "v0.5.0"}
  ]
end
```

You'll need a Rust toolchain (≥ 1.91 stable) on the machine that
compiles. See the README for `asdf`/`rustup` setup.

## Your first document

```elixir
iex> doc = LoroEx.new()
#Reference<...>

iex> LoroEx.insert_text(doc, "body", 0, "hello")
:ok

iex> LoroEx.get_text(doc, "body")
"hello"
```

`"body"` is a **root container name**. The first call that uses it
materializes a text container; subsequent calls address the same one.
A doc can hold any number of root containers of any kind:

```elixir
iex> LoroEx.insert_text(doc, "title", 0, "My page")
:ok
iex> LoroEx.map_set(doc, "settings", "theme", ~s("dark"))
:ok
iex> LoroEx.list_push(doc, "tags", ~s("work"))
:ok
```

## Sync between two docs

The simplest way to share state: one doc exports a snapshot, the other
imports it.

```elixir
iex> source = LoroEx.new()
iex> :ok = LoroEx.insert_text(source, "body", 0, "hello")
iex> snapshot = LoroEx.export_snapshot(source)

iex> mirror = LoroEx.new()
iex> :ok = LoroEx.apply_update(mirror, snapshot)
iex> LoroEx.get_text(mirror, "body")
"hello"
```

A snapshot is **self-contained** — it's the full state of the doc,
everything needed to reconstruct it from scratch. Snapshots are the
right choice for:

- Onboarding a new peer
- Persisting to storage (S3, Postgres)

For ongoing sync between peers that already know each other, send
**deltas** instead. A delta contains only the ops the peer doesn't
already have.

```elixir
iex> server = LoroEx.new()
iex> client = LoroEx.new()

# Client hydrates from a snapshot
iex> :ok = LoroEx.apply_update(client, LoroEx.export_snapshot(server))

# Client tells server its current version
iex> version = LoroEx.oplog_version(client)

# Server makes an edit
iex> :ok = LoroEx.insert_text(server, "body", 0, "x")

# Delta is the smallest payload that gets client up to date
iex> delta = LoroEx.export_updates(server, version)
iex> byte_size(delta) < byte_size(LoroEx.export_snapshot(server))
true

iex> :ok = LoroEx.apply_update(client, delta)
```

## Concurrent edits converge

Two peers edit the same doc independently, exchange snapshots, both
converge to the same state:

```elixir
iex> alice = LoroEx.new(1)
iex> bob = LoroEx.new(2)

iex> :ok = LoroEx.insert_text(alice, "body", 0, "hello")
iex> :ok = LoroEx.insert_text(bob, "body", 0, "world")

iex> :ok = LoroEx.apply_update(alice, LoroEx.export_snapshot(bob))
iex> :ok = LoroEx.apply_update(bob, LoroEx.export_snapshot(alice))

iex> LoroEx.get_text(alice, "body") == LoroEx.get_text(bob, "body")
true
```

Note we created `alice` and `bob` with explicit peer ids via
`LoroEx.new/1`. For production server-side docs you always want a
**deterministic** peer id so the oplog stays compact across process
restarts:

```elixir
peer_id = :erlang.phash2({node(), doc_id})
doc = LoroEx.new(peer_id)
```

## Error handling

Every fallible call returns either its normal value or
`{:error, {reason_atom, detail_string}}`. Pattern-match on the atom:

```elixir
case LoroEx.apply_update(doc, peer_bytes) do
  :ok ->
    :ok

  {:error, {:checksum_mismatch, detail}} ->
    Logger.warning("peer sent corrupt bytes: \#{detail}")
    :skip_message

  {:error, {:incompatible_version, _}} ->
    {:error, :upgrade_loro}

  {:error, {reason, _}} ->
    Logger.error("apply_update failed: \#{reason}")
    :drop_peer
end
```

The full reason atom set is in `t:LoroEx.error_reason/0`. Common ones:

| Reason | Means |
|---|---|
| `:invalid_update` | Bytes aren't a Loro update |
| `:checksum_mismatch` | Bytes modified in transit |
| `:incompatible_version` | Peer is on a newer Loro format |
| `:out_of_bound` | Text position past the end |
| `:invalid_value` | Passed a non-scalar to `map_set` or `list_push` |
| `:tree_node_not_found` | Referenced a TreeID that doesn't exist |
| `:history_cleared` | Tried to resolve a cursor whose anchor was GC'd |

## Architectural note: one GenServer per doc

A `LoroDoc` handle is safe to pass between Elixir processes but **not
safe for concurrent mutation** — every NIF call takes an internal
mutex. The expected pattern is one GenServer owning each doc, with all
mutations flowing through its mailbox.

A minimal skeleton:

```elixir
defmodule MyApp.DocServer do
  use GenServer

  def start_link(doc_id) do
    GenServer.start_link(__MODULE__, doc_id, name: via(doc_id))
  end

  def insert(doc_id, pos, text) do
    GenServer.call(via(doc_id), {:insert, pos, text})
  end

  def init(doc_id) do
    peer_id = :erlang.phash2({node(), doc_id})
    doc = LoroEx.new(peer_id)
    # hydrate from storage, subscribe for broadcast, etc.
    {:ok, %{doc: doc, doc_id: doc_id}}
  end

  def handle_call({:insert, pos, text}, _from, state) do
    result = LoroEx.insert_text(state.doc, "body", pos, text)
    {:reply, result, state}
  end

  defp via(doc_id), do: {:via, Registry, {MyApp.DocRegistry, doc_id}}
end
```

## Where to go next

| Goal | Guide |
|---|---|
| Build a rich-text editor with formatting marks | [Rich text](rich_text.md) |
| Set up real-time sync for multiple users | [Sync & persistence](sync_and_persistence.md) |
| Show cursors and selections of other users | [Presence & cursors](presence_and_cursors.md) |
| Build a Notion-style nested-block document | [Tree & blocks](tree_and_blocks.md) |
| Add `Ctrl+Z` / `Ctrl+Shift+Z` | [Undo](undo.md) |
