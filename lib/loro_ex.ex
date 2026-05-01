defmodule LoroEx do
  @moduledoc """
  Elixir bindings to the [Loro](https://loro.dev) CRDT library.

  `LoroEx` is a thin, friendly wrapper over `LoroEx.Native`. The wrapper
  exists mostly to give good specs and docs; the heavy lifting happens in
  the NIF.

  ## Quick start

      iex> doc = LoroEx.new()
      iex> :ok = LoroEx.insert_text(doc, "body", 0, "hello")
      iex> LoroEx.get_text(doc, "body")
      "hello"

  ## Concurrency model

  `LoroDoc` handles are safe to pass between Elixir processes but are NOT
  safe for concurrent mutation — every NIF call acquires an internal mutex.
  The expected usage is: one GenServer per doc guards a handle, and all
  mutations funnel through that GenServer's mailbox.

  ## Error handling

  All fallible calls return either their normal value (e.g. `:ok`, a
  binary, a string) or `{:error, {reason, detail}}` where `reason` is a
  stable atom. Common reasons:

    * `:invalid_update` — the update bytes are corrupt or from an
      incompatible version of Loro.
    * `:invalid_version_vector` — the given version vector failed to
      decode. You probably mixed `oplog_version/1` and `state_vector/1`,
      or corrupted the bytes in transit.
    * `:invalid_frontier` — frontier bytes failed to decode.
    * `:invalid_tree_id` — tree node id string is not a valid `TreeID`.
    * `:invalid_value` — JSON scalar expected but got an object, array,
      or out-of-range number. Returned by `map_set/4`, `list_push/3`.
    * `:checksum_mismatch` — update bytes had a bad checksum.
    * `:incompatible_version` — encoding version from a newer Loro.
    * `:not_found` — container or frontier not in the doc.
    * `:out_of_bound` — text position outside the container.
    * `:cyclic_move` — attempted to move a tree node under its own
      descendant.
    * `:tree_node_not_found` — tree node id not in the doc, or its
      parent is missing.
    * `:fractional_index_not_enabled` — should not happen; LoroEx
      enables fractional indices on every tree it touches.
    * `:index_out_of_bound` — child index beyond the sibling count.
    * `:container_deleted` — target container was deleted by a remote
      op; retry after reconciling.
    * `:lock_poisoned` — internal mutex was poisoned by a prior panic.
      The doc is unusable; drop it and rehydrate from a snapshot.
    * `:unknown` — anything not covered above. `detail` has the raw
      Loro debug string.
  """

  alias LoroEx.Native

  @typedoc "Opaque handle to a Loro document."
  @type doc :: reference()
  @typedoc "Opaque handle to an active local-update subscription."
  @type subscription :: reference()
  @type version :: binary()
  @type frontier :: binary()
  @type container_id :: String.t()
  @type error_reason ::
          :invalid_update
          | :invalid_version_vector
          | :invalid_frontier
          | :invalid_tree_id
          | :invalid_peer_id
          | :invalid_value
          | :checksum_mismatch
          | :incompatible_version
          | :not_found
          | :out_of_bound
          | :cyclic_move
          | :tree_node_not_found
          | :fractional_index_not_enabled
          | :index_out_of_bound
          | :container_deleted
          | :lock_poisoned
          | :unknown
  @type error :: {:error, {error_reason(), String.t()}}

  # Lifecycle -----------------------------------------------------------------

  @doc "Create a new empty document with a random peer id."
  @spec new() :: doc()
  defdelegate new(), to: Native, as: :new_doc

  @doc """
  Create a new document with an explicit peer id.

  Use a deterministic peer id for server-side docs so repeated hydrate /
  edit cycles don't churn the oplog with new peers. A good pattern is
  `:erlang.phash2({node(), doc_id})`.
  """
  @spec new(non_neg_integer()) :: doc() | error()
  defdelegate new(peer_id), to: Native, as: :new_doc_with_peer

  # Sync ----------------------------------------------------------------------

  @doc """
  Apply a remote update (snapshot or delta) to the document.

  The bytes must have been produced by `export_snapshot/1`,
  `export_updates/2`, or a subscription's `{:loro_event, _, bytes}`.
  """
  @spec apply_update(doc(), binary()) :: :ok | error()
  defdelegate apply_update(doc, bytes), to: Native

  @doc "Export the entire document state as a self-contained snapshot."
  @spec export_snapshot(doc()) :: binary() | error()
  defdelegate export_snapshot(doc), to: Native

  @doc """
  Export a shallow snapshot trimmed to the given frontier.

  Useful for new joiners who don't need the full op history.
  """
  @spec export_shallow_snapshot(doc(), frontier()) :: binary() | error()
  defdelegate export_shallow_snapshot(doc, frontier), to: Native

  @doc "Export the incremental updates since `version`."
  @spec export_updates(doc(), version()) :: binary() | error()
  defdelegate export_updates(doc, version), to: Native, as: :export_updates_from

  @doc "Return the opaque oplog version vector for this document."
  @spec oplog_version(doc()) :: version() | error()
  defdelegate oplog_version(doc), to: Native

  @doc "Return the opaque state version vector for this document."
  @spec state_vector(doc()) :: version() | error()
  defdelegate state_vector(doc), to: Native

  @doc """
  Return the opaque op-log **frontier** for this document. Distinct
  from `oplog_version/1` — a frontier is a set of op ids, not a
  per-peer counter map. Use this with
  `export_shallow_snapshot/2`.
  """
  @spec oplog_frontiers(doc()) :: frontier() | error()
  defdelegate oplog_frontiers(doc), to: Native

  @doc "State frontier. May lag `oplog_frontiers/1` when commits are pending."
  @spec state_frontiers(doc()) :: frontier() | error()
  defdelegate state_frontiers(doc), to: Native

  @doc """
  Frontier at which a shallow snapshot's history is truncated. Useful
  for detecting whether a doc was hydrated from a shallow snapshot
  and, if so, where its baseline begins.
  """
  @spec shallow_since_frontiers(doc()) :: frontier() | error()
  defdelegate shallow_since_frontiers(doc), to: Native

  # Text ----------------------------------------------------------------------

  @spec get_text(doc(), container_id()) :: String.t() | error()
  defdelegate get_text(doc, container_id), to: Native

  @spec insert_text(doc(), container_id(), non_neg_integer(), String.t()) ::
          :ok | error()
  defdelegate insert_text(doc, container_id, pos, value), to: Native

  @spec delete_text(doc(), container_id(), non_neg_integer(), non_neg_integer()) ::
          :ok | error()
  defdelegate delete_text(doc, container_id, pos, len), to: Native

  # Map -----------------------------------------------------------------------

  @doc """
  Return the contents of a map container as a JSON string.

  Kept as a string on purpose: decoding happens on the caller's schedule,
  not inside the NIF.
  """
  @spec get_map_json(doc(), container_id()) :: String.t() | error()
  defdelegate get_map_json(doc, container_id), to: Native

  @doc """
  Set `key` on the map container `container_id` to the JSON-encoded scalar
  `value_json`.

  Only scalars are accepted: `null`, `true` / `false`, numbers, strings.
  Objects and arrays return `{:error, {:invalid_value, _}}` — use
  dedicated container-init APIs for nested structure (not yet exposed).

  ## Examples

      LoroEx.map_set(doc, "comments", "c1", ~s("{\\"body\\":\\"hi\\"}"))  # value is a JSON string
      LoroEx.map_set(doc, "settings", "theme", ~s("\\"dark\\""))          # string
      LoroEx.map_set(doc, "settings", "count", "3")                      # number
  """
  @spec map_set(doc(), container_id(), String.t(), String.t()) :: :ok | error()
  defdelegate map_set(doc, container_id, key, value_json), to: Native

  @doc "Delete `key` from the map container `container_id`."
  @spec map_delete(doc(), container_id(), String.t()) :: :ok | error()
  defdelegate map_delete(doc, container_id, key), to: Native

  @doc """
  Return the value at `key` in the map container `container_id` as a JSON
  string. Returns `"null"` if the key doesn't exist.
  """
  @spec map_get_json(doc(), container_id(), String.t()) :: String.t() | error()
  defdelegate map_get_json(doc, container_id, key), to: Native

  # List ----------------------------------------------------------------------

  @doc """
  Return the contents of a list container as a JSON string.
  """
  @spec list_get_json(doc(), container_id()) :: String.t() | error()
  defdelegate list_get_json(doc, container_id), to: Native

  @doc """
  Append `value_json` to the list container `container_id`. Scalar-only
  rules identical to `map_set/4`.
  """
  @spec list_push(doc(), container_id(), String.t()) :: :ok | error()
  defdelegate list_push(doc, container_id, value_json), to: Native

  @doc """
  Delete `len` elements starting at `index` from the list container.
  """
  @spec list_delete(doc(), container_id(), non_neg_integer(), non_neg_integer()) ::
          :ok | error()
  defdelegate list_delete(doc, container_id, index, len), to: Native

  # Tree ----------------------------------------------------------------------

  @spec tree_create_node(doc(), container_id(), String.t() | nil) ::
          String.t() | error()
  defdelegate tree_create_node(doc, tree_id, parent_id \\ nil), to: Native

  @spec tree_move_node(
          doc(),
          container_id(),
          String.t(),
          String.t() | nil,
          non_neg_integer()
        ) :: :ok | error()
  defdelegate tree_move_node(doc, tree_id, node_id, new_parent_id, index), to: Native

  @spec tree_delete_node(doc(), container_id(), String.t()) :: :ok | error()
  defdelegate tree_delete_node(doc, tree_id, node_id), to: Native

  @spec tree_get_nodes(doc(), container_id()) :: String.t() | error()
  defdelegate tree_get_nodes(doc, tree_id), to: Native

  # Subscriptions -------------------------------------------------------------

  @doc """
  Subscribe `pid` to local-update events on the doc.

  Whenever a local mutation (`insert_text`, `apply_update`, tree ops, etc.)
  commits on this doc handle, the subscribed pid receives:

      {:loro_event, subscription_ref, update_bytes}

  `update_bytes` is ready to feed into `apply_update/2` on a peer doc — no
  further processing required. This mirrors Loro's `subscribe_local_update`
  semantics.

  ## Reference semantics

  The returned `subscription` handle keeps the subscription alive. Dropping
  the last reference cancels; call `unsubscribe/1` to cancel eagerly.

  ## Re-entrancy warning

  The callback runs inside the commit path. Inside Rust we only do a
  `send` to your pid, so there's no chance of deadlock from the NIF side.
  But if the subscribed process handles `{:loro_event, _, _}` by calling
  back into LoroEx on the SAME doc via a GenServer call, and that
  GenServer is the one that just committed the change, you'll deadlock
  your own supervisor tree. Handle the event asynchronously (e.g. cast,
  or broadcast to another topic).
  """
  @spec subscribe(doc(), pid()) :: subscription() | error()
  defdelegate subscribe(doc, pid), to: Native

  @doc """
  Cancel a subscription eagerly.

  Safe to call more than once; second call is a no-op.
  """
  @spec unsubscribe(subscription()) :: :ok | error()
  defdelegate unsubscribe(sub), to: Native
end
