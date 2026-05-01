defmodule LoroEx.Native do
  @moduledoc """
  Raw NIF bindings to the Loro Rust library.

  Prefer the friendly API in `LoroEx`; this module is public only to make the
  NIF functions callable from the Elixir side. Arguments and return values
  mirror the Rust signatures one-to-one.

  ## Invariants

  * All NIFs scheduled on `DirtyCpu`; safe to call from any process.
  * Doc handles are opaque `ResourceArc`s; they are reference-counted and
    will be dropped when no Elixir term references them.
  * Version vectors, frontiers, and cursors cross the boundary as opaque
    binaries — do not inspect.
  * Local-update subscription callbacks deliver
    `{:loro_event, subscription_ref, update_bytes}`.
  * Structured diff subscription callbacks deliver
    `{:loro_diff, subscription_ref, events_json_binary}`.
  * Ephemeral subscription callbacks deliver
    `{:loro_ephemeral, subscription_ref, update_bytes}`.

  ## Error shape

  Errors are `{:error, {reason_atom, detail_string}}`. See `LoroEx` for the
  full list of reason atoms.
  """

  use Rustler, otp_app: :loro_ex, crate: "loro_nif"

  @type doc :: reference()
  @type subscription :: reference()
  @type undo_manager :: reference()
  @type ephemeral_store :: reference()
  @type cursor :: binary()
  @type error_reason :: atom()
  @type error :: {:error, {error_reason(), String.t()}}

  # Lifecycle -----------------------------------------------------------------

  def new_doc, do: :erlang.nif_error(:nif_not_loaded)
  def new_doc_with_peer(_peer_id), do: :erlang.nif_error(:nif_not_loaded)

  # Sync primitives -----------------------------------------------------------

  def apply_update(_doc, _bytes), do: :erlang.nif_error(:nif_not_loaded)
  def export_snapshot(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def export_shallow_snapshot(_doc, _frontier), do: :erlang.nif_error(:nif_not_loaded)
  def export_updates_from(_doc, _version), do: :erlang.nif_error(:nif_not_loaded)
  def oplog_version(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def state_vector(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def oplog_frontiers(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def state_frontiers(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def shallow_since_frontiers(_doc), do: :erlang.nif_error(:nif_not_loaded)

  # Text (plain) --------------------------------------------------------------

  def get_text(_doc, _container_id), do: :erlang.nif_error(:nif_not_loaded)
  def insert_text(_doc, _container_id, _pos, _value), do: :erlang.nif_error(:nif_not_loaded)
  def delete_text(_doc, _container_id, _pos, _len), do: :erlang.nif_error(:nif_not_loaded)

  # Text (rich-text / Peritext) ----------------------------------------------

  def text_mark(_doc, _cid, _start, _end, _key, _value_json),
    do: :erlang.nif_error(:nif_not_loaded)

  def text_unmark(_doc, _cid, _start, _end, _key), do: :erlang.nif_error(:nif_not_loaded)
  def text_to_delta(_doc, _cid), do: :erlang.nif_error(:nif_not_loaded)
  def text_apply_delta(_doc, _cid, _delta_json), do: :erlang.nif_error(:nif_not_loaded)
  def text_get_richtext_value(_doc, _cid), do: :erlang.nif_error(:nif_not_loaded)
  def text_len_unicode(_doc, _cid), do: :erlang.nif_error(:nif_not_loaded)
  def text_len_utf8(_doc, _cid), do: :erlang.nif_error(:nif_not_loaded)
  def text_len_utf16(_doc, _cid), do: :erlang.nif_error(:nif_not_loaded)
  def text_convert_pos(_doc, _cid, _index, _from, _to), do: :erlang.nif_error(:nif_not_loaded)

  # Cursor --------------------------------------------------------------------

  def text_get_cursor(_doc, _cid, _pos, _side), do: :erlang.nif_error(:nif_not_loaded)
  def list_get_cursor(_doc, _cid, _pos, _side), do: :erlang.nif_error(:nif_not_loaded)
  def cursor_resolve(_doc, _cursor_bin), do: :erlang.nif_error(:nif_not_loaded)

  # Map -----------------------------------------------------------------------

  def get_map_json(_doc, _cid), do: :erlang.nif_error(:nif_not_loaded)
  def map_set(_doc, _cid, _key, _value_json), do: :erlang.nif_error(:nif_not_loaded)
  def map_delete(_doc, _cid, _key), do: :erlang.nif_error(:nif_not_loaded)
  def map_get_json(_doc, _cid, _key), do: :erlang.nif_error(:nif_not_loaded)
  def map_insert_container(_doc, _cid, _key, _kind), do: :erlang.nif_error(:nif_not_loaded)

  # List ----------------------------------------------------------------------

  def list_get_json(_doc, _cid), do: :erlang.nif_error(:nif_not_loaded)
  def list_push(_doc, _cid, _value_json), do: :erlang.nif_error(:nif_not_loaded)
  def list_delete(_doc, _cid, _index, _len), do: :erlang.nif_error(:nif_not_loaded)
  def list_insert_container(_doc, _cid, _pos, _kind), do: :erlang.nif_error(:nif_not_loaded)

  # Movable tree --------------------------------------------------------------

  def tree_create_node(_doc, _tree_id, _parent_id), do: :erlang.nif_error(:nif_not_loaded)

  def tree_move_node(_doc, _tree_id, _node_id, _new_parent_id, _index),
    do: :erlang.nif_error(:nif_not_loaded)

  def tree_delete_node(_doc, _tree_id, _node_id), do: :erlang.nif_error(:nif_not_loaded)
  def tree_get_nodes(_doc, _tree_id), do: :erlang.nif_error(:nif_not_loaded)
  def tree_get_meta(_doc, _tree_id, _node_id), do: :erlang.nif_error(:nif_not_loaded)

  # Subscriptions -------------------------------------------------------------

  def subscribe(_doc, _pid), do: :erlang.nif_error(:nif_not_loaded)
  def unsubscribe(_sub), do: :erlang.nif_error(:nif_not_loaded)
  def subscribe_container(_doc, _cid, _pid), do: :erlang.nif_error(:nif_not_loaded)
  def subscribe_root(_doc, _pid), do: :erlang.nif_error(:nif_not_loaded)

  # UndoManager ---------------------------------------------------------------

  def undo_manager_new(_doc), do: :erlang.nif_error(:nif_not_loaded)
  def undo_manager_undo(_mgr), do: :erlang.nif_error(:nif_not_loaded)
  def undo_manager_redo(_mgr), do: :erlang.nif_error(:nif_not_loaded)
  def undo_manager_can_undo(_mgr), do: :erlang.nif_error(:nif_not_loaded)
  def undo_manager_can_redo(_mgr), do: :erlang.nif_error(:nif_not_loaded)
  def undo_manager_record_new_checkpoint(_mgr), do: :erlang.nif_error(:nif_not_loaded)
  def undo_manager_set_max_undo_steps(_mgr, _size), do: :erlang.nif_error(:nif_not_loaded)
  def undo_manager_set_merge_interval(_mgr, _ms), do: :erlang.nif_error(:nif_not_loaded)

  # EphemeralStore ------------------------------------------------------------

  def ephemeral_new(_timeout_ms), do: :erlang.nif_error(:nif_not_loaded)
  def ephemeral_set(_store, _key, _value_json), do: :erlang.nif_error(:nif_not_loaded)
  def ephemeral_get(_store, _key), do: :erlang.nif_error(:nif_not_loaded)
  def ephemeral_delete(_store, _key), do: :erlang.nif_error(:nif_not_loaded)
  def ephemeral_keys(_store), do: :erlang.nif_error(:nif_not_loaded)
  def ephemeral_get_all_states(_store), do: :erlang.nif_error(:nif_not_loaded)
  def ephemeral_encode(_store, _key), do: :erlang.nif_error(:nif_not_loaded)
  def ephemeral_encode_all(_store), do: :erlang.nif_error(:nif_not_loaded)
  def ephemeral_apply(_store, _bytes), do: :erlang.nif_error(:nif_not_loaded)
  def ephemeral_remove_outdated(_store), do: :erlang.nif_error(:nif_not_loaded)
  def ephemeral_subscribe(_store, _pid), do: :erlang.nif_error(:nif_not_loaded)
end
