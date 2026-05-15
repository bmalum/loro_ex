//! Rustler NIF for the Loro CRDT library.
//!
//! ## Invariants
//!
//! 1. Every NIF that touches a `LoroDoc` is scheduled on a `DirtyCpu`
//!    scheduler. Loro operations on non-trivial docs can take tens of
//!    milliseconds which would starve normal BEAM schedulers.
//!
//! 2. `LoroDoc` is wrapped in a `Mutex`. Rustler may invoke NIFs from any
//!    thread; Loro operations mutate internal state. We use `Mutex` rather
//!    than `RwLock` because writes are the hot path.
//!
//! 3. Version vectors, frontiers, and cursors cross the NIF boundary as
//!    opaque binaries produced by `encode()`. Callers must treat them as
//!    opaque. Decoding happens inside Rust so Elixir can't mix them up.
//!
//! 4. Return values prefer `OwnedBinary` over `Vec<u8>` to avoid a second
//!    heap copy into the BEAM.
//!
//! 5. Subscription callbacks MUST NOT re-enter the doc. They run inside
//!    `commit()` / `import()` which already hold the mutex; taking it again
//!    would deadlock. Callbacks only encode and `send` to a pid.

use rustler::{
    Atom, Binary, Encoder, Error as NifError, LocalPid, NifResult, OwnedBinary, OwnedEnv,
    ResourceArc,
};
use std::sync::Mutex;

use loro::{
    awareness::EphemeralStore,
    cursor::{Cursor, PosType, Side},
    ContainerID, ContainerType, ExportMode, Frontiers, LoroDoc, LoroEncodeError, LoroError,
    LoroTreeError, LoroValue, Subscription, TextDelta, TreeID, UndoManager, ValueOrContainer,
    VersionVector,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,

        // Error reason atoms
        invalid_update,
        invalid_version_vector,
        invalid_frontier,
        invalid_tree_id,
        invalid_peer_id,
        invalid_value,
        invalid_cursor,
        invalid_delta,
        invalid_container_kind,
        checksum_mismatch,
        incompatible_version,
        not_found,
        out_of_bound,
        cyclic_move,
        tree_node_not_found,
        fractional_index_not_enabled,
        index_out_of_bound,
        container_deleted,
        history_cleared,
        id_not_found,
        lock_poisoned,
        subscription_dropped,
        ephemeral_apply_failed,
        unknown,

        // Side atoms
        left,
        middle,
        right,

        // Container kind atoms
        text,
        map,
        list,
        movable_list,
        tree,

        // Tree parent variants
        root,
        deleted,
        unexist,

        // JSON-path
        invalid_path,

        // Event tags
        loro_event,
        loro_diff,
        loro_ephemeral
    }
}

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

pub struct DocResource {
    pub inner: Mutex<LoroDoc>,
}

impl DocResource {
    fn new(doc: LoroDoc) -> Self {
        Self {
            inner: Mutex::new(doc),
        }
    }
}

#[rustler::resource_impl]
impl rustler::Resource for DocResource {}

pub struct SubscriptionResource {
    pub inner: Mutex<Option<Subscription>>,
}

#[rustler::resource_impl]
impl rustler::Resource for SubscriptionResource {}

pub struct UndoResource {
    #[allow(dead_code)]
    pub doc: ResourceArc<DocResource>,
    pub inner: Mutex<UndoManager>,
}

#[rustler::resource_impl]
impl rustler::Resource for UndoResource {}

pub struct EphemeralResource {
    pub inner: EphemeralStore,
}

#[rustler::resource_impl]
impl rustler::Resource for EphemeralResource {}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

fn loro_err_to_nif(err: LoroError) -> NifError {
    let reason = match &err {
        LoroError::DecodeVersionVectorError => atoms::invalid_version_vector(),
        LoroError::DecodeError(_)
        | LoroError::DecodeDataCorruptionError
        | LoroError::ImportUnsupportedEncodingMode => atoms::invalid_update(),
        LoroError::DecodeChecksumMismatchError => atoms::checksum_mismatch(),
        LoroError::IncompatibleFutureEncodingError(_) => atoms::incompatible_version(),
        LoroError::NotFoundError(_) | LoroError::FrontiersNotFound(_) => atoms::not_found(),
        LoroError::OutOfBound { .. } => atoms::out_of_bound(),
        LoroError::InvalidPeerID => atoms::invalid_peer_id(),
        LoroError::ContainerDeleted { .. } => atoms::container_deleted(),
        LoroError::LockError => atoms::lock_poisoned(),
        LoroError::TreeError(tree_err) => match tree_err {
            LoroTreeError::CyclicMoveError => atoms::cyclic_move(),
            LoroTreeError::TreeNodeParentNotFound(_)
            | LoroTreeError::TreeNodeNotExist(_)
            | LoroTreeError::TreeNodeDeletedOrNotExist(_)
            | LoroTreeError::InvalidParent => atoms::tree_node_not_found(),
            LoroTreeError::IndexOutOfBound { .. } => atoms::index_out_of_bound(),
            LoroTreeError::FractionalIndexNotEnabled => atoms::fractional_index_not_enabled(),
        },
        _ => atoms::unknown(),
    };
    NifError::Term(Box::new((reason, format!("{err}"))))
}

fn encode_err_to_nif(err: LoroEncodeError) -> NifError {
    let reason = match &err {
        LoroEncodeError::FrontiersNotFound(_) => atoms::not_found(),
        LoroEncodeError::ShallowSnapshotIncompatibleWithOldFormat => atoms::incompatible_version(),
        _ => atoms::unknown(),
    };
    NifError::Term(Box::new((reason, format!("{err}"))))
}

fn tree_id_parse_err_to_nif(err: LoroError) -> NifError {
    NifError::Term(Box::new((atoms::invalid_tree_id(), format!("{err}"))))
}

fn json_err_to_nif(err: serde_json::Error) -> NifError {
    NifError::Term(Box::new((atoms::unknown(), format!("json: {err}"))))
}

fn poisoned_to_nif() -> NifError {
    NifError::Term(Box::new((atoms::lock_poisoned(), "mutex poisoned")))
}

fn invalid_value_err(detail: &str) -> NifError {
    NifError::Term(Box::new((atoms::invalid_value(), detail.to_string())))
}

fn bytes_to_owned_binary(bytes: &[u8]) -> NifResult<OwnedBinary> {
    let mut bin = OwnedBinary::new(bytes.len())
        .ok_or_else(|| NifError::Term(Box::new((atoms::unknown(), "alloc failed"))))?;
    bin.as_mut_slice().copy_from_slice(bytes);
    Ok(bin)
}

fn parse_tree_id(s: &str) -> NifResult<TreeID> {
    TreeID::try_from(s).map_err(tree_id_parse_err_to_nif)
}

fn ensure_tree_ready(tree: &loro::LoroTree) {
    tree.enable_fractional_index(0);
}

// ---------------------------------------------------------------------------
// Container-id resolution
// ---------------------------------------------------------------------------

fn try_parse_container_id(s: &str) -> Option<ContainerID> {
    ContainerID::try_from(s).ok()
}

fn get_text_handle(doc: &LoroDoc, id: &str) -> loro::LoroText {
    match try_parse_container_id(id) {
        Some(cid) => doc.get_text(cid),
        None => doc.get_text(id),
    }
}

fn get_map_handle(doc: &LoroDoc, id: &str) -> loro::LoroMap {
    match try_parse_container_id(id) {
        Some(cid) => doc.get_map(cid),
        None => doc.get_map(id),
    }
}

fn get_list_handle(doc: &LoroDoc, id: &str) -> loro::LoroList {
    match try_parse_container_id(id) {
        Some(cid) => doc.get_list(cid),
        None => doc.get_list(id),
    }
}

fn get_movable_list_handle(doc: &LoroDoc, id: &str) -> loro::LoroMovableList {
    match try_parse_container_id(id) {
        Some(cid) => doc.get_movable_list(cid),
        None => doc.get_movable_list(id),
    }
}

fn get_tree_handle(doc: &LoroDoc, id: &str) -> loro::LoroTree {
    match try_parse_container_id(id) {
        Some(cid) => doc.get_tree(cid),
        None => doc.get_tree(id),
    }
}

// ---------------------------------------------------------------------------
// JSON ↔ LoroValue
// ---------------------------------------------------------------------------

fn json_to_loro_value(v: serde_json::Value) -> NifResult<LoroValue> {
    match v {
        serde_json::Value::Null => Ok(LoroValue::Null),
        serde_json::Value::Bool(b) => Ok(LoroValue::Bool(b)),
        serde_json::Value::String(s) => Ok(LoroValue::String(s.into())),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Ok(LoroValue::I64(i))
            } else if let Some(f) = n.as_f64() {
                Ok(LoroValue::Double(f))
            } else {
                Err(invalid_value_err("number out of range"))
            }
        }
        // Structured values: defer to Loro's built-in conversion, which
        // walks the tree and produces LoroValue::List / LoroValue::Map
        // with the same semantics as the scalar branches above. Available
        // because the `loro` crate enables the `serde_json` feature on
        // `loro-common`.
        //
        // Note: values produced this way are stored as frozen structured
        // values inside the parent map/list. For CRDT-level merging on
        // nested fields, use `map_insert_container` / `list_insert_container`
        // to materialize nested containers instead.
        arr @ serde_json::Value::Array(_) => Ok(LoroValue::from(arr)),
        obj @ serde_json::Value::Object(_) => Ok(LoroValue::from(obj)),
    }
}

