# Presence & cursors

Presence is the "who's here and where are they looking" state in a
collaborative app — user cursors, selections, "is typing," display
names, colors. It's **not** the document; it expires on disconnect,
it doesn't need merge semantics, it just needs to flow between peers
quickly.

Stable cursors are the flip side: when I mark "my cursor is at
position 7," that position needs to survive concurrent edits by other
users. Otherwise my cursor jumps the moment someone types above me.

This guide covers both, with a complete multi-user example at the end.

## The two pieces

| Concept | API | What it does |
|---|---|---|
| Presence state | `LoroEx.Presence` | Ships ephemeral KV with TTL |
| Stable cursor | `LoroEx.text_get_cursor/4` + `cursor_resolve/2` | Anchors a position against the doc's ops |

They compose: store a stable cursor (as opaque bytes) inside a
presence entry, and the cursor will resolve correctly on every peer
even as the underlying doc shifts.

## Presence: basic usage

Create a store, set keys, encode & ship:

```elixir
iex> alice = LoroEx.Presence.new(30_000)  # 30-second TTL
iex> :ok = LoroEx.Presence.set(alice, "alice/cursor", %{"pos" => 7})
iex> :ok = LoroEx.Presence.set(alice, "alice/color", "#ff00aa")
iex> :ok = LoroEx.Presence.set(alice, "alice/name", "Alice")

iex> payload = LoroEx.Presence.encode_all(alice)
iex> is_binary(payload)
true
```

On the peer side, apply:

```elixir
iex> bob = LoroEx.Presence.new(30_000)
iex> :ok = LoroEx.Presence.apply(bob, payload)

iex> LoroEx.Presence.get(bob, "alice/cursor")
%{"pos" => 7}

iex> LoroEx.Presence.get_all_states(bob)
%{"alice/cursor" => ..., "alice/color" => "#ff00aa", "alice/name" => "Alice"}
```

## Key naming convention

Always **namespace by peer**: prefix every key with a stable peer id
so peers never collide.

```elixir
:ok = LoroEx.Presence.set(pres, "alice/cursor", %{"pos" => 7})
:ok = LoroEx.Presence.set(pres, "bob/cursor", %{"pos" => 42})
```

Common keys under a peer prefix:

| Key | Value | Purpose |
|---|---|---|
| `"<peer>/cursor"` | `%{"pos" => n, "len" => 0}` | Where the caret is |
| `"<peer>/selection"` | `%{"anchor" => n, "focus" => m}` | Text selection |
| `"<peer>/color"` | `"#ff00aa"` | Cursor color |
| `"<peer>/name"` | `"Alice"` | Display name |
| `"<peer>/typing"` | `true` | "Is typing" indicator |
| `"<peer>/focused_container"` | `"body"` | Which container they're in |

## Not a CRDT — last-write-wins with TTL

Presence is **not** a CRDT. It's LWW per key with timeouts:

- Two peers writing the same key: whoever's `apply/2` lands last wins
- Keys time out after the store's TTL
- `remove_outdated/1` prunes expired keys and fires a subscription event

This is the right trade-off for presence. You don't want to merge "my
cursor is at 7" with "my cursor is at 42" — one of them is stale,
keep the newest.

For persistent, mergeable state, use the main doc API (`map_set/4`).

## Subscription for real-time updates

Pushing updates is cheaper than polling. Subscribe `pid` to local
changes:

```elixir
defmodule MyApp.PresenceServer do
  use GenServer

  def init(room_id) do
    pres = LoroEx.Presence.new(30_000)
    _sub = LoroEx.Presence.subscribe(pres, self())

    # Periodic garbage collection
    :timer.send_interval(5_000, :gc)

    {:ok, %{pres: pres, room_id: room_id}}
  end

  # Local change → broadcast to peers
  def handle_info({:loro_ephemeral, _sub, bytes}, state) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "presence:\#{state.room_id}",
      {:presence_update, bytes}
    )
    {:noreply, state}
  end

  # Remote peer's update
  def handle_info({:presence_update, bytes}, state) do
    :ok = LoroEx.Presence.apply(state.pres, bytes)
    {:noreply, state}
  end

  # Periodic GC
  def handle_info(:gc, state) do
    :ok = LoroEx.Presence.remove_outdated(state.pres)
    {:noreply, state}
  end
end
```

## Stable cursors: the basic pattern

A raw integer cursor breaks under concurrent edits:

```elixir
iex> doc = LoroEx.new()
iex> :ok = LoroEx.insert_text(doc, "body", 0, "hello world")

# "I'm at position 6 (just before 'w')"
iex> my_pos = 6

# Someone else inserts at the start
iex> :ok = LoroEx.insert_text(doc, "body", 0, ">>> ")

# My integer is wrong now — "body" is ">>> hello world", pos 6 is 'l' not 'w'
iex> String.at(LoroEx.get_text(doc, "body"), my_pos)
"l"
```

A stable cursor fixes this. It anchors to a specific op in the doc,
and resolves to the current position *relative to that anchor*:

```elixir
iex> doc = LoroEx.new()
iex> :ok = LoroEx.insert_text(doc, "body", 0, "hello world")

iex> cursor = LoroEx.text_get_cursor(doc, "body", 6, :left)

# Concurrent insert above
iex> :ok = LoroEx.insert_text(doc, "body", 0, ">>> ")

iex> {pos, _side} = LoroEx.cursor_resolve(doc, cursor)
iex> pos
10  # still points at 'w' in ">>> hello world"

iex> String.at(LoroEx.get_text(doc, "body"), pos)
"w"
```

