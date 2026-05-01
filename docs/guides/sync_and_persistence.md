# Sync & persistence

This guide covers the wire-format primitives and the server-side
architecture patterns for using LoroEx as the state engine in a
collaborative product.

## The three export modes

Loro offers three ways to export a doc's state:

| Mode | API | Contains | Use case |
|---|---|---|---|
| Full snapshot | `export_snapshot/1` | Every op since doc creation | First-time hydrate, cold storage |
| Shallow snapshot | `export_shallow_snapshot/2` | State + ops after a frontier | Onboarding, warm storage |
| Delta | `export_updates/2` | Ops the peer doesn't have | Real-time sync |

Picking the right one matters — full snapshots on every sync tick
will consume your bandwidth budget.

### Full snapshot

```elixir
snap = LoroEx.export_snapshot(doc)
```

Self-contained. A fresh doc given these bytes is identical to the
source (modulo peer id). Use for the initial load and for storage
checkpoints.

### Delta (updates)

```elixir
# Peer sends you their version:
their_version = ...  # opaque binary they got from oplog_version/1

# You reply with just the ops they're missing:
delta = LoroEx.export_updates(doc, their_version)
```

**Always prefer deltas for ongoing sync.** A typical delta for a
single keystroke is ~20 bytes; a full snapshot of a mature doc can be
hundreds of KB.

### Shallow snapshot

```elixir
frontier = LoroEx.oplog_frontiers(doc)
shallow = LoroEx.export_shallow_snapshot(doc, frontier)
```