fn parse_scalar_json(s: &str) -> NifResult<LoroValue> {
    let parsed: serde_json::Value = serde_json::from_str(s).map_err(json_err_to_nif)?;
    json_to_loro_value(parsed)
}

// ---------------------------------------------------------------------------
// Atom decoders
// ---------------------------------------------------------------------------

fn atom_to_container_type(a: Atom) -> NifResult<ContainerType> {
    if a == atoms::text() {
        Ok(ContainerType::Text)
    } else if a == atoms::map() {
        Ok(ContainerType::Map)
    } else if a == atoms::list() {
        Ok(ContainerType::List)
    } else if a == atoms::movable_list() {
        Ok(ContainerType::MovableList)
    } else if a == atoms::tree() {
        Ok(ContainerType::Tree)
    } else {
        Err(NifError::Term(Box::new((
            atoms::invalid_container_kind(),
            "expected :text | :map | :list | :movable_list | :tree".to_string(),
        ))))
    }
}

fn atom_to_side(a: Atom) -> NifResult<Side> {
    if a == atoms::left() {
        Ok(Side::Left)
    } else if a == atoms::middle() {
        Ok(Side::Middle)
    } else if a == atoms::right() {
        Ok(Side::Right)
    } else {
        Err(NifError::Term(Box::new((
            atoms::invalid_cursor(),
            "side must be :left | :middle | :right".to_string(),
        ))))
    }
}

fn side_to_atom(s: Side) -> Atom {
    match s {
        Side::Left => atoms::left(),
        Side::Middle => atoms::middle(),
        Side::Right => atoms::right(),
    }
}

fn atom_to_postype(a: Atom) -> NifResult<PosType> {
    rustler::atoms! { unicode, utf8, utf16 }
    if a == unicode() {
        Ok(PosType::Unicode)
    } else if a == utf8() {
        Ok(PosType::Bytes)
    } else if a == utf16() {
        Ok(PosType::Utf16)
    } else {
        Err(NifError::Term(Box::new((
            atoms::invalid_value(),
            "pos unit must be :unicode | :utf8 | :utf16".to_string(),
        ))))
    }
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn new_doc() -> ResourceArc<DocResource> {
    ResourceArc::new(DocResource::new(LoroDoc::new()))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn new_doc_with_peer(peer_id: u64) -> NifResult<ResourceArc<DocResource>> {
    let doc = LoroDoc::new();
    doc.set_peer_id(peer_id).map_err(loro_err_to_nif)?;
    Ok(ResourceArc::new(DocResource::new(doc)))
}

/// Duplicate the document. The returned `LoroDoc` observes the parent's op
/// history at the moment of the call but lives in its own resource — mutations
/// and exports on the fork do not touch the parent, and vice versa.
///
/// Loro assigns the fork a new random peer id, so any ops committed on it
/// won't collide with the parent's peer id if they're later merged back.
///
/// Time and space complexity are O(n) in the size of the op log — it's not
/// free, but it's considerably cheaper than a full `export_snapshot` because
/// no serialization to bytes happens. Primarily useful for moving expensive
/// exports off a GenServer mailbox.
#[rustler::nif(schedule = "DirtyCpu")]
fn fork(doc: ResourceArc<DocResource>) -> NifResult<ResourceArc<DocResource>> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let forked = guard.fork();
    drop(guard);
    Ok(ResourceArc::new(DocResource::new(forked)))
}

/// Fork the doc at a specific frontier. Like `fork/1` but the clone
/// observes only the history up to `frontier`, not the parent's
/// current state.
#[rustler::nif(schedule = "DirtyCpu")]
fn fork_at(doc: ResourceArc<DocResource>, frontier: Binary) -> NifResult<ResourceArc<DocResource>> {
    let frontiers = Frontiers::decode(frontier.as_slice())
        .map_err(|e| NifError::Term(Box::new((atoms::invalid_frontier(), format!("{e:?}")))))?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let forked = guard.fork_at(&frontiers).map_err(loro_err_to_nif)?;
    drop(guard);
    Ok(ResourceArc::new(DocResource::new(forked)))
}

/// Construct a fresh doc and import a snapshot in one call. Cheaper
/// than `new/0` followed by `apply_update/2` because the snapshot is
/// loaded directly into the doc's initial state.
#[rustler::nif(schedule = "DirtyCpu")]
fn from_snapshot(bytes: Binary) -> NifResult<ResourceArc<DocResource>> {
    let doc = LoroDoc::from_snapshot(bytes.as_slice()).map_err(loro_err_to_nif)?;
    Ok(ResourceArc::new(DocResource::new(doc)))
}

/// Return the doc's current peer id.
#[rustler::nif(schedule = "DirtyCpu")]
fn peer_id(doc: ResourceArc<DocResource>) -> NifResult<u64> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(guard.peer_id())
}

/// Replace the doc's peer id at runtime. Errors with `:invalid_peer_id`
/// if `peer_id` is the reserved `PeerID::MAX` value.
#[rustler::nif(schedule = "DirtyCpu")]
fn set_peer_id(doc: ResourceArc<DocResource>, peer_id: u64) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.set_peer_id(peer_id).map_err(loro_err_to_nif)?;
    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// Sync primitives
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn apply_update(doc: ResourceArc<DocResource>, update: Binary) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.import(update.as_slice()).map_err(loro_err_to_nif)?;
    Ok(atoms::ok())
}

/// Apply a batch of updates atomically. Acquires the doc mutex once
/// for the whole batch and emits a single commit, which is faster than
/// looping `apply_update/2` when replaying a queue of updates.
#[rustler::nif(schedule = "DirtyCpu")]
fn import_batch(doc: ResourceArc<DocResource>, updates: Vec<Binary>) -> NifResult<Atom> {
    let owned: Vec<Vec<u8>> = updates.iter().map(|b| b.as_slice().to_vec()).collect();
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.import_batch(&owned).map_err(loro_err_to_nif)?;
    Ok(atoms::ok())
}

/// Inspect the metadata of a snapshot or update blob without
/// importing it. Useful for auth, quota, and corruption checks before
/// committing the bytes to a doc.
///
/// Returns a JSON string with fields:
///   * `mode` — `"snapshot" | "shallow-snapshot" | "update" | "outdated-snapshot" | "outdated-update"`
///   * `is_snapshot` — bool
///   * `start_timestamp`, `end_timestamp` — i64 unix timestamps (0 if unrecorded)
///   * `change_num` — number of changes encoded
///   * `partial_start_vv_size`, `partial_end_vv_size` — peer-id counts in the partial vvs
#[rustler::nif(schedule = "DirtyCpu")]
fn decode_import_blob_meta(bytes: Binary, check_checksum: bool) -> NifResult<String> {
    let meta = LoroDoc::decode_import_blob_meta(bytes.as_slice(), check_checksum)
        .map_err(loro_err_to_nif)?;
    let json = serde_json::json!({
        "mode": format!("{}", meta.mode),
        "is_snapshot": meta.mode.is_snapshot(),
        "start_timestamp": meta.start_timestamp,
        "end_timestamp": meta.end_timestamp,
        "change_num": meta.change_num,
        "partial_start_vv_size": meta.partial_start_vv.iter().count() as u64,
        "partial_end_vv_size": meta.partial_end_vv.iter().count() as u64,
    });
    serde_json::to_string(&json).map_err(json_err_to_nif)
}

/// Rewind the doc to a previous frontier by emitting **new ops** that
/// invert the changes since that point. NOT a checkout — `revert_to`
/// produces forward-compatible inverse ops which:
///
///   * sync to peers like any other edit
///   * fire subscription callbacks
///   * are tracked by `UndoManager` and can themselves be undone
///
/// Errors with `:invalid_frontier` if the binary doesn't decode, or
/// `:not_found` / `:incompatible_version` if the frontier references
/// ops the doc doesn't have.
#[rustler::nif(schedule = "DirtyCpu")]
fn revert_to(doc: ResourceArc<DocResource>, frontier: Binary) -> NifResult<Atom> {
    let frontiers = Frontiers::decode(frontier.as_slice())
        .map_err(|e| NifError::Term(Box::new((atoms::invalid_frontier(), format!("{e:?}")))))?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.revert_to(&frontiers).map_err(loro_err_to_nif)?;
    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// Time travel
// ---------------------------------------------------------------------------
//
// Distinct from `revert_to`: checkout *changes the visible state* of the
// doc to a past point without producing new ops. While detached, the doc
// rejects new commits unless `set_detached_editing(true)` was called.
// `attach` re-enables live ops; `checkout_to_latest` does both at once.
//
// Concurrency note: under our `Mutex<LoroDoc>`, `checkout` is internally
// synchronized, but it mutates *visible state*. Any other process holding
// the doc handle and reading after the checkout will see the rewound state.
// The "one GenServer per doc" pattern serializes around this cleanly.

/// Rewind the doc's visible state to `frontier`. Reads after this call
/// see the doc as it existed at that point. Use `attach/1` (or
/// `checkout_to_latest/1`) to return to the live state.
///
/// Errors:
///   * `:invalid_frontier` — binary doesn't decode
///   * `:not_found` / `:incompatible_version` — frontier references
///     ops the doc doesn't have
#[rustler::nif(schedule = "DirtyCpu")]
fn checkout(doc: ResourceArc<DocResource>, frontier: Binary) -> NifResult<Atom> {
    let frontiers = Frontiers::decode(frontier.as_slice())
        .map_err(|e| NifError::Term(Box::new((atoms::invalid_frontier(), format!("{e:?}")))))?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.checkout(&frontiers).map_err(loro_err_to_nif)?;
    Ok(atoms::ok())
}

/// Re-attach the doc to its latest known state and resume accepting
/// new ops. Idempotent if the doc is already attached.
#[rustler::nif(schedule = "DirtyCpu")]
fn checkout_to_latest(doc: ResourceArc<DocResource>) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.checkout_to_latest();
    Ok(atoms::ok())
}