## Cursor side

When choosing the `side` parameter, think about what happens if
someone inserts *exactly* at your cursor's position:

- `:left` — cursor stays to the left of the insertion. Use for the
  start of a selection.
- `:right` — cursor stays to the right. Use for the end of a
  selection.
- `:middle` — Loro picks. Default, usually right for most editor
  behavior.

For a selection, convert both endpoints:

```elixir
start_cursor = LoroEx.text_get_cursor(doc, "body", selection.start, :left)
end_cursor   = LoroEx.text_get_cursor(doc, "body", selection.end, :right)
```

## Putting it together: cursor in presence

Store the cursor bytes inside presence so every peer can render
everyone else's caret:

```elixir
# Alice's side — on selection change
start_cursor = LoroEx.text_get_cursor(doc, "body", sel.start, :left)
end_cursor   = LoroEx.text_get_cursor(doc, "body", sel.end, :right)

:ok = LoroEx.Presence.set(pres, "alice/cursor", %{
  "start" => Base.encode64(start_cursor),
  "end"   => Base.encode64(end_cursor)
})
```

On the peer side, every render frame:

```elixir
# Bob's side
case LoroEx.Presence.get(pres, "alice/cursor") do
  %{"start" => b64_start, "end" => b64_end} ->
    start_cursor = Base.decode64!(b64_start)
    end_cursor = Base.decode64!(b64_end)
    {start_pos, _} = LoroEx.cursor_resolve(bob_doc, start_cursor)
    {end_pos, _} = LoroEx.cursor_resolve(bob_doc, end_cursor)
    render_remote_selection(:alice, start_pos, end_pos)

  nil ->
    # Alice hasn't set a cursor or TTL expired
    hide_remote_selection(:alice)
end
```

Alice's cursor will render *correctly* on Bob's screen even if Bob's
doc is ahead of Alice's — the cursor anchors to an op id, not a raw
index.

## Cursor errors to handle

`cursor_resolve/2` can fail:

```elixir
case LoroEx.cursor_resolve(doc, cursor) do
  {pos, side} ->
    render(pos, side)

  {:error, {:container_deleted, _}} ->
    # The container the cursor pointed at is gone
    hide_cursor()

  {:error, {:history_cleared, _}} ->
    # Doc was hydrated from a shallow snapshot that dropped the anchor op
    # Fall back to a best-guess position
    render(0, :middle)

  {:error, {:id_not_found, _}} ->
    # Local doc hasn't received the peer's ops yet; wait for sync
    defer_render()
end
```

## Complete example: multi-user cursor server

Putting all the pieces together as a Phoenix Channel server:

```elixir
defmodule MyAppWeb.RoomChannel do
  use Phoenix.Channel

  def join("room:" <> room_id, %{"peer_id" => peer_id}, socket) do
    MyApp.RoomServer.subscribe(room_id, peer_id)
    # hydrate with current doc + current presence
    snap = MyApp.RoomServer.get_snapshot(room_id)
    pres = MyApp.RoomServer.get_presence(room_id)

    {:ok,
     %{
       snapshot: Base.encode64(snap),
       presence: Base.encode64(pres)
     },
     assign(socket, peer_id: peer_id, room_id: room_id)}
  end

  def handle_in("doc_update", %{"bytes" => b64}, socket) do
    bytes = Base.decode64!(b64)
    :ok = MyApp.RoomServer.apply_doc_update(socket.assigns.room_id, bytes)
    {:noreply, socket}
  end

  def handle_in("presence_update", %{"bytes" => b64}, socket) do
    bytes = Base.decode64!(b64)
    :ok = MyApp.RoomServer.apply_presence_update(socket.assigns.room_id, bytes)
    {:noreply, socket}
  end

  def handle_info({:doc_update, bytes}, socket) do
    push(socket, "doc_update", %{bytes: Base.encode64(bytes)})
    {:noreply, socket}
  end

  def handle_info({:presence_update, bytes}, socket) do
    push(socket, "presence_update", %{bytes: Base.encode64(bytes)})
    {:noreply, socket}
  end
end
```

The `RoomServer` owns one `LoroDoc` and one `LoroEx.Presence` per
room, subscribes itself to both, and rebroadcasts via PubSub. Each
connected channel applies remote bytes to its own doc.

## Performance notes

- **Presence is high-frequency, small payloads.** A cursor update
  every animation frame is fine — each payload is a few dozen bytes.
- **Don't wrap cursors in JSON unnecessarily.** If you only need the
  cursor (no other metadata), `encode/2` a single key rather than
  re-encoding a map every time.
- **Run `remove_outdated/1` on a timer**, not on every update.
  Somewhere between 1s and 30s works; exact value isn't critical.

## What about non-cursor presence (typing indicators, etc.)?

Same pattern — set a scalar key with TTL; peers observe through their
own `get/2` or `get_all_states/1`:

```elixir
:ok = LoroEx.Presence.set(pres, "alice/typing", true)
# ...on blur/timeout...
:ok = LoroEx.Presence.delete(pres, "alice/typing")
```

The TTL gives you automatic cleanup if the client disconnects without
sending the delete.
