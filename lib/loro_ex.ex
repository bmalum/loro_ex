defmodule LoroEx do
  @moduledoc """
  Elixir bindings to the [Loro](https://loro.dev) CRDT library.

  `LoroEx` wraps the Loro Rust library through a Rustler NIF. It exposes
  Loro's document model — text with Peritext formatting, maps, lists,
  and a movable block tree — plus everything you need to build a
  collaborative editor on top: stable cursors, per-peer undo, structured
  diff subscriptions, and an ephemeral presence store.

  If you're new to the library, start with the
  [Getting started guide](guides/getting_started.md). For topic-oriented
  tutorials see:

    * [Rich text](guides/rich_text.md) — marks, deltas, editor integrations
    * [Sync & persistence](guides/sync_and_persistence.md) — snapshots, deltas, server architecture
    * [Presence & cursors](guides/presence_and_cursors.md) — multi-user state that survives edits
    * [Tree & blocks](guides/tree_and_blocks.md) — Notion-style block editors
    * [Undo](guides/undo.md) — per-peer history

  ## 30-second tour

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello")
      LoroEx.get_text(doc, "body")
      # => "hello"

      # Share state with a peer
      snap  = LoroEx.export_snapshot(doc)
      other = LoroEx.new()
      :ok   = LoroEx.apply_update(other, snap)
      LoroEx.get_text(other, "body")
      # => "hello"

  ## Concurrency model

  `LoroDoc` handles are safe to pass between Elixir processes but are
  NOT safe for concurrent mutation — every NIF call acquires an internal
  mutex. The expected usage is **one GenServer per doc** that owns the
  handle, with all mutations flowing through its mailbox.

  ## Container addressing

  Every container-taking function accepts a `container_id` string in one
  of two forms:

    * A **root name** like `"body"` or `"settings"`. The first call that
      uses the name materializes a root container of the appropriate
      kind (text / map / list / tree) and subsequent calls address the
      same container.
    * A **serialized `ContainerID`** returned from
      `map_insert_container/4`, `list_insert_container/4`, or
      `tree_get_meta/3`. These address *nested* containers.

  Callers don't need to track which form is which; the NIF resolves
  both transparently.

  ## Error handling

  Fallible calls return either their normal value or
  `{:error, {reason, detail}}` where `reason` is a stable atom and
  `detail` is a human-readable string. Example:

      case LoroEx.apply_update(doc, bytes) do
        :ok ->
          :ok

        {:error, {:checksum_mismatch, detail}} ->
          Logger.warning("peer sent corrupt bytes: \#{detail}")
          :skip

        {:error, {reason, _}} when reason in [:invalid_update, :incompatible_version] ->
          {:error, :drop_peer}
      end

  See `t:error_reason/0` for the full atom set.
  """

  alias LoroEx.Native

  @typedoc "Opaque handle to a Loro document. Reference-counted; drop the last ref to free."
  @type doc :: reference()
  @typedoc """
  Opaque handle to a subscription. You must call `unsubscribe/1` to
  cancel; dropping the reference alone does not auto-cancel (known
  limitation, planned fix in 0.5.1).
  """
  @type subscription :: reference()
  @typedoc "Opaque handle to an `UndoManager`."
  @type undo_manager :: reference()
  @typedoc "Opaque handle to an `EphemeralStore`."
  @type ephemeral_store :: reference()
  @typedoc """
  Opaque, encoded `Cursor`. Produced by `text_get_cursor/4` /
  `list_get_cursor/4`; consumed by `cursor_resolve/2`. Safe to persist
  or ship across the network as bytes.
  """
  @type cursor :: binary()
  @typedoc "Opaque version vector, produced by `oplog_version/1` / `state_vector/1`."
  @type version :: binary()
  @typedoc "Opaque frontier (a set of op ids)."
  @type frontier :: binary()
  @typedoc "Either a root-container name or a serialized nested-container id."
  @type container_id :: String.t()
  @typedoc "Kind atom used when creating a nested container."
  @type container_kind :: :text | :map | :list | :movable_list
  @typedoc """
  Cursor bias when multiple ops land at the same position.
    * `:left` — treat inserts at this position as being *before* the cursor
    * `:middle` (default) — cursor is at the position
    * `:right` — treat inserts at this position as being *after* the cursor
  """
  @type cursor_side :: :left | :middle | :right
  @typedoc """
  Unit system for text positions. Unicode is the default; `:utf8` and
  `:utf16` exist for bridging to byte- or UTF-16-indexed editors
  (browsers, many native text fields).
  """
  @type pos_unit :: :unicode | :utf8 | :utf16
  @type error_reason ::
          :invalid_update
          | :invalid_version_vector
          | :invalid_frontier
          | :invalid_tree_id
          | :invalid_peer_id
          | :invalid_value
          | :invalid_cursor
          | :invalid_delta
          | :invalid_container_kind
          | :checksum_mismatch
          | :incompatible_version
          | :not_found
          | :out_of_bound
          | :cyclic_move
          | :tree_node_not_found
          | :fractional_index_not_enabled
          | :index_out_of_bound
          | :container_deleted
          | :history_cleared
          | :id_not_found
          | :lock_poisoned
          | :ephemeral_apply_failed
          | :unknown
  @type error :: {:error, {error_reason(), String.t()}}

  # ============================================================================
  # Lifecycle
  # ============================================================================

  @doc """
  Create a new, empty document with a random peer id.

  ## Use cases

  Use this for client-side docs where the peer id doesn't need to be
  stable across process restarts. Two docs created with `new/0` will
  almost certainly get different peer ids and can exchange updates
  without conflict.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello")
      LoroEx.get_text(doc, "body")
      # => "hello"

  ## See also

    * `new/1` — when you need a deterministic peer id (server-side)
  """
  @spec new() :: doc()
  defdelegate new(), to: Native, as: :new_doc

  @doc """
  Create a new, empty document with an explicit peer id.

  ## Use cases

  Use this for server-side docs and tests where you need the same peer
  id across process restarts. A stable peer id keeps the oplog compact
  (one peer = one append-only stripe) and makes `UndoManager` behavior
  predictable — undo is scoped to a peer id, so if it changes the
  manager loses track of what's undoable.

  A common pattern for a server-side doc:

      peer_id = :erlang.phash2({node(), doc_id})
      doc = LoroEx.new(peer_id)

  ## Example

      doc = LoroEx.new(42)
      :ok = LoroEx.insert_text(doc, "body", 0, "hello")

  ## Errors

    * `{:error, {:invalid_peer_id, _}}` — peer id is `PeerID::MAX` (reserved).
  """
  @spec new(non_neg_integer()) :: doc() | error()
  defdelegate new(peer_id), to: Native, as: :new_doc_with_peer

  # ============================================================================
  # Sync primitives
  # ============================================================================

  @doc """
  Apply a remote update (snapshot or delta) to the document.

  The bytes must come from `export_snapshot/1`, `export_shallow_snapshot/2`,
  `export_updates/2`, or a subscription's `{:loro_event, _, bytes}`
  message. Duplicates and out-of-order updates are handled internally —
  you can replay the same update twice, and applying delta N+1 before
  delta N works as long as you eventually catch up.

  ## Use cases

  This is the entry point for every sync scenario:

    * **New joiner** — apply a full snapshot to hydrate a fresh doc.
    * **Incremental sync** — apply a delta produced with `export_updates/2`.
    * **Server broadcast** — each client subscribes and forwards
      `{:loro_event, _, bytes}` to the server, which fans out to other
      clients who call `apply_update/2`.

  ## Example

      source = LoroEx.new()
      :ok    = LoroEx.insert_text(source, "body", 0, "hello")

      mirror = LoroEx.new()
      :ok    = LoroEx.apply_update(mirror, LoroEx.export_snapshot(source))

      LoroEx.get_text(mirror, "body")
      # => "hello"

  ## Errors

    * `{:error, {:invalid_update, _}}` — bytes are corrupt or not a Loro update
    * `{:error, {:checksum_mismatch, _}}` — bytes were modified in transit
    * `{:error, {:incompatible_version, _}}` — bytes are from a newer Loro format
  """
  @spec apply_update(doc(), binary()) :: :ok | error()
  defdelegate apply_update(doc, bytes), to: Native

  @doc """
  Export the entire document state as a self-contained snapshot.

  The returned binary is a **full** snapshot: every op, every
  container, every piece of state. A fresh doc given these bytes via
  `apply_update/2` becomes identical to the source (modulo peer id).

  ## Use cases

    * Hydrate a new peer joining a doc for the first time.
    * Persist the doc to storage (S3, Postgres, disk) for later revival.
    * Debug: `byte_size(export_snapshot(doc))` tells you how large the
      doc is on the wire.

  If you already know what the peer has, prefer `export_updates/2` —
  it's much smaller.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello")

      snap = LoroEx.export_snapshot(doc)
      byte_size(snap)
      # => a small number of bytes

      other = LoroEx.new()
      :ok   = LoroEx.apply_update(other, snap)
  """
  @spec export_snapshot(doc()) :: binary() | error()
  defdelegate export_snapshot(doc), to: Native

  @doc """
  Export a shallow snapshot trimmed to the given frontier.

  A shallow snapshot drops the op history *before* the frontier. The
  resulting bytes are smaller than a full snapshot but the receiving
  doc can't time-travel past that frontier — everything before is
  opaque state.

  ## Use cases

    * Onboarding new joiners on large docs: give them the current state
      without shipping years of edit history.
    * Storage tier: snapshot a doc to cold storage at month boundaries;
      each snapshot is shallow against the previous month's frontier.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "baseline content")

      frontier = LoroEx.oplog_frontiers(doc)
      shallow  = LoroEx.export_shallow_snapshot(doc, frontier)

      reader = LoroEx.new()
      :ok    = LoroEx.apply_update(reader, shallow)
      LoroEx.get_text(reader, "body")
      # => "baseline content"

  ## Errors

    * `{:error, {:invalid_frontier, _}}` — the frontier bytes didn't decode
    * `{:error, {:not_found, _}}` — the frontier references op ids not in this doc
  """
  @spec export_shallow_snapshot(doc(), frontier()) :: binary() | error()
  defdelegate export_shallow_snapshot(doc, frontier), to: Native

  @doc """
  Export the incremental updates a peer needs, given its version.

  The `version` binary is what the peer produced from its own
  `oplog_version/1`. The returned delta contains exactly the ops you
  have that the peer doesn't.

  ## Use cases

    * Real-time sync — cheaper than sending full snapshots on every
      tick. Ask the peer for its `oplog_version/1`, export just the
      diff.
    * Bandwidth-constrained environments.

  ## Example

      server = LoroEx.new()
      client = LoroEx.new()

      # Client hydrates from a snapshot
      :ok = LoroEx.apply_update(client, LoroEx.export_snapshot(server))

      # Client tells the server its version
      version = LoroEx.oplog_version(client)

      # Server makes a small edit
      :ok = LoroEx.insert_text(server, "body", 0, "x")

      # Delta is much smaller than a full snapshot
      delta = LoroEx.export_updates(server, version)
      :ok   = LoroEx.apply_update(client, delta)

  ## Errors

    * `{:error, {:invalid_version_vector, _}}` — the version didn't decode
      (probably you passed `state_vector/1` or a frontier instead of
      `oplog_version/1`).
  """
  @spec export_updates(doc(), version()) :: binary() | error()
  defdelegate export_updates(doc, version), to: Native, as: :export_updates_from

  @doc """
  Return the opaque **op-log version vector** for this document.

  A version vector is a per-peer counter map: "I have seen counter N
  from peer P, counter M from peer Q, …". Pass it to the other side so
  they can compute a delta with `export_updates/2`.

  Opaque — don't inspect the bytes.

  ## Use cases

  The request leg of a delta sync handshake:

      # Client → server: "here's what I have"
      my_version = LoroEx.oplog_version(my_doc)

      # Server → client: "here's what you're missing"
      delta = LoroEx.export_updates(server_doc, my_version)

  ## Example

      doc = LoroEx.new()
      v   = LoroEx.oplog_version(doc)
      is_binary(v)
      # => true
  """
  @spec oplog_version(doc()) :: version() | error()
  defdelegate oplog_version(doc), to: Native

  @doc """
  Return the opaque **state** version vector.

  Distinct from `oplog_version/1`: the state VV reflects the current
  visible state, which may lag the oplog when there are queued but
  not-yet-committed ops. In practice that gap is microseconds and only
  matters if you've explicitly deferred commits. Use `oplog_version/1`
  unless you know you need this one.
  """
  @spec state_vector(doc()) :: version() | error()
  defdelegate state_vector(doc), to: Native

  @doc """
  Return the opaque **op-log frontier** — a set of op ids, not a
  per-peer counter map.

  Frontiers and version vectors are related but not interchangeable.
  `export_shallow_snapshot/2` needs a frontier; `export_updates/2`
  needs a version vector. Getting them confused returns
  `{:error, {:invalid_*, _}}`.

  ## Use case

  Pin the current state as an anchor for a shallow snapshot:

      frontier = LoroEx.oplog_frontiers(doc)
      snap     = LoroEx.export_shallow_snapshot(doc, frontier)
  """
  @spec oplog_frontiers(doc()) :: frontier() | error()
  defdelegate oplog_frontiers(doc), to: Native

  @doc """
  Return the current **state frontier**. May lag `oplog_frontiers/1`
  when commits are pending. Rarely what you want — use
  `oplog_frontiers/1`.
  """
  @spec state_frontiers(doc()) :: frontier() | error()
  defdelegate state_frontiers(doc), to: Native

  @doc """
  Return the frontier at which this doc's history is truncated.

  For a doc hydrated from a shallow snapshot, this tells you where the
  retained history starts; everything before is opaque baseline. Useful
  to detect whether a doc was shallow-hydrated, or to avoid issuing a
  `checkout` to a frontier that's no longer addressable.
  """
  @spec shallow_since_frontiers(doc()) :: frontier() | error()
  defdelegate shallow_since_frontiers(doc), to: Native

  # ============================================================================
  # Text (plain)
  # ============================================================================

  @doc """
  Read a text container's current value as a plain string.

  Returns `""` for a container that hasn't been written to yet
  (accessing a root name also creates the container).

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello")
      LoroEx.get_text(doc, "body")
      # => "hello"

  See `text_to_delta/2` if you need to read the text *with formatting*.
  """
  @spec get_text(doc(), container_id()) :: String.t() | error()
  defdelegate get_text(doc, container_id), to: Native

  @doc """
  Insert `value` at Unicode codepoint position `pos` in the text container.

  Positions are Unicode scalar (codepoint) indices by default. If
  you're coming from a browser editor that uses UTF-16, convert first
  with `text_convert_pos/5`.

  ## Examples

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello")
      :ok = LoroEx.insert_text(doc, "body", 5, " world")
      LoroEx.get_text(doc, "body")
      # => "hello world"

  ## Errors

    * `{:error, {:out_of_bound, _}}` — `pos` is past the end of the text.
  """
  @spec insert_text(doc(), container_id(), non_neg_integer(), String.t()) ::
          :ok | error()
  defdelegate insert_text(doc, container_id, pos, value), to: Native

  @doc """
  Delete `len` Unicode codepoints starting at `pos`.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello world")
      :ok = LoroEx.delete_text(doc, "body", 5, 6)
      LoroEx.get_text(doc, "body")
      # => "hello"

  ## Errors

    * `{:error, {:out_of_bound, _}}` — the range runs past the text.
  """
  @spec delete_text(doc(), container_id(), non_neg_integer(), non_neg_integer()) ::
          :ok | error()
  defdelegate delete_text(doc, container_id, pos, len), to: Native

  # ============================================================================
  # Rich text (Peritext marks)
  # ============================================================================

  @doc """
  Apply a Peritext mark to a Unicode range.

  A mark is a (key, value) annotation over a range of text —
  `bold: true`, `link: "https://…"`, `color: "#ff0000"`. Peritext's
  property is that marks survive concurrent edits correctly: if Alice
  bolds "hello" while Bob inserts "!" in the middle ("hel!lo"), the
  bolding applies to the merged "hel!lo" instead of splitting into
  two runs.

  `value` is anything `Jason.encode!/1` can handle as a scalar —
  boolean, number, string, or `nil`. Objects and arrays will return
  `{:error, {:invalid_value, _}}`.

  ## Use cases

    * Rich text editors (TipTap, ProseMirror, CodeMirror) — map
      document-level formatting to Loro marks.
    * Inline annotations (comments, @-mentions, tagged entities).
    * Any "tag a slice of text" feature.

  ## Examples

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "Hello, world!")

      # Boolean mark
      :ok = LoroEx.text_mark(doc, "body", 0, 5, "bold", true)

      # String value
      :ok = LoroEx.text_mark(doc, "body", 7, 12, "link", "https://loro.dev")

      # Numeric value
      :ok = LoroEx.text_mark(doc, "body", 0, 5, "font_size", 18)

  ## See also

    * `text_unmark/5` to remove a mark
    * `text_to_delta/2` to read text + marks back as Quill ops
  """
  @spec text_mark(
          doc(),
          container_id(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          boolean() | number() | String.t() | nil
        ) :: :ok | error()
  def text_mark(doc, container_id, start_pos, end_pos, key, value) do
    Native.text_mark(doc, container_id, start_pos, end_pos, key, Jason.encode!(value))
  end

  @doc """
  Remove a Peritext mark with the given `key` over a Unicode range.

  Only the portion of the mark that falls within `start_pos..end_pos`
  is removed; a `bold` mark from 0..10 with `unmark(3, 7, "bold")`
  becomes two marks: 0..3 and 7..10.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "ABCDE")
      :ok = LoroEx.text_mark(doc, "body", 0, 5, "bold", true)
      :ok = LoroEx.text_unmark(doc, "body", 2, 4, "bold")

      # "AB" is bold, "CD" is not, "E" is bold again
  """
  @spec text_unmark(
          doc(),
          container_id(),
          non_neg_integer(),
          non_neg_integer(),
          String.t()
        ) :: :ok | error()
  defdelegate text_unmark(doc, container_id, start_pos, end_pos, key), to: Native

  @doc """
  Export the text container as a decoded [Quill
  delta](https://quilljs.com/docs/delta/) — a list of `%{"insert" =>
  ..., "attributes" => ...}` / `%{"retain" => n}` / `%{"delete" => n}`
  ops.

  This is the format TipTap, ProseMirror, CodeMirror, and Quill all
  consume. A rich-text editor in the browser can apply these deltas
  directly to its internal model.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "Hello world!")
      :ok = LoroEx.text_mark(doc, "body", 0, 5, "bold", true)

      LoroEx.text_to_delta(doc, "body")
      # =>
      # [
      #   %{"insert" => "Hello", "attributes" => %{"bold" => true}},
      #   %{"insert" => " world!"}
      # ]

  ## See also

    * `text_apply_delta/3` — the inverse; apply a delta from a peer
    * `text_get_richtext_value/2` — alternative, segment-oriented format
  """
  @spec text_to_delta(doc(), container_id()) :: [map()] | error()
  def text_to_delta(doc, container_id) do
    case Native.text_to_delta(doc, container_id) do
      {:error, _} = e -> e
      json when is_binary(json) -> Jason.decode!(json)
    end
  end

  @doc """
  Apply a Quill-compatible delta to the text container.

  Inverse of `text_to_delta/2`. Useful on the receiving side: fetch
  ops from an editor's "output delta" event, ship them to the server,
  apply.

  ## Example

      source = LoroEx.new(1)
      :ok    = LoroEx.insert_text(source, "body", 0, "Hello")
      :ok    = LoroEx.text_mark(source, "body", 0, 5, "bold", true)
      delta  = LoroEx.text_to_delta(source, "body")

      mirror = LoroEx.new(2)
      :ok    = LoroEx.text_apply_delta(mirror, "body", delta)

      LoroEx.text_to_delta(mirror, "body") == delta
      # => true

  ## Errors

    * `{:error, {:invalid_delta, _}}` — the list isn't a valid Quill delta
  """
  @spec text_apply_delta(doc(), container_id(), [map()]) :: :ok | error()
  def text_apply_delta(doc, container_id, delta) when is_list(delta) do
    Native.text_apply_delta(doc, container_id, Jason.encode!(delta))
  end

  @doc """
  Return the rich-text value as a decoded list of segments.

  Each segment has the shape `%{"insert" => "…", "attributes" => %{…}}`.
  Similar to `text_to_delta/2` but without `retain`/`delete` bookkeeping
  — useful when you want to render, not to edit.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "Hello world")
      :ok = LoroEx.text_mark(doc, "body", 0, 5, "bold", true)

      LoroEx.text_get_richtext_value(doc, "body")
      # =>
      # [
      #   %{"insert" => "Hello", "attributes" => %{"bold" => true}},
      #   %{"insert" => " world"}
      # ]
  """
  @spec text_get_richtext_value(doc(), container_id()) :: [map()] | error()
  def text_get_richtext_value(doc, container_id) do
    case Native.text_get_richtext_value(doc, container_id) do
      {:error, _} = e -> e
      json when is_binary(json) -> Jason.decode!(json)
    end
  end

  @doc """
  Return the length of a text container in the given unit.

  | Unit     | What it counts                     | Typical consumer         |
  |----------|-----------------------------------|---------------------------|
  | `:unicode` | Unicode codepoints (scalars)    | Elixir strings, Loro defaults |
  | `:utf8`    | UTF-8 bytes                     | Server-side tokenizers    |
  | `:utf16`   | UTF-16 code units               | Browser editors, macOS APIs |

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "é")

      LoroEx.text_len(doc, "body", :unicode)  # 1
      LoroEx.text_len(doc, "body", :utf8)     # 2 (0xC3 0xA9)
      LoroEx.text_len(doc, "body", :utf16)    # 1

  ## See also

    * `text_convert_pos/5` — convert an index between units
  """
  @spec text_len(doc(), container_id(), pos_unit()) :: non_neg_integer() | error()
  def text_len(doc, container_id, :unicode), do: Native.text_len_unicode(doc, container_id)
  def text_len(doc, container_id, :utf8), do: Native.text_len_utf8(doc, container_id)
  def text_len(doc, container_id, :utf16), do: Native.text_len_utf16(doc, container_id)

  def text_len(_doc, _container_id, unit),
    do: {:error, {:invalid_value, "unit must be :unicode | :utf8 | :utf16, got: #{inspect(unit)}"}}

  @doc """
  Convert a text position from one unit system to another.

  Essential at the boundary between a browser editor (which thinks in
  UTF-16 code units) and a Loro doc (which thinks in Unicode
  codepoints). Failing to convert is the most common cause of "the
  cursor jumped" bugs.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "aéb")

      # "b" is at Unicode index 2, UTF-8 byte 3 (a:1 + é:2 = 3)
      LoroEx.text_convert_pos(doc, "body", 2, :unicode, :utf8)
      # => 3

      LoroEx.text_convert_pos(doc, "body", 3, :utf8, :unicode)
      # => 2

  ## Errors

    * `{:error, {:out_of_bound, _}}` — the source index doesn't point
      to a valid boundary in the source unit system (e.g. landing inside
      a multi-byte sequence).
  """
  @spec text_convert_pos(
          doc(),
          container_id(),
          non_neg_integer(),
          pos_unit(),
          pos_unit()
        ) :: non_neg_integer() | error()
  defdelegate text_convert_pos(doc, container_id, index, from, to),
    to: Native,
    as: :text_convert_pos

  # ============================================================================
  # Cursor (stable positions)
  # ============================================================================

  @doc """
  Get a stable `Cursor` pointing at `pos` (Unicode) in a text container.

  Unlike a raw integer index, a Cursor survives concurrent edits.
  If someone inserts text *before* a cursor at position 7, resolving
  that cursor later yields a larger position — whatever the new index
  is after the insertion.

  `side` determines what happens when a new op lands *exactly at* the
  cursor's position:

    * `:left` — cursor stays to the left of the insertion
    * `:middle` (default) — Loro picks; matches most editor defaults
    * `:right` — cursor stays to the right of the insertion

  Returns an opaque binary. Persist, transmit, or store it; resolve
  with `cursor_resolve/2`.

  Returns `nil` if the doc's state makes a stable cursor impossible
  (rare; empty containers in some edge cases).

  ## Use cases

    * **Selection preservation across remote edits.** Convert the
      user's cursor/selection to a Cursor on every edit; convert back
      on every frame.
    * **Comment anchors.** A comment's "attached to text index 42"
      becomes "attached to this Cursor" — survives edits above.
    * **Bookmarks / deep links.** Persist the Cursor bytes as part of
      a URL or app state.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello world")

      # Remember where the caret was
      cursor = LoroEx.text_get_cursor(doc, "body", 6, :left)

      # Concurrent edit lands before the caret
      :ok = LoroEx.insert_text(doc, "body", 0, ">>> ")

      {pos, _side} = LoroEx.cursor_resolve(doc, cursor)
      # pos is now 10 (was 6 + 4 chars inserted)

  ## See also

    * `cursor_resolve/2` to convert back
    * `list_get_cursor/4` for list containers
  """
  @spec text_get_cursor(doc(), container_id(), non_neg_integer(), cursor_side()) ::
          cursor() | nil | error()
  def text_get_cursor(doc, container_id, pos, side \\ :middle) do
    Native.text_get_cursor(doc, container_id, pos, side)
  end

  @doc """
  Get a stable `Cursor` at `pos` in a list container.

  Same semantics as `text_get_cursor/4`: an opaque token that survives
  concurrent inserts/removes.

  Useful for "I'm currently highlighting item N of this list" when N
  might shift under you.
  """
  @spec list_get_cursor(doc(), container_id(), non_neg_integer(), cursor_side()) ::
          cursor() | nil | error()
  def list_get_cursor(doc, container_id, pos, side \\ :middle) do
    Native.list_get_cursor(doc, container_id, pos, side)
  end

  @doc """
  Resolve a `Cursor` to its current position in the doc.

  Returns `{pos, side_atom}`. `pos` is a Unicode codepoint index (for
  text cursors) or a list index.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "abcdef")

      cursor = LoroEx.text_get_cursor(doc, "body", 3, :middle)
      {3, :middle} = LoroEx.cursor_resolve(doc, cursor)

  ## Errors

    * `{:error, {:container_deleted, _}}` — the container the cursor
      pointed at was deleted on another peer.
    * `{:error, {:history_cleared, _}}` — the anchor op was garbage
      collected (usually because the doc was hydrated from a shallow
      snapshot that drops ops this cursor referenced).
    * `{:error, {:id_not_found, _}}` — the anchor op id isn't in the doc
      (you resolved a cursor against a different doc that hasn't
      synced yet).
    * `{:error, {:invalid_cursor, _}}` — the cursor bytes are corrupt.
  """
  @spec cursor_resolve(doc(), cursor()) ::
          {non_neg_integer(), cursor_side()} | error()
  defdelegate cursor_resolve(doc, cursor), to: Native

  # ============================================================================
  # Map
  # ============================================================================

  @doc """
  Return the contents of a map container as a JSON string.

  Kept as a string on purpose — decoding happens on the caller's
  schedule (outside the NIF), which keeps mutations cheap. Decode with
  `Jason.decode!/1` when you need it.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.map_set(doc, "settings", "theme", ~s("dark"))
      :ok = LoroEx.map_set(doc, "settings", "count", "14")

      LoroEx.get_map_json(doc, "settings")
      # => "{\\"count\\":14,\\"theme\\":\\"dark\\"}"

      LoroEx.get_map_json(doc, "settings") |> Jason.decode!()
      # => %{"count" => 14, "theme" => "dark"}
  """
  @spec get_map_json(doc(), container_id()) :: String.t() | error()
  defdelegate get_map_json(doc, container_id), to: Native

  @doc """
  Set `key` on a map container to the JSON-encoded scalar `value_json`.

  Only scalars are supported directly: `null`, `true`/`false`, numbers,
  strings. Objects and arrays return `{:error, {:invalid_value, _}}` —
  for nested structure use `map_insert_container/4`.

  The "value is a JSON string" is deliberate — it keeps the type
  boundary explicit. An Elixir number becomes `"42"`, a string becomes
  `~s("dark")` (the outer `~s(...)` quotes the JSON, the inner escaped
  quotes delimit the JSON string value).

  ## Examples

      doc = LoroEx.new()

      # Boolean
      :ok = LoroEx.map_set(doc, "settings", "dark_mode", "true")

      # Number
      :ok = LoroEx.map_set(doc, "settings", "font_size", "14")

      # String — note the inner quotes
      :ok = LoroEx.map_set(doc, "settings", "theme", ~s("dark"))

      # null
      :ok = LoroEx.map_set(doc, "settings", "last_opened", "null")

  ## Errors

    * `{:error, {:invalid_value, _}}` — `value_json` is an object or array

  ## See also

    * `map_insert_container/4` — nest a text/map/list/movable_list under a key
  """
  @spec map_set(doc(), container_id(), String.t(), String.t()) :: :ok | error()
  defdelegate map_set(doc, container_id, key, value_json), to: Native

  @doc """
  Delete `key` from a map container.

  Safe to call on a missing key — it's a no-op. Concurrent
  `delete` and `set` on the same key resolve via LWW (last-write-wins)
  per Loro's map semantics.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.map_set(doc, "settings", "theme", ~s("dark"))
      :ok = LoroEx.map_delete(doc, "settings", "theme")

      LoroEx.get_map_json(doc, "settings") |> Jason.decode!()
      # => %{}
  """
  @spec map_delete(doc(), container_id(), String.t()) :: :ok | error()
  defdelegate map_delete(doc, container_id, key), to: Native

  @doc """
  Return the value at `key` as a JSON string.

  Returns the literal string `"null"` if the key is missing or
  explicitly set to null. Decode with `Jason.decode!/1`.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.map_set(doc, "settings", "theme", ~s("dark"))

      LoroEx.map_get_json(doc, "settings", "theme")
      # => "\\"dark\\""

      LoroEx.map_get_json(doc, "settings", "missing")
      # => "null"
  """
  @spec map_get_json(doc(), container_id(), String.t()) :: String.t() | error()
  defdelegate map_get_json(doc, container_id, key), to: Native

  @doc """
  Insert a new, empty nested container under `key` in a map.

  `kind` is one of `:text | :map | :list | :movable_list`. Returns the
  new container's **serialized id** — pass it as `container_id` to any
  text/map/list/movable_list function to address the nested container.

  ## Use cases

    * Structured data inside a map: settings with nested groups,
      comments with nested reply threads.
    * "Block with content" patterns: a tree node's metadata map
      holding a text container with the block's body.

  ## Example

      doc = LoroEx.new()

      # Create a nested map for appearance settings
      appearance = LoroEx.map_insert_container(doc, "settings", "appearance", :map)

      # Write into the nested map using its returned id
      :ok = LoroEx.map_set(doc, appearance, "theme", ~s("dark"))
      :ok = LoroEx.map_set(doc, appearance, "density", ~s("compact"))

      # The parent reflects the structure
      LoroEx.get_map_json(doc, "settings") |> Jason.decode!()
      # => %{"appearance" => %{"theme" => "dark", "density" => "compact"}}

  ## See also

    * `list_insert_container/4`
    * `tree_get_meta/3`
  """
  @spec map_insert_container(doc(), container_id(), String.t(), container_kind()) ::
          container_id() | error()
  defdelegate map_insert_container(doc, container_id, key, kind), to: Native

  # ============================================================================
  # List
  # ============================================================================

  @doc """
  Return the contents of a list container as a JSON string.

  Decode with `Jason.decode!/1`. Kept as a string for the same reasons
  as `get_map_json/2`.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "events", ~s("login"))
      :ok = LoroEx.list_push(doc, "events", ~s("edit"))

      LoroEx.list_get_json(doc, "events") |> Jason.decode!()
      # => ["login", "edit"]
  """
  @spec list_get_json(doc(), container_id()) :: String.t() | error()
  defdelegate list_get_json(doc, container_id), to: Native

  @doc """
  Append a JSON scalar to a list container.

  Same scalar-only rules as `map_set/4`. Use
  `list_insert_container/4` for nested structure.

  ## Examples

      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "events", ~s("login"))
      :ok = LoroEx.list_push(doc, "counters", "42")
      :ok = LoroEx.list_push(doc, "flags", "true")

  ## Errors

    * `{:error, {:invalid_value, _}}` — object or array, not a scalar
  """
  @spec list_push(doc(), container_id(), String.t()) :: :ok | error()
  defdelegate list_push(doc, container_id, value_json), to: Native

  @doc """
  Delete `len` elements starting at `index` from a list container.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "events", ~s("login"))
      :ok = LoroEx.list_push(doc, "events", ~s("edit"))
      :ok = LoroEx.list_push(doc, "events", ~s("logout"))

      # Remove the middle element
      :ok = LoroEx.list_delete(doc, "events", 1, 1)

      LoroEx.list_get_json(doc, "events") |> Jason.decode!()
      # => ["login", "logout"]
  """
  @spec list_delete(doc(), container_id(), non_neg_integer(), non_neg_integer()) ::
          :ok | error()
  defdelegate list_delete(doc, container_id, index, len), to: Native

  @doc """
  Insert a nested container at `pos` in a list. Symmetric with
  `map_insert_container/4`; returns the new container's serialized id.

  Useful for block-style editors where each list element is a
  container (text block, tree block, …).

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "blocks", ~s("heading"))

      # Insert a text container as the second item
      body_cid = LoroEx.list_insert_container(doc, "blocks", 1, :text)
      :ok = LoroEx.insert_text(doc, body_cid, 0, "Block content")

      LoroEx.get_text(doc, body_cid)
      # => "Block content"
  """
  @spec list_insert_container(
          doc(),
          container_id(),
          non_neg_integer(),
          container_kind()
        ) :: container_id() | error()
  defdelegate list_insert_container(doc, container_id, pos, kind), to: Native

  # ============================================================================
  # Tree (movable)
  # ============================================================================

  @doc """
  Create a new node under `parent_id` (or at the root if `parent_id` is
  `nil`). Returns the new node's TreeID as a string.

  Loro's tree is a *movable* tree: the CRDT guarantees no cycles and a
  deterministic conflict winner when two peers concurrently move
  nodes. Perfect for Notion-style nested blocks, file trees, outliners.

  ## Example

      doc = LoroEx.new()

      page = LoroEx.tree_create_node(doc, "blocks", nil)
      intro = LoroEx.tree_create_node(doc, "blocks", page)
      body  = LoroEx.tree_create_node(doc, "blocks", page)

  ## See also

    * `tree_move_node/5` — reorder nodes
    * `tree_get_meta/3` — attach metadata to a node
  """
  @spec tree_create_node(doc(), container_id(), String.t() | nil) ::
          String.t() | error()
  defdelegate tree_create_node(doc, tree_id, parent_id \\ nil), to: Native

  @doc """
  Move a node to become a child of `new_parent_id` at position
  `index`.

  Use `nil` for `new_parent_id` to move a node to the top level.
  Concurrent moves from different peers are resolved without cycles
  and without losing any node.

  ## Example

      doc = LoroEx.new()
      a = LoroEx.tree_create_node(doc, "blocks", nil)
      b = LoroEx.tree_create_node(doc, "blocks", nil)

      # Move b under a, at position 0
      :ok = LoroEx.tree_move_node(doc, "blocks", b, a, 0)

  ## Errors

    * `{:error, {:cyclic_move, _}}` — attempted to move a node under
      one of its own descendants (the CRDT normally prevents this
      automatically by canceling the lower-priority op; this error
      surfaces only if you're moving within a single peer).
    * `{:error, {:tree_node_not_found, _}}` — target or parent doesn't exist
    * `{:error, {:index_out_of_bound, _}}` — `index` > sibling count
    * `{:error, {:invalid_tree_id, _}}` — malformed node id
  """
  @spec tree_move_node(
          doc(),
          container_id(),
          String.t(),
          String.t() | nil,
          non_neg_integer()
        ) :: :ok | error()
  defdelegate tree_move_node(doc, tree_id, node_id, new_parent_id, index), to: Native

  @doc """
  Delete a node (and all its descendants) from the tree.

  The op remains in the oplog for convergence, but the node is gone
  from the visible state. Concurrent-with-move is handled per Loro's
  tree rules (delete wins).

  ## Example

      doc = LoroEx.new()
      node = LoroEx.tree_create_node(doc, "blocks", nil)
      :ok = LoroEx.tree_delete_node(doc, "blocks", node)
  """
  @spec tree_delete_node(doc(), container_id(), String.t()) :: :ok | error()
  defdelegate tree_delete_node(doc, tree_id, node_id), to: Native

  @doc """
  Return the tree as a JSON string describing every live node with
  their parent/index relationships.

  Decode with `Jason.decode!/1`. The shape is roughly:

      [%{"id" => "…", "parent" => "…" | nil, "index" => n, …}, …]

  ## Example

      doc = LoroEx.new()
      _ = LoroEx.tree_create_node(doc, "blocks", nil)

      LoroEx.tree_get_nodes(doc, "blocks") |> Jason.decode!()
      # => [%{"id" => "...", "parent" => nil, "index" => 0, ...}]

  ## See also

    * For per-node children/parent queries, use `tree_get_meta/3` to
      store your own adjacency info, or parse this JSON output. A
      first-class `children/2` NIF is on the roadmap.
  """
  @spec tree_get_nodes(doc(), container_id()) :: String.t() | error()
  defdelegate tree_get_nodes(doc, tree_id), to: Native

  @doc """
  Return the container id of the metadata map attached to a tree node.

  Each tree node has a dedicated `LoroMap` for metadata. This is how
  you store per-node data: title, icon, block kind, custom properties.

  ## Example

      doc = LoroEx.new()
      page = LoroEx.tree_create_node(doc, "blocks", nil)

      meta = LoroEx.tree_get_meta(doc, "blocks", page)
      :ok = LoroEx.map_set(doc, meta, "title", ~s("My page"))
      :ok = LoroEx.map_set(doc, meta, "icon", ~s("📄"))
      :ok = LoroEx.map_set(doc, meta, "kind", ~s("document"))

      LoroEx.get_map_json(doc, meta) |> Jason.decode!()
      # => %{"title" => "My page", "icon" => "📄", "kind" => "document"}

  ## Errors

    * `{:error, {:tree_node_not_found, _}}` — the node doesn't exist.
  """
  @spec tree_get_meta(doc(), container_id(), String.t()) :: container_id() | error()
  defdelegate tree_get_meta(doc, tree_id, node_id), to: Native

  # ============================================================================
  # Subscriptions (local-update bytes)
  # ============================================================================

  @doc """
  Subscribe `pid` to raw local-update bytes for this doc.

  After every local commit, the subscribed pid receives:

      {:loro_event, subscription_ref, update_bytes}

  `update_bytes` is ready to feed into `apply_update/2` on a peer
  doc — no post-processing needed.

  ## Use cases

    * **Server-side broadcast.** A GenServer owns the doc, subscribes
      itself, and broadcasts the bytes to connected clients via
      `Phoenix.PubSub` or similar.
    * **Live mirroring.** A mirror doc subscribes to the source and
      applies every event — useful for keeping a read-only replica
      in another process.

  ## Re-entrancy warning

  The callback runs inside Loro's commit path. Inside Rust we only do
  a `send` to your pid, so there's no deadlock risk from the NIF
  side. **But**: if your process handles `{:loro_event, _, _}` by
  calling back into LoroEx on the SAME doc via a GenServer call, and
  that GenServer is the one that just committed, you'll deadlock your
  own supervisor tree. Always handle events asynchronously — `cast`,
  broadcast to another topic, or spawn a task.

  ## Example

      doc = LoroEx.new()
      sub = LoroEx.subscribe(doc, self())

      :ok = LoroEx.insert_text(doc, "body", 0, "hello")

      receive do
        {:loro_event, ^sub, bytes} ->
          mirror = LoroEx.new()
          :ok = LoroEx.apply_update(mirror, bytes)
      end

  ## See also

    * `unsubscribe/1` — eagerly cancel
    * `subscribe_container/3` — structured diffs instead of raw bytes
    * `subscribe_root/2` — structured diffs across the whole doc
  """
  @spec subscribe(doc(), pid()) :: subscription() | error()
  defdelegate subscribe(doc, pid), to: Native

  @doc """
  Cancel a subscription eagerly.

  Safe to call more than once; second call is a no-op. **You must call
  this to cancel a subscription** — the current implementation has a
  reference cycle between the subscription handle and its delivery
  closure, so dropping the handle without calling `unsubscribe/1`
  keeps the subscription (and its closure, and its captured doc
  reference) alive until the BEAM process exits.

  This is a known limitation; a fix using a global subscription
  registry is planned for 0.5.1. For now, treat subscriptions like
  ETS tables: always pair every `subscribe/2` with an `unsubscribe/1`
  on shutdown.

  ## Example

      doc = LoroEx.new()
      sub = LoroEx.subscribe(doc, self())
      :ok = LoroEx.unsubscribe(sub)
  """
  @spec unsubscribe(subscription()) :: :ok | error()
  defdelegate unsubscribe(sub), to: Native

  @doc """
  Subscribe `pid` to **structured diff events** for a specific
  container.

  After every commit that affects the container, the pid receives:

      {:loro_diff, subscription_ref, events_json_binary}

  `events_json_binary` is JSON (decode with `Jason.decode!/1`). Each
  element in the decoded array has shape:

      %{
        "target" => "<container_id>",
        "path"   => [[parent_cid, key_or_index], ...],
        "diff"   => %{"type" => "text" | "map" | "list" | "tree" | ..., ...}
      }

  For text diffs, `diff.ops` is a Quill delta (same format as
  `text_to_delta/2`). For map diffs, `diff.updated` is a map of
  changed keys → new values. For list diffs, `diff.ops` is a list of
  insert/delete/retain items. For tree diffs, `diff.diff` is a list
  of create/move/delete actions.

  ## Use cases

    * **Editor integration.** Have your editor component subscribe to
      its text container; each diff event maps 1:1 to an editor
      operation (Quill delta → editor, tree diff → block layout).
    * **Search indexing.** Subscribe a worker process to the doc's
      text containers; reindex incrementally on each diff.

  ## Example

      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "x")
      sub = LoroEx.subscribe_container(doc, "body", self())

      :ok = LoroEx.insert_text(doc, "body", 1, "y")

      receive do
        {:loro_diff, ^sub, json} ->
          events = Jason.decode!(json)
          # => [%{"target" => "cid:root-body:Text", "path" => [], "diff" => %{...}}]
      end

  ## Container addressing

  `container_id` can be a root-name string ("body") or a serialized
  ContainerID (from `map_insert_container/4` etc.) — both work.
  """
  @spec subscribe_container(doc(), container_id(), pid()) :: subscription() | error()
  defdelegate subscribe_container(doc, container_id, pid), to: Native

  @doc """
  Subscribe `pid` to structured diff events across **every** container
  in the doc.

  Same message shape as `subscribe_container/3`: a single JSON payload
  per commit, containing diffs for all affected containers.

  ## Use cases

    * **Audit log.** Record every change with its container path and
      diff shape.
    * **Server broadcast** when clients apply structured diffs rather
      than raw bytes.
    * **Persistence hooks.** Write-through cache that flushes to disk
      on every doc change.

  ## Example

      doc = LoroEx.new()
      _sub = LoroEx.subscribe_root(doc, self())

      :ok = LoroEx.insert_text(doc, "body", 0, "hi")

      receive do
        {:loro_diff, _sub, json} ->
          events = Jason.decode!(json)
          # events is a list of per-container diffs
      end
  """
  @spec subscribe_root(doc(), pid()) :: subscription() | error()
  defdelegate subscribe_root(doc, pid), to: Native

  # ============================================================================
  # Submodules
  # ============================================================================

  defmodule UndoManager do
    @moduledoc """
    Per-peer undo/redo for a `LoroEx` doc.

    `UndoManager` is how you implement the `Ctrl+Z` / `Ctrl+Shift+Z`
    pair in a collaborative editor. It's **local-only**: undoing
    rewinds operations made by *this doc's current peer*, not remote
    edits from other users. That's the right semantics for an editor —
    "undo my last action" should never surprise me by reverting my
    collaborator's work.

    For *global* rollback across all peers, use time-travel APIs
    (`checkout`, `revert_to`) — not yet exposed in LoroEx.

    ## Important invariants

    **Peer identity must be stable.** The manager is bound to the
    doc's current peer id at construction. If you change the doc's
    peer id (via `set_peer_id`, not yet exposed), the manager loses
    track of what's undoable. For this reason, always pair
    `UndoManager` with a deterministic peer id — create the doc with
    `LoroEx.new/1`, not `LoroEx.new/0`.

    ## Checkpoints and grouping

    By default, every local commit produces a separate undo step.
    Call `record_new_checkpoint/1` to force a boundary, or use
    `set_merge_interval/2` to bundle fast successive edits into one
    step (common for typing — you want `Ctrl+Z` to undo a whole word,
    not one character at a time).

    ## Example

        doc = LoroEx.new(1)
        undo = LoroEx.UndoManager.new(doc)

        :ok = LoroEx.insert_text(doc, "body", 0, "hello")
        :ok = LoroEx.UndoManager.record_new_checkpoint(undo)

        :ok = LoroEx.insert_text(doc, "body", 5, " world")
        :ok = LoroEx.UndoManager.record_new_checkpoint(undo)

        true = LoroEx.UndoManager.can_undo(undo)
        true = LoroEx.UndoManager.undo(undo)
        LoroEx.get_text(doc, "body")  # => "hello"

        true = LoroEx.UndoManager.redo(undo)
        LoroEx.get_text(doc, "body")  # => "hello world"

    See the [Undo guide](guides/undo.md) for patterns (typing groups,
    selection restoration, integration with `subscribe_root/2`).
    """

    alias LoroEx.Native

    @typedoc "Opaque undo manager handle."
    @type t :: reference()

    @doc """
    Create a new undo manager bound to `doc`.

    Captures the doc's peer id; don't change it afterwards. Default
    max undo steps is 100 — override with `set_max_undo_steps/2`.

    ## Example

        doc = LoroEx.new(1)
        undo = LoroEx.UndoManager.new(doc)
    """
    @spec new(LoroEx.doc()) :: t()
    defdelegate new(doc), to: Native, as: :undo_manager_new

    @doc """
    Step back to the previous checkpoint. Returns `true` if a step
    was taken, `false` if there's nothing to undo.

    Only affects local ops from the bound peer. Remote edits (imported
    via `apply_update/2`) are never undone.

    ## Example

        :ok = LoroEx.insert_text(doc, "body", 0, "hello")
        :ok = LoroEx.UndoManager.record_new_checkpoint(undo)

        true = LoroEx.UndoManager.undo(undo)  # steps back
        false = LoroEx.UndoManager.undo(undo) # nothing more to undo
    """
    @spec undo(t()) :: boolean() | LoroEx.error()
    defdelegate undo(mgr), to: Native, as: :undo_manager_undo

    @doc """
    Step forward after an undo. Returns `true` if a step was taken,
    `false` if the redo stack is empty.

    Making a new edit after an undo clears the redo stack — matches
    standard editor behavior.
    """
    @spec redo(t()) :: boolean() | LoroEx.error()
    defdelegate redo(mgr), to: Native, as: :undo_manager_redo

    @doc """
    Whether `undo/1` has anything to undo.

    Wire this to your "Undo" button's enabled state. Calling before
    any local commits returns `false`.
    """
    @spec can_undo(t()) :: boolean()
    defdelegate can_undo(mgr), to: Native, as: :undo_manager_can_undo

    @doc """
    Whether `redo/1` has anything to redo.

    Wire this to your "Redo" button's enabled state. Always `false`
    after a new edit, which clears the redo stack.
    """
    @spec can_redo(t()) :: boolean()
    defdelegate can_redo(mgr), to: Native, as: :undo_manager_can_redo

    @doc """
    Force a checkpoint boundary between the previous edit and the
    next.

    Without this call (or `set_merge_interval/2`) every commit is its
    own undo step, which is too granular for typing. Typical usage: a
    debounced idle timer calls `record_new_checkpoint/1` after N
    milliseconds of no edits.

    ## Example

        :ok = LoroEx.insert_text(doc, "body", 0, "h")
        :ok = LoroEx.insert_text(doc, "body", 1, "i")
        :ok = LoroEx.UndoManager.record_new_checkpoint(undo)
        # ^ "hi" is now one undo step

        :ok = LoroEx.insert_text(doc, "body", 2, "!")
        :ok = LoroEx.UndoManager.record_new_checkpoint(undo)
        # ^ "!" is the second undo step
    """
    @spec record_new_checkpoint(t()) :: :ok | LoroEx.error()
    defdelegate record_new_checkpoint(mgr), to: Native, as: :undo_manager_record_new_checkpoint

    @doc """
    Cap the undo history at `size` steps. Default is 100.

    Older steps are discarded FIFO as new ones come in. Higher values
    cost more memory (each step retains its diff for replay).

    ## Example

        :ok = LoroEx.UndoManager.set_max_undo_steps(undo, 500)
    """
    @spec set_max_undo_steps(t(), non_neg_integer()) :: :ok
    defdelegate set_max_undo_steps(mgr, size), to: Native, as: :undo_manager_set_max_undo_steps

    @doc """
    Merge successive edits within `interval_ms` into a single undo
    step. Default is 0 (each commit is its own step).

    For typing, 500–1000ms is typical. For discrete operations
    (click-to-insert, paste), keep at 0 so each is undone separately.

    ## Example

        # Merge keystrokes within 1 second into one undo step
        :ok = LoroEx.UndoManager.set_merge_interval(undo, 1000)
    """
    @spec set_merge_interval(t(), integer()) :: :ok
    defdelegate set_merge_interval(mgr, ms), to: Native, as: :undo_manager_set_merge_interval
  end

  defmodule Presence do
    @moduledoc """
    Ephemeral, CRDT-less presence state for multi-user apps.

    `Presence` wraps Loro's `EphemeralStore`. It's how you ship
    "who's here and where are they looking" state between peers —
    cursor positions, selections, "is typing" flags, display
    names, colors. Everything that doesn't belong in the persistent
    document.

    ## Not a CRDT

    Presence is **last-write-wins per key with TTLs**. No merge logic,
    no causal history. Two peers writing the same key at the same
    time: whoever's `apply/2` runs last wins. Keys time out after the
    store's TTL. This is the right trade-off for presence — you don't
    want to merge "I'm at position 7" with "I'm at position 42".

    For persistent collaborative state use the main doc API
    (`LoroEx.map_set/4` etc).

    ## Keys you set locally vs keys you receive from peers

    Use **namespaced keys**: prefix with a stable per-peer id so two
    peers never collide.

        LoroEx.Presence.set(pres, "alice/cursor", %{"pos" => 7})
        LoroEx.Presence.set(pres, "alice/color", "#ff00aa")
        # bob's key: "bob/cursor"
        # charlie's key: "charlie/cursor"

    ## Wire protocol

    `encode_all/1` produces bytes for your *local* entries. Ship to
    peers. Each peer calls `apply/2`. To get updates pushed in
    real time, combine with `subscribe/2` — the callback delivers
    bytes on every local `set`/`delete`.

    ## Example — full cycle

        # Process A
        alice = LoroEx.Presence.new(30_000)
        :ok = LoroEx.Presence.set(alice, "alice/cursor", %{"pos" => 7})

        # Ship `encode_all` to Process B
        payload = LoroEx.Presence.encode_all(alice)

        # Process B
        bob = LoroEx.Presence.new(30_000)
        :ok = LoroEx.Presence.apply(bob, payload)

        LoroEx.Presence.get(bob, "alice/cursor")
        # => %{"pos" => 7}

    See the [Presence & cursors guide](guides/presence_and_cursors.md)
    for the GenServer pattern, TTL management, and integration with
    stable cursors.
    """

    alias LoroEx.Native

    @typedoc "Opaque presence store handle."
    @type t :: reference()

    @doc """
    Create a new presence store with an inactivity `timeout_ms`.

    Keys that don't receive an update within the timeout are pruned
    by `remove_outdated/1` and skipped on `encode_all/1`. Typical
    value: 30_000 (30 seconds) — long enough to survive a tab
    switch, short enough that stale cursors disappear.

    ## Example

        pres = LoroEx.Presence.new(30_000)
    """
    @spec new(integer()) :: t()
    defdelegate new(timeout_ms), to: Native, as: :ephemeral_new

    @doc """
    Set `key` to `value`, a JSON-encodable Elixir term.

    Scalars (number/string/bool/nil) round-trip natively. Maps and
    lists are stored as JSON strings and unwrapped transparently by
    `get/2` — as a caller you don't need to know which is which.

    ## Examples

        pres = LoroEx.Presence.new(30_000)

        :ok = LoroEx.Presence.set(pres, "alice/cursor", %{"pos" => 7, "len" => 3})
        :ok = LoroEx.Presence.set(pres, "alice/color", "#ff00aa")
        :ok = LoroEx.Presence.set(pres, "alice/typing", true)
    """
    @spec set(t(), String.t(), term()) :: :ok | LoroEx.error()
    def set(store, key, value) do
      json = Jason.encode!(value)

      case value do
        v when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v) ->
          Native.ephemeral_set(store, key, json)

        _ ->
          Native.ephemeral_set(store, key, Jason.encode!(json))
      end
    end

    @doc """
    Get a key, decoding its stored value back to the Elixir term that
    was set.

    Returns `nil` if the key doesn't exist or has expired.

    ## Example

        :ok = LoroEx.Presence.set(pres, "alice/cursor", %{"pos" => 7})
        LoroEx.Presence.get(pres, "alice/cursor")
        # => %{"pos" => 7}

        LoroEx.Presence.get(pres, "missing")
        # => nil
    """
    @spec get(t(), String.t()) :: term()
    def get(store, key) do
      case Native.ephemeral_get(store, key) do
        {:error, _} = e -> e
        json when is_binary(json) -> decode_scalar_or_embedded(json)
      end
    end

    @doc """
    Delete a key locally and notify subscribers.

    Peers that receive the encoded deletion via `apply/2` get the
    key removed from their side too.

    ## Example

        :ok = LoroEx.Presence.set(pres, "alice/cursor", %{"pos" => 7})
        :ok = LoroEx.Presence.delete(pres, "alice/cursor")
        LoroEx.Presence.get(pres, "alice/cursor")
        # => nil
    """
    @spec delete(t(), String.t()) :: :ok
    defdelegate delete(store, key), to: Native, as: :ephemeral_delete

    @doc """
    List all currently-held keys (including expired ones, until
    `remove_outdated/1` is called).

    ## Example

        :ok = LoroEx.Presence.set(pres, "alice/cursor", 7)
        :ok = LoroEx.Presence.set(pres, "bob/cursor", 12)
        LoroEx.Presence.keys(pres) |> Enum.sort()
        # => ["alice/cursor", "bob/cursor"]
    """
    @spec keys(t()) :: [String.t()]
    defdelegate keys(store), to: Native, as: :ephemeral_keys

    @doc """
    Return every key/value pair as a decoded Elixir map.

    ## Example

        :ok = LoroEx.Presence.set(pres, "alice/cursor", %{"pos" => 7})
        :ok = LoroEx.Presence.set(pres, "bob/color", "#00ff00")

        LoroEx.Presence.get_all_states(pres)
        # => %{"alice/cursor" => ..., "bob/color" => "#00ff00"}
    """
    @spec get_all_states(t()) :: map()
    def get_all_states(store) do
      case Native.ephemeral_get_all_states(store) do
        {:error, _} = e -> e
        json when is_binary(json) -> Jason.decode!(json)
      end
    end

    @doc """
    Encode a single key's current value for transmission to peers.

    Smaller than `encode_all/1` when you want to send just-changed
    state. Both produce wire-compatible payloads for `apply/2`.
    """
    @spec encode(t(), String.t()) :: binary()
    defdelegate encode(store, key), to: Native, as: :ephemeral_encode

    @doc """
    Encode all non-expired keys for transmission to peers.

    Use this as the "hello, here's my state" payload when a new peer
    joins, and for catch-up sync. For continuous updates pair with
    `subscribe/2` which delivers incremental bytes.

    ## Example

        payload = LoroEx.Presence.encode_all(pres)
        Phoenix.PubSub.broadcast(MyApp.PubSub, "doc:42:presence", payload)
    """
    @spec encode_all(t()) :: binary()
    defdelegate encode_all(store), to: Native, as: :ephemeral_encode_all

    @doc """
    Apply a wire payload from `encode/2` or `encode_all/1` to this
    store. Merges remote state into local.

    ## Errors

      * `{:error, {:ephemeral_apply_failed, _}}` — payload corrupt or
        from an incompatible version.
    """
    @spec apply(t(), binary()) :: :ok | LoroEx.error()
    defdelegate apply(store, bytes), to: Native, as: :ephemeral_apply

    @doc """
    Remove keys whose last update is past the TTL configured in `new/1`.

    Triggers a subscription event with `by = :timeout` for the removed
    keys. Call on a timer (e.g. every few seconds) — it doesn't run
    automatically.

    ## Example

        # Periodic cleanup
        Process.send_after(self(), :gc_presence, 5_000)
        # ...
        def handle_info(:gc_presence, state) do
          :ok = LoroEx.Presence.remove_outdated(state.pres)
          Process.send_after(self(), :gc_presence, 5_000)
          {:noreply, state}
        end
    """
    @spec remove_outdated(t()) :: :ok
    defdelegate remove_outdated(store), to: Native, as: :ephemeral_remove_outdated

    @doc """
    Subscribe `pid` to local update bytes.

    After each local `set/3` or `delete/2`, the pid receives:

        {:loro_ephemeral, subscription_ref, update_bytes}

    `update_bytes` is ready to pass to `apply/2` on a peer store — no
    post-processing needed. This is the push-based counterpart to
    `encode_all/1` + polling.

    ## Use case

    The GenServer owning the store subscribes itself, then broadcasts
    on every event:

        def init(_) do
          pres = LoroEx.Presence.new(30_000)
          _sub = LoroEx.Presence.subscribe(pres, self())
          {:ok, %{pres: pres}}
        end

        def handle_info({:loro_ephemeral, _sub, bytes}, state) do
          Phoenix.PubSub.broadcast(MyApp.PubSub, topic(), {:presence, bytes})
          {:noreply, state}
        end
    """
    @spec subscribe(t(), pid()) :: LoroEx.subscription()
    defdelegate subscribe(store, pid), to: Native, as: :ephemeral_subscribe

    defp decode_scalar_or_embedded(json) do
      case Jason.decode(json) do
        {:ok, v} when is_binary(v) ->
          case Jason.decode(v) do
            {:ok, inner} -> inner
            _ -> v
          end

        {:ok, v} ->
          v

        _ ->
          json
      end
    end
  end
end