/// Re-attach to live state. Same effect as `checkout_to_latest/1`.
/// Kept as a separate name because Loro exposes both verbs and
/// callers may prefer the `attach`/`detach` pairing for readability.
#[rustler::nif(schedule = "DirtyCpu")]
fn attach(doc: ResourceArc<DocResource>) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.attach();
    Ok(atoms::ok())
}

/// Detach the doc from its latest state without rewinding. The doc
/// rejects new commits while detached unless `set_detached_editing(true)`
/// is enabled.
#[rustler::nif(schedule = "DirtyCpu")]
fn detach(doc: ResourceArc<DocResource>) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.detach();
    Ok(atoms::ok())
}

/// `true` if the doc is currently detached (post `checkout/2` or
/// `detach/1`, before `attach/1` or `checkout_to_latest/1`).
#[rustler::nif(schedule = "DirtyCpu")]
fn is_detached(doc: ResourceArc<DocResource>) -> NifResult<bool> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(guard.is_detached())
}

/// Allow / forbid new commits while the doc is detached. Default is
/// `false`. Enable when you intentionally want to fork history off a
/// past frontier.
#[rustler::nif(schedule = "DirtyCpu")]
fn set_detached_editing(doc: ResourceArc<DocResource>, enable: bool) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.set_detached_editing(enable);
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn export_snapshot(doc: ResourceArc<DocResource>) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let bytes = guard
        .export(ExportMode::Snapshot)
        .map_err(encode_err_to_nif)?;
    bytes_to_owned_binary(&bytes)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn export_shallow_snapshot(
    doc: ResourceArc<DocResource>,
    frontier: Binary,
) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let frontiers = Frontiers::decode(frontier.as_slice())
        .map_err(|e| NifError::Term(Box::new((atoms::invalid_frontier(), format!("{e:?}")))))?;
    let bytes = guard
        .export(ExportMode::shallow_snapshot(&frontiers))
        .map_err(encode_err_to_nif)?;
    bytes_to_owned_binary(&bytes)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn export_updates_from(doc: ResourceArc<DocResource>, version: Binary) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let vv = VersionVector::decode(version.as_slice()).map_err(loro_err_to_nif)?;
    let bytes = guard
        .export(ExportMode::updates(&vv))
        .map_err(encode_err_to_nif)?;
    bytes_to_owned_binary(&bytes)
}

/// Return the set of distinct container ids touched by ops in the
/// half-open range `(from_vv, current_oplog_vv]`.
///
/// The cost is O(ops_since), not O(doc_size). For a small gap this is
/// microseconds; for a huge replay it scales with the size of the
/// replay.
///
/// Implementation note: Loro 1.12 does not expose `OpLog::iter_ops`
/// publicly, so we go through `export_json_updates_without_peer_compression`.
/// We use the non-compressed variant on purpose — the compressed
/// variant rewrites peer ids to small indices in the schema, which
/// would mangle ContainerID strings (`cid:1@<peer>:Text` becomes
/// `cid:1@<index>:Text`). Callers expect to feed the returned strings
/// straight back into other LoroEx functions, so they must match the
/// real peer-tagged form.
///
/// The schema is materialized but never serialized — we walk it once
/// to harvest CIDs and drop it. If profiling later flags this as hot,
/// we can switch to a direct `change_store().iter_changes(span)` walk
/// via `with_oplog` once upstream exposes it.
#[rustler::nif(schedule = "DirtyCpu")]
fn containers_touched_since(
    doc: ResourceArc<DocResource>,
    from_vv: Binary,
) -> NifResult<Vec<String>> {
    use std::collections::HashSet;

    let from_vv = VersionVector::decode(from_vv.as_slice()).map_err(loro_err_to_nif)?;

    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let current_vv = guard.oplog_vv();

    if from_vv == current_vv {
        return Ok(Vec::new());
    }

    let schema = guard.export_json_updates_without_peer_compression(&from_vv, &current_vv);

    let mut seen: HashSet<ContainerID> = HashSet::new();
    let mut out: Vec<String> = Vec::new();
    for change in &schema.changes {
        for op in &change.ops {
            if seen.insert(op.container.clone()) {
                out.push(op.container.to_string());
            }
        }
    }
    Ok(out)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn oplog_version(doc: ResourceArc<DocResource>) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    bytes_to_owned_binary(&guard.oplog_vv().encode())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn state_vector(doc: ResourceArc<DocResource>) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    bytes_to_owned_binary(&guard.state_vv().encode())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn oplog_frontiers(doc: ResourceArc<DocResource>) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    bytes_to_owned_binary(&guard.oplog_frontiers().encode())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn state_frontiers(doc: ResourceArc<DocResource>) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    bytes_to_owned_binary(&guard.state_frontiers().encode())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn shallow_since_frontiers(doc: ResourceArc<DocResource>) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    bytes_to_owned_binary(&guard.shallow_since_frontiers().encode())
}

// ---------------------------------------------------------------------------
// Doc introspection
// ---------------------------------------------------------------------------

/// `true` if the doc is a shallow doc (history before
/// `shallow_since_vv` has been trimmed).
#[rustler::nif(schedule = "DirtyCpu")]
fn is_shallow(doc: ResourceArc<DocResource>) -> NifResult<bool> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(guard.is_shallow())
}

/// `true` if the given container exists in this doc. Root container
/// names always return `true` (Loro materializes roots lazily on
/// first access). For nested containers, returns `true` only if the
/// CID exists in the doc state.
#[rustler::nif(schedule = "DirtyCpu")]
fn has_container(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<bool> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(match try_parse_container_id(&container_id) {
        Some(cid) => guard.has_container(&cid),
        // Root names — Loro treats every well-formed root as present.
        None => true,
    })
}

/// Number of ops queued in the pending transaction (uncommitted).
#[rustler::nif(schedule = "DirtyCpu")]
fn pending_txn_len(doc: ResourceArc<DocResource>) -> NifResult<u64> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(guard.get_pending_txn_len() as u64)
}

/// Total number of ops in the op log (committed).
#[rustler::nif(schedule = "DirtyCpu")]
fn len_ops(doc: ResourceArc<DocResource>) -> NifResult<u64> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(guard.len_ops() as u64)
}

/// Total number of changes (op-batches) in the op log.
#[rustler::nif(schedule = "DirtyCpu")]
fn len_changes(doc: ResourceArc<DocResource>) -> NifResult<u64> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(guard.len_changes() as u64)
}

/// Return doc analysis as a JSON string. Shape:
///
/// ```json
/// {
///   "containers": {
///     "<cid>": { "size": u32, "depth": u32, "ops_num": u32,
///                "dropped": bool, "last_edit_time": i64 }
///   }
/// }
/// ```
#[rustler::nif(schedule = "DirtyCpu")]
fn analyze(doc: ResourceArc<DocResource>) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let analysis = guard.analyze();
    let mut containers = serde_json::Map::with_capacity(analysis.containers.len());
    for (cid, info) in &analysis.containers {
        containers.insert(
            cid.to_string(),
            serde_json::json!({
                "size": info.size,
                "depth": info.depth,
                "ops_num": info.ops_num,
                "dropped": info.dropped,
                "last_edit_time": info.last_edit_time,
            }),
        );
    }
    serde_json::to_string(&serde_json::json!({"containers": containers})).map_err(json_err_to_nif)
}

/// Return the path from root to the given container as a JSON array
/// of `[cid, index]` pairs. `index` is either a string (map key /
/// tree node id) or an integer (list/movable-list position).
///
/// Returns `null` if the container does not exist.
#[rustler::nif(schedule = "DirtyCpu")]
fn get_path_to_container(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let cid = match try_parse_container_id(&container_id) {
        Some(c) => c,
        None => {
            return Ok("null".to_string());
        }
    };
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    match guard.get_path_to_container(&cid) {
        Some(path) => {
            let arr: Vec<serde_json::Value> = path
                .into_iter()
                .map(|(cid, idx)| serde_json::json!([cid.to_string(), index_to_json(&idx)]))
                .collect();
            serde_json::to_string(&serde_json::Value::Array(arr)).map_err(json_err_to_nif)
        }
        None => Ok("null".to_string()),
    }
}

/// Like `get_map_json` / `list_get_json` at the doc root, but each
/// container in the returned tree is wrapped with its container id.
/// Useful for block-tree introspection where the caller needs CIDs to
/// drive subsequent writes.
#[rustler::nif(schedule = "DirtyCpu")]
fn get_deep_value_with_id(doc: ResourceArc<DocResource>) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let value = guard.get_deep_value_with_id();
    serde_json::to_string(&value).map_err(json_err_to_nif)
}

// ---------------------------------------------------------------------------
// JSON-path queries
// ---------------------------------------------------------------------------

