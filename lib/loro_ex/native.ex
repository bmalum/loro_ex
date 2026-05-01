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
  * Version vectors cross the boundary as opaque binaries — do not inspect.
  * Subscription callbacks deliver messages as
    `{:loro_event, subscription_ref, update_bytes}`.

  ## Error shape

  Errors are `{:error, {reason_atom, detail_string}}`. See `LoroEx` for the
  full list of reason atoms.
  """

  use Rustler, otp_app: :loro_ex, crate: "loro_nif"

  @type doc :: reference()
  @type subscription :: reference()
  @type error_reason :: atom()
  @type error :: {:error, {error_reason(), String.t()}}

  # Lifecycle -----------------------------------------------------------------

  @spec new_doc() :: doc()
  def new_doc, do: :erlang.nif_error(:nif_not_loaded)

  @spec new_doc_with_peer(non_neg_integer()) :: doc() | error()
  def new_doc_with_peer(_peer_id), do: :erlang.nif_error(:nif_not_loaded)

  # Sync primitives -----------------------------------------------------------

  @spec apply_update(doc(), binary()) :: :ok | error()
  def apply_update(_doc, _bytes), do: :erlang.nif_error(:nif_not_loaded)

  @spec export_snapshot(doc()) :: binary() | error()
  def export_snapshot(_doc), do: :erlang.nif_error(:nif_not_loaded)

  @spec export_shallow_snapshot(doc(), binary()) :: binary() | error()
  def export_shallow_snapshot(_doc, _frontier), do: :erlang.nif_error(:nif_not_loaded)

  @spec export_updates_from(doc(), binary()) :: binary() | error()
  def export_updates_from(_doc, _version), do: :erlang.nif_error(:nif_not_loaded)

  @spec oplog_version(doc()) :: binary() | error()
  def oplog_version(_doc), do: :erlang.nif_error(:nif_not_loaded)

  @spec state_vector(doc()) :: binary() | error()
  def state_vector(_doc), do: :erlang.nif_error(:nif_not_loaded)

  @spec oplog_frontiers(doc()) :: binary() | error()
  def oplog_frontiers(_doc), do: :erlang.nif_error(:nif_not_loaded)

  @spec state_frontiers(doc()) :: binary() | error()
  def state_frontiers(_doc), do: :erlang.nif_error(:nif_not_loaded)

  @spec shallow_since_frontiers(doc()) :: binary() | error()
  def shallow_since_frontiers(_doc), do: :erlang.nif_error(:nif_not_loaded)

  # Text ----------------------------------------------------------------------

  @spec get_text(doc(), String.t()) :: String.t() | error()
  def get_text(_doc, _container_id), do: :erlang.nif_error(:nif_not_loaded)

  @spec insert_text(doc(), String.t(), non_neg_integer(), String.t()) :: :ok | error()
  def insert_text(_doc, _container_id, _pos, _value),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec delete_text(doc(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | error()
  def delete_text(_doc, _container_id, _pos, _len), do: :erlang.nif_error(:nif_not_loaded)

  # Map -----------------------------------------------------------------------

  @spec get_map_json(doc(), String.t()) :: String.t() | error()
  def get_map_json(_doc, _container_id), do: :erlang.nif_error(:nif_not_loaded)

  @spec map_set(doc(), String.t(), String.t(), String.t()) :: :ok | error()
  def map_set(_doc, _container_id, _key, _value_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec map_delete(doc(), String.t(), String.t()) :: :ok | error()
  def map_delete(_doc, _container_id, _key),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec map_get_json(doc(), String.t(), String.t()) :: String.t() | error()
  def map_get_json(_doc, _container_id, _key),
    do: :erlang.nif_error(:nif_not_loaded)

  # List ----------------------------------------------------------------------

  @spec list_get_json(doc(), String.t()) :: String.t() | error()
  def list_get_json(_doc, _container_id),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec list_push(doc(), String.t(), String.t()) :: :ok | error()
  def list_push(_doc, _container_id, _value_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec list_delete(doc(), String.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | error()
  def list_delete(_doc, _container_id, _index, _len),
    do: :erlang.nif_error(:nif_not_loaded)

  # Movable tree --------------------------------------------------------------

  @spec tree_create_node(doc(), String.t(), String.t() | nil) :: String.t() | error()
  def tree_create_node(_doc, _tree_id, _parent_id),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec tree_move_node(
          doc(),
          String.t(),
          String.t(),
          String.t() | nil,
          non_neg_integer()
        ) :: :ok | error()
  def tree_move_node(_doc, _tree_id, _node_id, _new_parent_id, _index),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec tree_delete_node(doc(), String.t(), String.t()) :: :ok | error()
  def tree_delete_node(_doc, _tree_id, _node_id),
    do: :erlang.nif_error(:nif_not_loaded)

  @spec tree_get_nodes(doc(), String.t()) :: String.t() | error()
  def tree_get_nodes(_doc, _tree_id), do: :erlang.nif_error(:nif_not_loaded)

  # Subscriptions -------------------------------------------------------------

  @spec subscribe(doc(), pid()) :: subscription() | error()
  def subscribe(_doc, _pid), do: :erlang.nif_error(:nif_not_loaded)

  @spec unsubscribe(subscription()) :: :ok | error()
  def unsubscribe(_sub), do: :erlang.nif_error(:nif_not_loaded)
end