Intermediate: ships current state but drops ops before the frontier.
The receiver can't time-travel past that frontier but everything
current works. Use for:
- Onboarding a new peer on a long-lived doc (drop 6 months of history)
- Monthly storage rollups (drop last month's ops, keep the state)

## The three version types

Loro has three related version types. They are **not**
interchangeable:

| Type | API | Shape | Accepted by |
|---|---|---|---|
| Op-log VV | `oplog_version/1` | Per-peer counter map | `export_updates/2` |
| State VV | `state_vector/1` | Same, may lag op-log | Rarely needed |
| Frontier | `oplog_frontiers/1` | Set of op ids | `export_shallow_snapshot/2` |

Mixing them up returns `{:error, {:invalid_version_vector, _}}` or
`{:error, {:invalid_frontier, _}}`. Keep the variable names tight:

```elixir
# Version vector — for delta sync
my_version = LoroEx.oplog_version(doc)

# Frontier — for shallow snapshots
my_frontier = LoroEx.oplog_frontiers(doc)
```

All four are opaque binaries. Never inspect the bytes.

## Delta sync protocol (request/response)

The canonical two-peer sync:

```elixir
# Alice asks Bob for her missing state
alice_version = LoroEx.oplog_version(alice)

# Bob computes the delta
delta = LoroEx.export_updates(bob, alice_version)

# Alice applies
:ok = LoroEx.apply_update(alice, delta)

# To sync the other direction, swap names
```

## Real-time sync via subscriptions

For continuous sync, skip the polling and push every change. LoroEx
emits update bytes for every local commit via `subscribe/2`:

```elixir
defmodule MyApp.DocServer do
  use GenServer

  def init(doc_id) do
    doc = hydrate(doc_id)
    _sub = LoroEx.subscribe(doc, self())
    {:ok, %{doc: doc, doc_id: doc_id}}
  end

  def handle_info({:loro_event, _sub, bytes}, state) do
    # Fan out to every connected client
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "doc:\#{state.doc_id}",
      {:doc_update, bytes}
    )

    # Persist
    Task.start(fn -> MyApp.Storage.append(state.doc_id, bytes) end)

    {:noreply, state}
  end
end
```

On the client side of the WebSocket, every received payload is ready
to apply:

```elixir
def handle_in("update", %{"bytes" => b64}, socket) do
  bytes = Base.decode64!(b64)
  :ok = LoroEx.apply_update(socket.assigns.doc, bytes)
  {:noreply, socket}
end
```

## Persistence patterns

### Append-only log + snapshot compaction

The pattern with the best recovery story:

1. On every `{:loro_event, _, bytes}`, append the bytes to disk or
   object storage.
2. Periodically (hourly, daily, on size threshold), take an
   `export_snapshot/1` and mark the log as checkpointed.
3. To recover: load the latest snapshot, then replay any log entries
   after the checkpoint.

```elixir
defmodule MyApp.Storage do
  def append(doc_id, bytes) do
    File.write!(log_path(doc_id), bytes, [:append])
  end

  def checkpoint(doc_id, doc) do
    snap = LoroEx.export_snapshot(doc)
    File.write!(snap_path(doc_id), snap)
    File.rm!(log_path(doc_id))
  end

  def load(doc_id) do
    doc = LoroEx.new(:erlang.phash2({node(), doc_id}))

    # 1. Load snapshot if it exists
    if File.exists?(snap_path(doc_id)) do
      snap = File.read!(snap_path(doc_id))
      :ok = LoroEx.apply_update(doc, snap)
    end

    # 2. Replay any log entries after the snapshot
    if File.exists?(log_path(doc_id)) do
      replay_log(doc, log_path(doc_id))
    end

    doc
  end
end
```

### Single-snapshot storage (simpler, higher I/O)

On every change, overwrite a single snapshot blob:

```elixir
def handle_info({:loro_event, _sub, _bytes}, state) do
  snap = LoroEx.export_snapshot(state.doc)
  File.write!(snap_path(state.doc_id), snap)
  {:noreply, state}
end
```

Works for small, low-volume docs. Snapshots get expensive for hot docs.

### S3 / object storage

`export_snapshot/1` returns a plain binary; write it to S3 like any
blob. For bulk onboarding, pre-compute shallow snapshots against
well-known frontiers (e.g. start-of-month) so new joiners get a
compact baseline + a short tail of recent ops.

## Handling peer joins

When a new peer connects:

1. Server sends a **full snapshot** (first connection) or **shallow
   snapshot** against a well-known frontier (if the doc is large).
2. Client hydrates with `apply_update/2`.
3. Both sides subscribe to each other's updates.

```elixir
# Server side (Phoenix Channel join)
def join("doc:" <> doc_id, _params, socket) do
  doc = MyApp.DocServer.get_doc(doc_id)
  snap = LoroEx.export_snapshot(doc)
  {:ok, %{snapshot: Base.encode64(snap)}, socket}
end

# Client side
def init(doc_id) do
  {:ok, response, _ref} = Phoenix.Client.join("doc:\#{doc_id}")
  doc = LoroEx.new()
  :ok = LoroEx.apply_update(doc, Base.decode64!(response["snapshot"]))
  {:ok, %{doc: doc}}
end
```

## Resuming after disconnect

When a client reconnects after offline work:

```elixir
# Client has made offline edits; its version is ahead of what server saw
my_version = LoroEx.oplog_version(client_doc)

# Server asks: "send me what you have past <my_last_seen_client_version>"
# Client replies:
delta = LoroEx.export_updates(client_doc, server_seen_version)
send_to_server(delta)

# Then the reverse: client asks server for updates since last sync
```

This is a standard two-way handshake. The only subtlety: each side
needs to remember **the last version vector they saw from the other
side**, not their own latest version. That's what makes the delta
minimal.

## Memory profile and idle eviction

A "hot" doc with 100k ops occupies ~50MB of Rust heap per instance.
For a server holding N hot docs you'll see `N * 50MB` out of BEAM's
accounting. Two mitigations:

1. **Idle doc eviction.** Kill the GenServer after M minutes of no
   activity; hydrate from storage on next access.
2. **Shallow snapshots at rest.** Persist shallow snapshots instead
   of full ones for cold docs — the snapshot itself is smaller, and
   the hydrated doc starts with compact state.

## Error handling in sync paths

Peer-supplied bytes are untrusted. Always handle:

```elixir
case LoroEx.apply_update(doc, peer_bytes) do
  :ok ->
    :ok

  {:error, {:checksum_mismatch, _}} ->
    # Likely network corruption; ask for retransmit
    :retry

  {:error, {:invalid_update, _}} ->
    # Peer sent garbage; could be a bug or malice
    Logger.warning("invalid update from peer \#{peer_id}")
    :drop_peer

  {:error, {:incompatible_version, _}} ->
    # Peer is on a newer Loro format than we support
    {:error, :upgrade_required}

  {:error, {reason, detail}} ->
    # Unknown; log and move on
    Logger.error("sync failure: \#{reason} - \#{detail}")
    :skip
end
```

Don't `raise` on peer-supplied input. Every sync path should be a
clean `case` that handles errors gracefully.

## Structured diffs for indexing and audit

If you need more than "something changed" — e.g. you're building a
search index or an audit log — use `subscribe_root/2` instead of
`subscribe/2`:

```elixir
iex> _sub = LoroEx.subscribe_root(doc, self())
iex> :ok = LoroEx.insert_text(doc, "body", 0, "hi")

iex> receive do
...>   {:loro_diff, _sub, events_json} ->
...>     events = Jason.decode!(events_json)
...>     # events is a list of per-container diffs, each with a
...>     # structured diff (Quill delta for text, map updates for
...>     # maps, etc.)
...> end
```

This is typically a separate subscriber from the sync path — one
subscription for "broadcast raw bytes," one for "index structured
changes."

## What's not covered

`export_shallow_snapshot/2` requires a *frontier*, not a version
vector. Frontiers are a different beast — see the API docs for
`oplog_frontiers/1` and `shallow_since_frontiers/1`.

Time travel (`checkout`, `fork_at`, `revert_to`) isn't yet exposed
from LoroEx but is on the roadmap.