/// Look up a single value or container at a JSON-path expression.
/// Returns the deep value as a JSON string, or `null` if the path
/// resolves to nothing.
///
/// Path syntax follows Loro's JSON-path implementation, which is a
/// subset of [RFC 9535](https://datatracker.ietf.org/doc/rfc9535/).
/// See `get_by_str_path/2` in the Elixir-side docs for examples.
#[rustler::nif(schedule = "DirtyCpu")]
fn get_by_str_path(doc: ResourceArc<DocResource>, path: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    match guard.get_by_str_path(&path) {
        Some(voc) => serde_json::to_string(&voc.get_deep_value()).map_err(json_err_to_nif),
        None => Ok("null".to_string()),
    }
}

/// Run a JSON-path query and return all matches as a JSON array
/// string. An empty array means no matches; `:invalid_path` means
/// the expression itself didn't parse.
#[rustler::nif(schedule = "DirtyCpu")]
fn jsonpath(doc: ResourceArc<DocResource>, path: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let results = guard
        .jsonpath(&path)
        .map_err(|e| NifError::Term(Box::new((atoms::invalid_path(), format!("{e:?}")))))?;

    let json_arr: Vec<serde_json::Value> = results
        .iter()
        .map(|voc| serde_json::to_value(voc.get_deep_value()).unwrap_or(serde_json::Value::Null))
        .collect();

    serde_json::to_string(&serde_json::Value::Array(json_arr)).map_err(json_err_to_nif)
}

// ---------------------------------------------------------------------------
// Memory hygiene
// ---------------------------------------------------------------------------

/// Drop the cached history index. The doc still works correctly; the
/// next history-traversing op rebuilds the index lazily.
#[rustler::nif(schedule = "DirtyCpu")]
fn free_history_cache(doc: ResourceArc<DocResource>) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.free_history_cache();
    Ok(atoms::ok())
}

/// Drop the cached structured-diff calculator. Same caveat as
/// `free_history_cache/1` — the next diff-emitting op rebuilds it.
#[rustler::nif(schedule = "DirtyCpu")]
fn free_diff_calculator(doc: ResourceArc<DocResource>) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.free_diff_calculator();
    Ok(atoms::ok())
}

/// Compact the change store, releasing unused capacity. Cheap to call
/// periodically on long-lived doc handles.
#[rustler::nif(schedule = "DirtyCpu")]
fn compact_change_store(doc: ResourceArc<DocResource>) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.compact_change_store();
    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// Text (plain)
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn get_text(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(get_text_handle(&guard, &container_id).to_string())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn insert_text(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
    value: String,
) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let text = get_text_handle(&guard, &container_id);
    text.insert(pos as usize, &value).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn delete_text(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
    len: u32,
) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let text = get_text_handle(&guard, &container_id);
    text.delete(pos as usize, len as usize)
        .map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// Text (rich-text / Peritext)
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn text_mark(
    doc: ResourceArc<DocResource>,
    container_id: String,
    start: u32,
    end: u32,
    key: String,
    value_json: String,
) -> NifResult<Atom> {
    let value = parse_scalar_json(&value_json)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let text = get_text_handle(&guard, &container_id);
    text.mark(start as usize..end as usize, &key, value)
        .map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn text_unmark(
    doc: ResourceArc<DocResource>,
    container_id: String,
    start: u32,
    end: u32,
    key: String,
) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let text = get_text_handle(&guard, &container_id);
    text.unmark(start as usize..end as usize, &key)
        .map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn text_to_delta(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let text = get_text_handle(&guard, &container_id);
    let delta = text.to_delta();
    serde_json::to_string(&delta).map_err(json_err_to_nif)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn text_apply_delta(
    doc: ResourceArc<DocResource>,
    container_id: String,
    delta_json: String,
) -> NifResult<Atom> {
    let delta: Vec<TextDelta> = serde_json::from_str(&delta_json)
        .map_err(|e| NifError::Term(Box::new((atoms::invalid_delta(), format!("{e}")))))?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let text = get_text_handle(&guard, &container_id);
    text.apply_delta(&delta).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn text_get_richtext_value(
    doc: ResourceArc<DocResource>,
    container_id: String,
) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let text = get_text_handle(&guard, &container_id);
    let value = text.get_richtext_value();
    serde_json::to_string(&value).map_err(json_err_to_nif)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn text_len_unicode(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<u64> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(get_text_handle(&guard, &container_id).len_unicode() as u64)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn text_len_utf8(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<u64> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(get_text_handle(&guard, &container_id).len_utf8() as u64)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn text_len_utf16(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<u64> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(get_text_handle(&guard, &container_id).len_utf16() as u64)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn text_convert_pos(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
    from: Atom,
    to: Atom,
) -> NifResult<u64> {
    let from_ty = atom_to_postype(from)?;
    let to_ty = atom_to_postype(to)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let text = get_text_handle(&guard, &container_id);
    text.convert_pos(index as usize, from_ty, to_ty)
        .map(|v| v as u64)
        .ok_or_else(|| {
            NifError::Term(Box::new((
                atoms::out_of_bound(),
                "position is not at a valid boundary".to_string(),
            )))
        })
}

// ---------------------------------------------------------------------------
// Cursor
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn text_get_cursor<'a>(
    env: rustler::Env<'a>,
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
    side: Atom,
) -> NifResult<rustler::Term<'a>> {
    let side = atom_to_side(side)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let text = get_text_handle(&guard, &container_id);
    match text.get_cursor(pos as usize, side) {
        Some(cursor) => {
            let encoded = cursor.encode();
            let mut bin = rustler::NewBinary::new(env, encoded.len());
            bin.as_mut_slice().copy_from_slice(&encoded);
            let term: rustler::Term = bin.into();
            Ok(term)
        }
        None => Ok(rustler::types::atom::nil().to_term(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn list_get_cursor<'a>(
    env: rustler::Env<'a>,
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
    side: Atom,
) -> NifResult<rustler::Term<'a>> {
    let side = atom_to_side(side)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_list_handle(&guard, &container_id);
    match list.get_cursor(pos as usize, side) {
        Some(cursor) => {
            let encoded = cursor.encode();
            let mut bin = rustler::NewBinary::new(env, encoded.len());
            bin.as_mut_slice().copy_from_slice(&encoded);
            let term: rustler::Term = bin.into();
            Ok(term)
        }
        None => Ok(rustler::types::atom::nil().to_term(env)),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn cursor_resolve(doc: ResourceArc<DocResource>, cursor_bin: Binary) -> NifResult<(u64, Atom)> {
    let cursor = Cursor::decode(cursor_bin.as_slice())
        .map_err(|e| NifError::Term(Box::new((atoms::invalid_cursor(), format!("{e}")))))?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    match guard.get_cursor_pos(&cursor) {
        Ok(result) => Ok((result.current.pos as u64, side_to_atom(result.current.side))),
        Err(e) => {
            let reason = match e {
                loro::cursor::CannotFindRelativePosition::ContainerDeleted => {
                    atoms::container_deleted()
                }
                loro::cursor::CannotFindRelativePosition::HistoryCleared => {
                    atoms::history_cleared()
                }
                loro::cursor::CannotFindRelativePosition::IdNotFound => atoms::id_not_found(),
            };
            Err(NifError::Term(Box::new((reason, format!("{e}")))))
        }
    }
}

// ---------------------------------------------------------------------------
// Map
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn get_map_json(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let value = get_map_handle(&guard, &container_id).get_deep_value();
    serde_json::to_string(&value).map_err(json_err_to_nif)
}

/// Return the list of keys currently present in a map container.
/// O(n) in the map size but avoids the full deep-JSON-encode cost of
/// `get_map_json/2` when the caller only needs to iterate keys.
#[rustler::nif(schedule = "DirtyCpu")]
fn map_keys(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<Vec<String>> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = get_map_handle(&guard, &container_id);
    Ok(map.keys().map(|s| s.as_ref().to_string()).collect())
}

/// Return the number of entries in a map container. O(1) at the
/// CRDT layer — much cheaper than decoding `get_map_json/2` just to
/// count keys.
#[rustler::nif(schedule = "DirtyCpu")]
fn map_size(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<u32> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = get_map_handle(&guard, &container_id);
    Ok(map.len() as u32)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn map_set(
    doc: ResourceArc<DocResource>,
    container_id: String,
    key: String,
    value_json: String,
) -> NifResult<Atom> {
    let loro_value = parse_scalar_json(&value_json)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = get_map_handle(&guard, &container_id);
    map.insert(&key, loro_value).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn map_delete(doc: ResourceArc<DocResource>, container_id: String, key: String) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = get_map_handle(&guard, &container_id);
    map.delete(&key).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn map_get_json(
    doc: ResourceArc<DocResource>,
    container_id: String,
    key: String,
) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = get_map_handle(&guard, &container_id);
    match map.get_deep_value() {
        LoroValue::Map(m) => {
            let v = m.get(key.as_str()).cloned().unwrap_or(LoroValue::Null);
            serde_json::to_string(&v).map_err(json_err_to_nif)
        }
        _ => Ok("null".to_string()),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn map_insert_container(
    doc: ResourceArc<DocResource>,
    container_id: String,
    key: String,
    kind: Atom,
) -> NifResult<String> {
    use loro::ContainerTrait;
    let kind = atom_to_container_type(kind)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = get_map_handle(&guard, &container_id);
    let cid_str = match kind {
        ContainerType::Text => map
            .insert_container(&key, loro::LoroText::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::Map => map
            .insert_container(&key, loro::LoroMap::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::List => map
            .insert_container(&key, loro::LoroList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::MovableList => map
            .insert_container(&key, loro::LoroMovableList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        _ => {
            return Err(invalid_value_err(
                "only :text | :map | :list | :movable_list are supported",
            ));
        }
    };
    guard.commit();
    Ok(cid_str)
}

/// Idempotent, race-free "ensure a child container exists at this
/// key" for maps.
///
/// Semantics:
/// * If `map[key]` already holds a container of the requested kind,
///   return its CID unchanged.
/// * If `map[key]` holds a container of a **different** kind, return
///   `{:invalid_container_kind, _}` — we never silently coerce a
///   container's kind.
/// * If `map[key]` holds a scalar value, return `{:invalid_value, _}`
///   — we never clobber existing data.
/// * If `map[key]` is absent, insert a new container of the
///   requested kind and return its CID.
///
/// The check-then-insert happens under a single lock of the doc's
/// mutex so there's no window where two callers can race and both
/// insert. Replaces the non-atomic dance
/// `map_get_child_cid || map_insert_container`.
#[rustler::nif(schedule = "DirtyCpu")]
fn map_get_or_create_container(
    doc: ResourceArc<DocResource>,
    container_id: String,
    key: String,
    kind: Atom,
) -> NifResult<String> {
    use loro::{Container, ContainerTrait};

    let requested = atom_to_container_type(kind)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = get_map_handle(&guard, &container_id);

    // Existing entry at `key`?
    if let Some(existing) = map.get(&key) {
        match existing {
            ValueOrContainer::Container(c) => {
                let actual = match &c {
                    Container::Text(_) => ContainerType::Text,
                    Container::Map(_) => ContainerType::Map,
                    Container::List(_) => ContainerType::List,
                    Container::MovableList(_) => ContainerType::MovableList,
                    Container::Tree(_) => ContainerType::Tree,
                    _ => {
                        return Err(invalid_value_err(
                            "existing child has an unsupported container kind",
                        ));
                    }
                };
                if actual != requested {
                    return Err(NifError::Term(Box::new((
                        atoms::invalid_container_kind(),
                        format!(
                            "key {:?} already holds a {:?} container, requested {:?}",
                            key, actual, requested
                        ),
                    ))));
                }
                return Ok(c.id().to_string());
            }
            ValueOrContainer::Value(_) => {
                return Err(invalid_value_err(
                    "key already holds a scalar value; refusing to clobber",
                ));
            }
        }
    }

    // Absent → insert a new container.
    let cid_str = match requested {
        ContainerType::Text => map
            .insert_container(&key, loro::LoroText::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::Map => map
            .insert_container(&key, loro::LoroMap::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::List => map
            .insert_container(&key, loro::LoroList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::MovableList => map
            .insert_container(&key, loro::LoroMovableList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        _ => {
            return Err(invalid_value_err(
                "only :text | :map | :list | :movable_list are supported",
            ));
        }
    };
    guard.commit();
    Ok(cid_str)
}

/// Return the child container's ID for `map[key]`, or `None` if the
/// value at that key is a scalar, absent, or the map itself is
/// detached. Enables path-based descent into nested container
/// structures without going through `get_deep_value`, which strips
/// container IDs.
#[rustler::nif(schedule = "DirtyCpu")]
fn map_get_child_cid(
    doc: ResourceArc<DocResource>,
    container_id: String,
    key: String,
) -> NifResult<Option<String>> {
    use loro::ContainerTrait;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = get_map_handle(&guard, &container_id);

    Ok(match map.get(&key) {
        Some(ValueOrContainer::Container(c)) => Some(c.id().to_string()),
        _ => None,
    })
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn list_get_json(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let value = get_list_handle(&guard, &container_id).get_deep_value();
    serde_json::to_string(&value).map_err(json_err_to_nif)
}

/// Return the number of elements in a list container. O(1) at the
/// CRDT layer — much cheaper than decoding `list_get_json/2` just to
/// count.
#[rustler::nif(schedule = "DirtyCpu")]
fn list_length(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<u32> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_list_handle(&guard, &container_id);
    Ok(list.len() as u32)
}

/// Return the value at `list[index]` as a JSON string. Returns the
/// literal `"null"` if the index is out of bounds, matching
/// `map_get_json/3`'s missing-key behavior.
///
/// For container children, returns the deep value (same shape as
/// `list_get_json/2` for the sub-tree). Use `list_get_child_cid/3`
/// to recover the CID for further writes.
#[rustler::nif(schedule = "DirtyCpu")]
fn list_get_json_at(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_list_handle(&guard, &container_id);
    match list.get(index as usize) {
        Some(v) => serde_json::to_string(&v.get_deep_value()).map_err(json_err_to_nif),
        None => Ok("null".to_string()),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn list_push(
    doc: ResourceArc<DocResource>,
    container_id: String,
    value_json: String,
) -> NifResult<Atom> {
    let loro_value = parse_scalar_json(&value_json)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_list_handle(&guard, &container_id);
    list.push(loro_value).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

/// Insert a JSON value at `pos` in a list container (shifts tail).
/// Accepts the same values as `list_push` (scalars + objects +
/// arrays). For nested containers, use `list_insert_container/4`.
///
/// Errors with `:out_of_bound` if `pos > list.len()`.
#[rustler::nif(schedule = "DirtyCpu")]
fn list_insert(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
    value_json: String,
) -> NifResult<Atom> {
    let loro_value = parse_scalar_json(&value_json)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_list_handle(&guard, &container_id);
    list.insert(pos as usize, loro_value)
        .map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn list_delete(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
    len: u32,
) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_list_handle(&guard, &container_id);
    list.delete(index as usize, len as usize)
        .map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn list_insert_container(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
    kind: Atom,
) -> NifResult<String> {
    use loro::ContainerTrait;
    let kind = atom_to_container_type(kind)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_list_handle(&guard, &container_id);
    let p = pos as usize;
    let cid_str = match kind {
        ContainerType::Text => list
            .insert_container(p, loro::LoroText::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::Map => list
            .insert_container(p, loro::LoroMap::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::List => list
            .insert_container(p, loro::LoroList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::MovableList => list
            .insert_container(p, loro::LoroMovableList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        _ => {
            return Err(invalid_value_err(
                "only :text | :map | :list | :movable_list are supported",
            ));
        }
    };
    guard.commit();
    Ok(cid_str)
}

/// Idempotent, race-free "ensure a child container" for lists.
///
/// Semantics:
/// * If `index < list.len()` and `list[index]` is a container of the
///   requested kind → return its CID unchanged.
/// * If `index < list.len()` and `list[index]` is a container of a
///   different kind → `{:invalid_container_kind, _}`.
/// * If `index < list.len()` and `list[index]` is a scalar value →
///   `{:invalid_value, _}` — we never clobber existing data.
/// * If `index == list.len()` → insert a new container of the
///   requested kind **at the end** and return its CID.
///   (This is the natural "append if missing" case for appending
///   blocks to a child list.)
/// * If `index > list.len()` → `{:out_of_bound, _}`.
///
/// The check-then-insert happens under a single doc-mutex lock.
/// Replaces the non-atomic dance
/// `list_get_child_cid || list_insert_container`.
///
/// Note: lists don't have stable keys across insertions, so this
/// operation is less "natural" than the map variant. Use it when you
/// know the intended shape — typically for idempotent creation of
/// block-at-position-0 during hydration.
#[rustler::nif(schedule = "DirtyCpu")]
fn list_get_or_create_container(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
    kind: Atom,
) -> NifResult<String> {
    use loro::{Container, ContainerTrait};

    let requested = atom_to_container_type(kind)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_list_handle(&guard, &container_id);
    let idx = index as usize;
    let len = list.len();

    if idx < len {
        match list.get(idx) {
            Some(ValueOrContainer::Container(c)) => {
                let actual = match &c {
                    Container::Text(_) => ContainerType::Text,
                    Container::Map(_) => ContainerType::Map,
                    Container::List(_) => ContainerType::List,
                    Container::MovableList(_) => ContainerType::MovableList,
                    Container::Tree(_) => ContainerType::Tree,
                    _ => {
                        return Err(invalid_value_err(
                            "existing child has an unsupported container kind",
                        ));
                    }
                };
                if actual != requested {
                    return Err(NifError::Term(Box::new((
                        atoms::invalid_container_kind(),
                        format!(
                            "index {} already holds a {:?} container, requested {:?}",
                            idx, actual, requested
                        ),
                    ))));
                }
                return Ok(c.id().to_string());
            }
            Some(ValueOrContainer::Value(_)) => {
                return Err(invalid_value_err(
                    "index already holds a scalar value; refusing to clobber",
                ));
            }
            None => {
                // Should be unreachable given idx < len, but fall through
                // to the append-at-end branch defensively.
            }
        }
    } else if idx > len {
        return Err(NifError::Term(Box::new((
            atoms::out_of_bound(),
            format!("index {} > len {}", idx, len),
        ))));
    }

    // idx == len → insert a new container at the end.
    let cid_str = match requested {
        ContainerType::Text => list
            .insert_container(len, loro::LoroText::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::Map => list
            .insert_container(len, loro::LoroMap::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::List => list
            .insert_container(len, loro::LoroList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::MovableList => list
            .insert_container(len, loro::LoroMovableList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        _ => {
            return Err(invalid_value_err(
                "only :text | :map | :list | :movable_list are supported",
            ));
        }
    };
    guard.commit();
    Ok(cid_str)
}

/// Return the child container's ID for `list[index]`, or `None` if the
/// value at that index is a scalar or the index is out of bounds.
/// Bounds are not treated as an error — callers that want to
/// distinguish "missing" from "scalar present" can cross-check against
/// `list_get_json`'s length.
#[rustler::nif(schedule = "DirtyCpu")]
fn list_get_child_cid(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
) -> NifResult<Option<String>> {
    use loro::ContainerTrait;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_list_handle(&guard, &container_id);

    Ok(match list.get(index as usize) {
        Some(ValueOrContainer::Container(c)) => Some(c.id().to_string()),
        _ => None,
    })
}

// ---------------------------------------------------------------------------
// MovableList
// ---------------------------------------------------------------------------
//
// Mirrors the List surface plus the MovableList-only ops:
//   * `mov` (move an element from one index to another, preserving identity)
//   * `set` / `set_container` (replace value at index in place)
//   * `pop`, `clear` (convenience)
//   * `get_creator_at` / `get_last_mover_at` / `get_last_editor_at`
//     (peer attribution telemetry — MovableList tracks per-element history)
//
// These ops are why MovableList exists: a plain List can't express
// "move this element" without losing its identity to the Peritext-style
// merger. MovableList does, so concurrent moves converge.

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_get_json(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let value = get_movable_list_handle(&guard, &container_id).get_deep_value();
    serde_json::to_string(&value).map_err(json_err_to_nif)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_length(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<u32> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(get_movable_list_handle(&guard, &container_id).len() as u32)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_get_json_at(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    match list.get(index as usize) {
        Some(v) => serde_json::to_string(&v.get_deep_value()).map_err(json_err_to_nif),
        None => Ok("null".to_string()),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_push(
    doc: ResourceArc<DocResource>,
    container_id: String,
    value_json: String,
) -> NifResult<Atom> {
    let value = parse_scalar_json(&value_json)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    list.push(value).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_insert(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
    value_json: String,
) -> NifResult<Atom> {
    let value = parse_scalar_json(&value_json)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    list.insert(pos as usize, value).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

/// Replace the scalar value at `index`. MovableList-only — plain
/// List lacks a set-by-index op.
#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_set(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
    value_json: String,
) -> NifResult<Atom> {
    let value = parse_scalar_json(&value_json)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    list.set(index as usize, value).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

/// Move the element at `from` to `to`. MovableList-only — the
/// headline feature that distinguishes it from List. Identity is
/// preserved across the move so concurrent moves of the same
/// element converge.
#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_move(
    doc: ResourceArc<DocResource>,
    container_id: String,
    from: u32,
    to: u32,
) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    list.mov(from as usize, to as usize)
        .map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_delete(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
    len: u32,
) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    list.delete(index as usize, len as usize)
        .map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

/// Pop the last element. Returns `null` JSON for an empty list,
/// otherwise the deep JSON value of what was removed.
#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_pop(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    let popped = list.pop().map_err(loro_err_to_nif)?;
    guard.commit();
    match popped {
        Some(v) => serde_json::to_string(&v.get_deep_value()).map_err(json_err_to_nif),
        None => Ok("null".to_string()),
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_clear(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    list.clear().map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_insert_container(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
    kind: Atom,
) -> NifResult<String> {
    use loro::ContainerTrait;
    let kind = atom_to_container_type(kind)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    let p = pos as usize;
    let cid_str = match kind {
        ContainerType::Text => list
            .insert_container(p, loro::LoroText::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::Map => list
            .insert_container(p, loro::LoroMap::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::List => list
            .insert_container(p, loro::LoroList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::MovableList => list
            .insert_container(p, loro::LoroMovableList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        _ => {
            return Err(invalid_value_err(
                "only :text | :map | :list | :movable_list are supported",
            ));
        }
    };
    guard.commit();
    Ok(cid_str)
}

/// Replace the value at `index` with a fresh container of the given
/// kind. MovableList-only.
#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_set_container(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
    kind: Atom,
) -> NifResult<String> {
    use loro::ContainerTrait;
    let kind = atom_to_container_type(kind)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    let i = index as usize;
    let cid_str = match kind {
        ContainerType::Text => list
            .set_container(i, loro::LoroText::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::Map => list
            .set_container(i, loro::LoroMap::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::List => list
            .set_container(i, loro::LoroList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::MovableList => list
            .set_container(i, loro::LoroMovableList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        _ => {
            return Err(invalid_value_err(
                "only :text | :map | :list | :movable_list are supported",
            ));
        }
    };
    guard.commit();
    Ok(cid_str)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_get_or_create_container(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
    kind: Atom,
) -> NifResult<String> {
    use loro::{Container, ContainerTrait};

    let requested = atom_to_container_type(kind)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    let idx = index as usize;
    let len = list.len();

    if idx < len {
        match list.get(idx) {
            Some(ValueOrContainer::Container(c)) => {
                let actual = match &c {
                    Container::Text(_) => ContainerType::Text,
                    Container::Map(_) => ContainerType::Map,
                    Container::List(_) => ContainerType::List,
                    Container::MovableList(_) => ContainerType::MovableList,
                    Container::Tree(_) => ContainerType::Tree,
                    _ => {
                        return Err(invalid_value_err(
                            "existing child has an unsupported container kind",
                        ));
                    }
                };
                if actual != requested {
                    return Err(NifError::Term(Box::new((
                        atoms::invalid_container_kind(),
                        format!(
                            "index {} already holds a {:?} container, requested {:?}",
                            idx, actual, requested
                        ),
                    ))));
                }
                return Ok(c.id().to_string());
            }
            Some(ValueOrContainer::Value(_)) => {
                return Err(invalid_value_err(
                    "index already holds a scalar value; refusing to clobber",
                ));
            }
            None => {}
        }
    } else if idx > len {
        return Err(NifError::Term(Box::new((
            atoms::out_of_bound(),
            format!("index {} > len {}", idx, len),
        ))));
    }

    // idx == len → insert at the end.
    let cid_str = match requested {
        ContainerType::Text => list
            .insert_container(len, loro::LoroText::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::Map => list
            .insert_container(len, loro::LoroMap::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::List => list
            .insert_container(len, loro::LoroList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        ContainerType::MovableList => list
            .insert_container(len, loro::LoroMovableList::new())
            .map_err(loro_err_to_nif)?
            .id()
            .to_string(),
        _ => {
            return Err(invalid_value_err(
                "only :text | :map | :list | :movable_list are supported",
            ));
        }
    };
    guard.commit();
    Ok(cid_str)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_get_child_cid(
    doc: ResourceArc<DocResource>,
    container_id: String,
    index: u32,
) -> NifResult<Option<String>> {
    use loro::ContainerTrait;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    Ok(match list.get(index as usize) {
        Some(ValueOrContainer::Container(c)) => Some(c.id().to_string()),
        _ => None,
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_get_cursor<'a>(
    env: rustler::Env<'a>,
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
    side: Atom,
) -> NifResult<rustler::Term<'a>> {
    let side = atom_to_side(side)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    match list.get_cursor(pos as usize, side) {
        Some(cursor) => {
            let encoded = cursor.encode();
            let mut bin = rustler::NewBinary::new(env, encoded.len());
            bin.as_mut_slice().copy_from_slice(&encoded);
            let term: rustler::Term = bin.into();
            Ok(term)
        }
        None => Ok(rustler::types::atom::nil().to_term(env)),
    }
}

/// Peer id of the peer that originally inserted the element at `pos`.
/// Returns `nil` if the index is out of bounds. Useful for attribution
/// UIs ("X added this row").
#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_get_creator_at(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
) -> NifResult<Option<u64>> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    Ok(list.get_creator_at(pos as usize))
}

/// Peer id of the peer that last moved the element at `pos`. Different
/// from `creator_at` because elements keep identity across moves.
#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_get_last_mover_at(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
) -> NifResult<Option<u64>> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    Ok(list.get_last_mover_at(pos as usize))
}

/// Peer id of the peer that last `set`/`set_container`'d the element
/// at `pos`. Distinct from creator and mover.
#[rustler::nif(schedule = "DirtyCpu")]
fn movable_list_get_last_editor_at(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
) -> NifResult<Option<u64>> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = get_movable_list_handle(&guard, &container_id);
    Ok(list.get_last_editor_at(pos as usize))
}

// ---------------------------------------------------------------------------
// Tree
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn tree_create_node(
    doc: ResourceArc<DocResource>,
    tree_id: String,
    parent_id: Option<String>,
) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    ensure_tree_ready(&tree);
    let parent: Option<TreeID> = match parent_id {
        Some(p) => Some(parse_tree_id(&p)?),
        None => None,
    };
    let node_id = tree.create(parent).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(node_id.to_string())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tree_move_node(
    doc: ResourceArc<DocResource>,
    tree_id: String,
    node_id: String,
    new_parent_id: Option<String>,
    index: u32,
) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    ensure_tree_ready(&tree);
    let node = parse_tree_id(&node_id)?;
    let parent: Option<TreeID> = match new_parent_id {
        Some(p) => Some(parse_tree_id(&p)?),
        None => None,
    };
    tree.mov_to(node, parent, index as usize)
        .map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tree_delete_node(
    doc: ResourceArc<DocResource>,
    tree_id: String,
    node_id: String,
) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    let node = parse_tree_id(&node_id)?;
    tree.delete(node).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tree_get_nodes(doc: ResourceArc<DocResource>, tree_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let value = get_tree_handle(&guard, &tree_id).get_value();
    serde_json::to_string(&value).map_err(json_err_to_nif)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tree_get_meta(
    doc: ResourceArc<DocResource>,
    tree_id: String,
    node_id: String,
) -> NifResult<String> {
    use loro::ContainerTrait;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    let node = parse_tree_id(&node_id)?;
    let meta_map = tree.get_meta(node).map_err(loro_err_to_nif)?;
    Ok(meta_map.id().to_string())
}

/// Return the parent of `node_id` projected as one of:
///   * `{:ok, parent_id_string}` — a real parent node
///   * `:root` — the node is at the top level
///   * `:deleted` — the node's parent has been deleted
///   * `:unexist` — `node_id` parses but never existed in this tree
///
/// Errors with `:tree_node_not_found` if `node_id` is not a valid
/// tree-id format.
#[rustler::nif(schedule = "DirtyCpu")]
fn tree_parent<'a>(
    env: rustler::Env<'a>,
    doc: ResourceArc<DocResource>,
    tree_id: String,
    node_id: String,
) -> NifResult<rustler::Term<'a>> {
    use loro::TreeParentId;
    let node = parse_tree_id(&node_id)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    match tree.parent(node) {
        Some(TreeParentId::Node(id)) => Ok((atoms::ok(), id.to_string()).encode(env)),
        Some(TreeParentId::Root) => Ok(atoms::root().encode(env)),
        Some(TreeParentId::Deleted) => Ok(atoms::deleted().encode(env)),
        Some(TreeParentId::Unexist) => Ok(atoms::unexist().encode(env)),
        None => Err(NifError::Term(Box::new((
            atoms::tree_node_not_found(),
            format!("node {node_id} not found in tree"),
        )))),
    }
}

/// Return the children of `parent_id` (or root children if
/// `parent_id` is `nil`). `nil` and missing parents both produce an
/// empty list — pass an explicit string id to disambiguate.
#[rustler::nif(schedule = "DirtyCpu")]
fn tree_children(
    doc: ResourceArc<DocResource>,
    tree_id: String,
    parent_id: Option<String>,
) -> NifResult<Vec<String>> {
    use loro::TreeParentId;
    let parent = match parent_id {
        Some(s) => TreeParentId::Node(parse_tree_id(&s)?),
        None => TreeParentId::Root,
    };
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    Ok(tree
        .children(parent)
        .unwrap_or_default()
        .into_iter()
        .map(|id| id.to_string())
        .collect())
}

/// Number of direct children under `parent_id` (or root if `nil`).
/// Returns `0` for a non-existent parent — symmetric with
/// `tree_children/3`.
#[rustler::nif(schedule = "DirtyCpu")]
fn tree_children_num(
    doc: ResourceArc<DocResource>,
    tree_id: String,
    parent_id: Option<String>,
) -> NifResult<u32> {
    use loro::TreeParentId;
    let parent = match parent_id {
        Some(s) => TreeParentId::Node(parse_tree_id(&s)?),
        None => TreeParentId::Root,
    };
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    Ok(tree.children_num(parent).unwrap_or(0) as u32)
}

/// All root-level node ids in the tree.
#[rustler::nif(schedule = "DirtyCpu")]
fn tree_roots(doc: ResourceArc<DocResource>, tree_id: String) -> NifResult<Vec<String>> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    Ok(tree.roots().into_iter().map(|id| id.to_string()).collect())
}

/// `true` if `node_id` is currently a live (non-deleted) node in the
/// tree.
#[rustler::nif(schedule = "DirtyCpu")]
fn tree_contains(
    doc: ResourceArc<DocResource>,
    tree_id: String,
    node_id: String,
) -> NifResult<bool> {
    let node = parse_tree_id(&node_id)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    Ok(tree.contains(node))
}

/// `true` if `node_id` was created and subsequently deleted.
/// Errors with `:tree_node_not_found` if `node_id` never existed.
#[rustler::nif(schedule = "DirtyCpu")]
fn tree_is_node_deleted(
    doc: ResourceArc<DocResource>,
    tree_id: String,
    node_id: String,
) -> NifResult<bool> {
    let node = parse_tree_id(&node_id)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    tree.is_node_deleted(&node).map_err(loro_err_to_nif)
}

/// Fractional index string for `node_id`, or `nil` if the tree was
/// not configured to maintain fractional indexes.
#[rustler::nif(schedule = "DirtyCpu")]
fn tree_fractional_index(
    doc: ResourceArc<DocResource>,
    tree_id: String,
    node_id: String,
) -> NifResult<Option<String>> {
    let node = parse_tree_id(&node_id)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = get_tree_handle(&guard, &tree_id);
    Ok(tree.fractional_index(node))
}

/// Return the tree as a JSON string with each node's meta inlined.
/// Distinct from `tree_get_nodes/2` which returns just the structural
/// shape without the per-node metadata.
#[rustler::nif(schedule = "DirtyCpu")]
fn tree_get_value_with_meta(doc: ResourceArc<DocResource>, tree_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let value = get_tree_handle(&guard, &tree_id).get_value_with_meta();
    serde_json::to_string(&value).map_err(json_err_to_nif)
}

// ---------------------------------------------------------------------------
// Local-update subscriptions
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn subscribe(
    doc: ResourceArc<DocResource>,
    pid: LocalPid,
) -> NifResult<ResourceArc<SubscriptionResource>> {
    let sub_resource = ResourceArc::new(SubscriptionResource {
        inner: Mutex::new(None),
    });
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let sub_for_callback = sub_resource.clone();
    let subscription = guard.subscribe_local_update(Box::new(move |update_bytes: &Vec<u8>| {
        let target = pid;
        let bytes = update_bytes.clone();
        let sub_ref = sub_for_callback.clone();
        std::thread::spawn(move || {
            let mut msg_env = OwnedEnv::new();
            let _ = msg_env.send_and_clear(&target, |env| {
                let mut new_bin = rustler::NewBinary::new(env, bytes.len());
                new_bin.as_mut_slice().copy_from_slice(&bytes);
                let bin_term: rustler::Term = new_bin.into();
                (atoms::loro_event(), sub_ref, bin_term).encode(env)
            });
        });
        true
    }));
    if let Ok(mut slot) = sub_resource.inner.lock() {
        *slot = Some(subscription);
    } else {
        return Err(poisoned_to_nif());
    }
    Ok(sub_resource)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn unsubscribe(sub: ResourceArc<SubscriptionResource>) -> NifResult<Atom> {
    let mut slot = sub.inner.lock().map_err(|_| poisoned_to_nif())?;
    *slot = None;
    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// Structured diff subscriptions
// ---------------------------------------------------------------------------

fn serialize_diff_events(events: &[loro::event::ContainerDiff<'_>]) -> serde_json::Value {
    let mut arr: Vec<serde_json::Value> = Vec::with_capacity(events.len());
    for ev in events {
        let path: Vec<serde_json::Value> = ev
            .path
            .iter()
            .map(|(cid, idx)| serde_json::json!([cid.to_string(), index_to_json(idx)]))
            .collect();
        let diff_json = match &ev.diff {
            loro::event::Diff::Text(deltas) => {
                serde_json::json!({
                    "type": "text",
                    "ops": serde_json::to_value(deltas).unwrap_or(serde_json::Value::Null),
                })
            }
            loro::event::Diff::Map(map_delta) => {
                let updated: serde_json::Map<String, serde_json::Value> = map_delta
                    .updated
                    .iter()
                    .map(|(k, v)| {
                        let val = match v {
                            Some(voc) => serde_json::to_value(voc.get_deep_value())
                                .unwrap_or(serde_json::Value::Null),
                            None => serde_json::Value::Null,
                        };
                        (k.to_string(), val)
                    })
                    .collect();
                serde_json::json!({"type": "map", "updated": updated})
            }
            loro::event::Diff::List(items) => {
                let ops: Vec<serde_json::Value> = items
                    .iter()
                    .map(|item| match item {
                        loro::event::ListDiffItem::Insert { insert, is_move } => {
                            let vals: Vec<serde_json::Value> = insert
                                .iter()
                                .map(|voc| {
                                    serde_json::to_value(voc.get_deep_value())
                                        .unwrap_or(serde_json::Value::Null)
                                })
                                .collect();
                            serde_json::json!({"insert": vals, "is_move": is_move})
                        }
                        loro::event::ListDiffItem::Delete { delete } => {
                            serde_json::json!({"delete": delete})
                        }
                        loro::event::ListDiffItem::Retain { retain } => {
                            serde_json::json!({"retain": retain})
                        }
                    })
                    .collect();
                serde_json::json!({"type": "list", "ops": ops})
            }
            loro::event::Diff::Tree(tree_diff) => {
                let items: Vec<serde_json::Value> = tree_diff
                    .as_ref()
                    .diff
                    .iter()
                    .map(serialize_tree_diff_item)
                    .collect();
                serde_json::json!({"type": "tree", "diff": items})
            }
            loro::event::Diff::Counter(n) => {
                serde_json::json!({"type": "counter", "delta": n})
            }
            loro::event::Diff::Unknown => serde_json::json!({"type": "unknown"}),
        };
        arr.push(serde_json::json!({
            "target": ev.target.to_string(),
            "path": path,
            "diff": diff_json,
        }));
    }
    serde_json::Value::Array(arr)
}

fn index_to_json(idx: &loro::Index) -> serde_json::Value {
    match idx {
        loro::Index::Key(k) => serde_json::Value::String(k.to_string()),
        loro::Index::Seq(n) => serde_json::Value::from(*n as u64),
        loro::Index::Node(t) => serde_json::Value::String(t.to_string()),
    }
}

fn serialize_tree_diff_item(item: &loro::TreeDiffItem) -> serde_json::Value {
    use loro::TreeExternalDiff;
    let target = item.target.to_string();
    match &item.action {
        TreeExternalDiff::Create {
            parent,
            index,
            position,
        } => serde_json::json!({
            "target": target,
            "action": "create",
            "parent": tree_parent_to_json(parent),
            "index": *index as u64,
            "position": position.to_string(),
        }),
        TreeExternalDiff::Move {
            parent,
            index,
            position,
            old_parent,
            old_index,
        } => serde_json::json!({
            "target": target,
            "action": "move",
            "parent": tree_parent_to_json(parent),
            "index": *index as u64,
            "position": position.to_string(),
            "old_parent": tree_parent_to_json(old_parent),
            "old_index": *old_index as u64,
        }),
        TreeExternalDiff::Delete {
            old_parent,
            old_index,
        } => serde_json::json!({
            "target": target,
            "action": "delete",
            "old_parent": tree_parent_to_json(old_parent),
            "old_index": *old_index as u64,
        }),
    }
}

fn tree_parent_to_json(p: &loro::TreeParentId) -> serde_json::Value {
    match p {
        loro::TreeParentId::Node(id) => serde_json::Value::String(id.to_string()),
        loro::TreeParentId::Root => serde_json::Value::Null,
        loro::TreeParentId::Deleted => serde_json::Value::String("__deleted__".to_string()),
        loro::TreeParentId::Unexist => serde_json::Value::String("__unexist__".to_string()),
    }
}

fn deliver_diff_event(
    target: LocalPid,
    sub_ref: ResourceArc<SubscriptionResource>,
    events_value: serde_json::Value,
) {
    std::thread::spawn(move || {
        let Ok(json_str) = serde_json::to_string(&events_value) else {
            return;
        };
        let mut msg_env = OwnedEnv::new();
        let _ = msg_env.send_and_clear(&target, |env| {
            let mut bin = rustler::NewBinary::new(env, json_str.len());
            bin.as_mut_slice().copy_from_slice(json_str.as_bytes());
            let bin_term: rustler::Term = bin.into();
            (atoms::loro_diff(), sub_ref, bin_term).encode(env)
        });
    });
}

#[rustler::nif(schedule = "DirtyCpu")]
fn subscribe_container(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pid: LocalPid,
) -> NifResult<ResourceArc<SubscriptionResource>> {
    let cid = ContainerID::try_from(container_id.as_str()).or_else(|_| {
        let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
        let candidates = [
            ContainerID::new_root(&container_id, ContainerType::Text),
            ContainerID::new_root(&container_id, ContainerType::Map),
            ContainerID::new_root(&container_id, ContainerType::List),
            ContainerID::new_root(&container_id, ContainerType::MovableList),
            ContainerID::new_root(&container_id, ContainerType::Tree),
        ];
        for c in candidates {
            if guard.has_container(&c) {
                return Ok::<_, NifError>(c);
            }
        }
        Err(NifError::Term(Box::new((
            atoms::not_found(),
            format!("container {container_id} not found"),
        ))))
    })?;

    let sub_resource = ResourceArc::new(SubscriptionResource {
        inner: Mutex::new(None),
    });
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let sub_for_callback = sub_resource.clone();
    let subscription = guard.subscribe(
        &cid,
        std::sync::Arc::new(move |event: loro::event::DiffEvent| {
            let events_value = serialize_diff_events(&event.events);
            deliver_diff_event(pid, sub_for_callback.clone(), events_value);
        }),
    );
    if let Ok(mut slot) = sub_resource.inner.lock() {
        *slot = Some(subscription);
    }
    Ok(sub_resource)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn subscribe_root(
    doc: ResourceArc<DocResource>,
    pid: LocalPid,
) -> NifResult<ResourceArc<SubscriptionResource>> {
    let sub_resource = ResourceArc::new(SubscriptionResource {
        inner: Mutex::new(None),
    });
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let sub_for_callback = sub_resource.clone();
    let subscription =
        guard.subscribe_root(std::sync::Arc::new(move |event: loro::event::DiffEvent| {
            let events_value = serialize_diff_events(&event.events);
            deliver_diff_event(pid, sub_for_callback.clone(), events_value);
        }));
    if let Ok(mut slot) = sub_resource.inner.lock() {
        *slot = Some(subscription);
    }
    Ok(sub_resource)
}

// ---------------------------------------------------------------------------
// UndoManager
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn undo_manager_new(doc: ResourceArc<DocResource>) -> NifResult<ResourceArc<UndoResource>> {
    let manager = {
        let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
        UndoManager::new(&guard)
    };
    Ok(ResourceArc::new(UndoResource {
        doc,
        inner: Mutex::new(manager),
    }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn undo_manager_undo(mgr: ResourceArc<UndoResource>) -> NifResult<bool> {
    let mut m = mgr.inner.lock().map_err(|_| poisoned_to_nif())?;
    m.undo().map_err(loro_err_to_nif)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn undo_manager_redo(mgr: ResourceArc<UndoResource>) -> NifResult<bool> {
    let mut m = mgr.inner.lock().map_err(|_| poisoned_to_nif())?;
    m.redo().map_err(loro_err_to_nif)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn undo_manager_can_undo(mgr: ResourceArc<UndoResource>) -> NifResult<bool> {
    let m = mgr.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(m.can_undo())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn undo_manager_can_redo(mgr: ResourceArc<UndoResource>) -> NifResult<bool> {
    let m = mgr.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(m.can_redo())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn undo_manager_record_new_checkpoint(mgr: ResourceArc<UndoResource>) -> NifResult<Atom> {
    let mut m = mgr.inner.lock().map_err(|_| poisoned_to_nif())?;
    m.record_new_checkpoint().map_err(loro_err_to_nif)?;
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn undo_manager_set_max_undo_steps(mgr: ResourceArc<UndoResource>, size: u32) -> NifResult<Atom> {
    let mut m = mgr.inner.lock().map_err(|_| poisoned_to_nif())?;
    m.set_max_undo_steps(size as usize);
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn undo_manager_set_merge_interval(
    mgr: ResourceArc<UndoResource>,
    interval_ms: i64,
) -> NifResult<Atom> {
    let mut m = mgr.inner.lock().map_err(|_| poisoned_to_nif())?;
    m.set_merge_interval(interval_ms);
    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// EphemeralStore
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_new(timeout_ms: i64) -> ResourceArc<EphemeralResource> {
    ResourceArc::new(EphemeralResource {
        inner: EphemeralStore::new(timeout_ms),
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_set(
    store: ResourceArc<EphemeralResource>,
    key: String,
    value_json: String,
) -> NifResult<Atom> {
    let value = parse_scalar_json(&value_json)?;
    store.inner.set(&key, value);
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_get(store: ResourceArc<EphemeralResource>, key: String) -> NifResult<String> {
    let val = store.inner.get(&key).unwrap_or(LoroValue::Null);
    serde_json::to_string(&val).map_err(json_err_to_nif)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_delete(store: ResourceArc<EphemeralResource>, key: String) -> NifResult<Atom> {
    store.inner.delete(&key);
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_keys(store: ResourceArc<EphemeralResource>) -> Vec<String> {
    store.inner.keys()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_get_all_states(store: ResourceArc<EphemeralResource>) -> NifResult<String> {
    let states = store.inner.get_all_states();
    let json_map: serde_json::Map<String, serde_json::Value> = states
        .into_iter()
        .map(|(k, v)| {
            (
                k,
                serde_json::to_value(v).unwrap_or(serde_json::Value::Null),
            )
        })
        .collect();
    serde_json::to_string(&serde_json::Value::Object(json_map)).map_err(json_err_to_nif)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_encode(store: ResourceArc<EphemeralResource>, key: String) -> NifResult<OwnedBinary> {
    bytes_to_owned_binary(&store.inner.encode(&key))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_encode_all(store: ResourceArc<EphemeralResource>) -> NifResult<OwnedBinary> {
    bytes_to_owned_binary(&store.inner.encode_all())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_apply(store: ResourceArc<EphemeralResource>, data: Binary) -> NifResult<Atom> {
    store
        .inner
        .apply(data.as_slice())
        .map_err(|e| NifError::Term(Box::new((atoms::ephemeral_apply_failed(), e.to_string()))))?;
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_remove_outdated(store: ResourceArc<EphemeralResource>) -> NifResult<Atom> {
    store.inner.remove_outdated();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn ephemeral_subscribe(
    store: ResourceArc<EphemeralResource>,
    pid: LocalPid,
) -> NifResult<ResourceArc<SubscriptionResource>> {
    let sub_resource = ResourceArc::new(SubscriptionResource {
        inner: Mutex::new(None),
    });
    let sub_for_callback = sub_resource.clone();
    let subscription = store
        .inner
        .subscribe_local_updates(Box::new(move |bytes: &Vec<u8>| {
            let target = pid;
            let data = bytes.clone();
            let sub_ref = sub_for_callback.clone();
            std::thread::spawn(move || {
                let mut msg_env = OwnedEnv::new();
                let _ = msg_env.send_and_clear(&target, |env| {
                    let mut new_bin = rustler::NewBinary::new(env, data.len());
                    new_bin.as_mut_slice().copy_from_slice(&data);
                    let bin_term: rustler::Term = new_bin.into();
                    (atoms::loro_ephemeral(), sub_ref, bin_term).encode(env)
                });
            });
            true
        }));
    if let Ok(mut slot) = sub_resource.inner.lock() {
        *slot = Some(subscription);
    }
    Ok(sub_resource)
}

// ---------------------------------------------------------------------------
// Module init
// ---------------------------------------------------------------------------

rustler::init!("Elixir.LoroEx.Native");
