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
//! 3. Version vectors cross the NIF boundary as opaque binaries produced by
//!    `oplog_version` / `state_vector`. Callers must treat them as opaque.
//!    Decoding happens inside Rust so Elixir can't mix them up.
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
    ExportMode, Frontiers, LoroDoc, LoroEncodeError, LoroError, LoroTreeError, LoroValue,
    Subscription, TreeID, VersionVector,
};

mod atoms {
    rustler::atoms! {
        ok,
        error,

        // Error reason atoms — map Loro's error enums onto stable atoms so
        // Elixir callers can pattern-match instead of parsing debug strings.
        invalid_update,
        invalid_version_vector,
        invalid_frontier,
        invalid_tree_id,
        invalid_peer_id,
        invalid_value,
        checksum_mismatch,
        incompatible_version,
        not_found,
        out_of_bound,
        cyclic_move,
        tree_node_not_found,
        fractional_index_not_enabled,
        index_out_of_bound,
        container_deleted,
        lock_poisoned,
        subscription_dropped,
        unknown,

        // Event tags delivered to subscriber pids.
        loro_event
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
        Self { inner: Mutex::new(doc) }
    }
}

#[rustler::resource_impl]
impl rustler::Resource for DocResource {}

/// Holds a Loro `Subscription` handle. Dropping it cancels the subscription.
/// Wrapped in `Mutex<Option<_>>` so `unsubscribe/1` can eagerly drop the
/// handle before the resource itself is garbage-collected.
pub struct SubscriptionResource {
    pub inner: Mutex<Option<Subscription>>,
}

#[rustler::resource_impl]
impl rustler::Resource for SubscriptionResource {}

// ---------------------------------------------------------------------------
// Error mapping
// ---------------------------------------------------------------------------

/// Convert a Loro error into a Rustler NIF error whose term shape is
/// `{reason_atom, debug_string}`. Elixir callers get `{:error, {atom, str}}`
/// and can match on the atom for control flow while keeping the string for
/// logs.
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
        LoroEncodeError::UnknownContainer => atoms::unknown(),
        LoroEncodeError::InternalError(_) => atoms::unknown(),
        // non_exhaustive enum — catch future variants
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
    NifError::Term(Box::new((atoms::lock_poisoned(), "doc mutex poisoned")))
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
    // Safe to call repeatedly — Loro dedupes.
    tree.enable_fractional_index(0);
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

// ---------------------------------------------------------------------------
// Sync primitives
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn apply_update(doc: ResourceArc<DocResource>, update: Binary) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    guard.import(update.as_slice()).map_err(loro_err_to_nif)?;
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn export_snapshot(doc: ResourceArc<DocResource>) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let bytes = guard.export(ExportMode::Snapshot).map_err(encode_err_to_nif)?;
    bytes_to_owned_binary(&bytes)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn export_shallow_snapshot(
    doc: ResourceArc<DocResource>,
    frontier: Binary,
) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let frontiers = Frontiers::decode(frontier.as_slice()).map_err(|e| {
        NifError::Term(Box::new((atoms::invalid_frontier(), format!("{e:?}"))))
    })?;
    let bytes = guard
        .export(ExportMode::shallow_snapshot(&frontiers))
        .map_err(encode_err_to_nif)?;
    bytes_to_owned_binary(&bytes)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn export_updates_from(
    doc: ResourceArc<DocResource>,
    version: Binary,
) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let vv = VersionVector::decode(version.as_slice()).map_err(loro_err_to_nif)?;
    let bytes = guard
        .export(ExportMode::updates(&vv))
        .map_err(encode_err_to_nif)?;
    bytes_to_owned_binary(&bytes)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn oplog_version(doc: ResourceArc<DocResource>) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let vv = guard.oplog_vv();
    bytes_to_owned_binary(&vv.encode())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn state_vector(doc: ResourceArc<DocResource>) -> NifResult<OwnedBinary> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let vv = guard.state_vv();
    bytes_to_owned_binary(&vv.encode())
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn get_text(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    Ok(guard.get_text(container_id.as_str()).to_string())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn insert_text(
    doc: ResourceArc<DocResource>,
    container_id: String,
    pos: u32,
    value: String,
) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let text = guard.get_text(container_id.as_str());
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
    let text = guard.get_text(container_id.as_str());
    text.delete(pos as usize, len as usize)
        .map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// Map
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn get_map_json(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let value = guard.get_map(container_id.as_str()).get_deep_value();
    serde_json::to_string(&value).map_err(json_err_to_nif)
}

/// Set a key on a root-level Map container. The value is a JSON string
/// limited to scalars (null / bool / number / string). Objects and arrays
/// are rejected with `:invalid_value` — nested containers can be added via
/// a dedicated API later.
///
/// Example:
///   map_set(doc, "comments", "c1", ~s("{\"body\":\"hi\"}"))   # string value
///   map_set(doc, "settings", "theme", ~s("\"dark\""))          # string
///   map_set(doc, "settings", "count", ~s("3"))                 # number
#[rustler::nif(schedule = "DirtyCpu")]
fn map_set(
    doc: ResourceArc<DocResource>,
    container_id: String,
    key: String,
    value_json: String,
) -> NifResult<Atom> {
    let parsed: serde_json::Value =
        serde_json::from_str(&value_json).map_err(json_err_to_nif)?;
    let loro_value = json_to_loro_value(parsed)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = guard.get_map(container_id.as_str());
    map.insert(&key, loro_value).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn map_delete(
    doc: ResourceArc<DocResource>,
    container_id: String,
    key: String,
) -> NifResult<Atom> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = guard.get_map(container_id.as_str());
    map.delete(&key).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

/// Read a single map key. Returns the JSON encoding of the value, or
/// `"null"` if the key doesn't exist. Deep-resolves nested containers
/// (matches `get_map_json`'s behavior).
#[rustler::nif(schedule = "DirtyCpu")]
fn map_get_json(
    doc: ResourceArc<DocResource>,
    container_id: String,
    key: String,
) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let map = guard.get_map(container_id.as_str());
    // `get_deep_value()` returns the whole map; we index into it afterwards
    // so we don't have to handle `ValueOrContainer` → JSON ourselves.
    match map.get_deep_value() {
        LoroValue::Map(m) => {
            let v = m
                .get(key.as_str())
                .cloned()
                .unwrap_or(LoroValue::Null);
            serde_json::to_string(&v).map_err(json_err_to_nif)
        }
        _ => Ok("null".to_string()),
    }
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn list_get_json(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let value = guard.get_list(container_id.as_str()).get_deep_value();
    serde_json::to_string(&value).map_err(json_err_to_nif)
}

/// Append a scalar value to a List container. Shapes allowed match
/// `map_set`: null / bool / number / string.
#[rustler::nif(schedule = "DirtyCpu")]
fn list_push(
    doc: ResourceArc<DocResource>,
    container_id: String,
    value_json: String,
) -> NifResult<Atom> {
    let parsed: serde_json::Value =
        serde_json::from_str(&value_json).map_err(json_err_to_nif)?;
    let loro_value = json_to_loro_value(parsed)?;
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let list = guard.get_list(container_id.as_str());
    list.push(loro_value).map_err(loro_err_to_nif)?;
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
    let list = guard.get_list(container_id.as_str());
    list.delete(index as usize, len as usize)
        .map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

/// Convert a parsed JSON value into a scalar `LoroValue`. Container-shaped
/// values (object / array) return `:invalid_value` — use container-init
/// APIs for nested structure. Numbers that fit in i64 are encoded as `I64`
/// (stable integer identity); otherwise encoded as `Double`.
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
                Err(NifError::Term(Box::new((
                    atoms::invalid_value(),
                    "number out of range".to_string(),
                ))))
            }
        }
        serde_json::Value::Array(_) | serde_json::Value::Object(_) => Err(NifError::Term(
            Box::new((
                atoms::invalid_value(),
                "objects and arrays are not scalar; use list/map container init APIs".to_string(),
            )),
        )),
    }
}

// ---------------------------------------------------------------------------
// Movable tree
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn tree_create_node(
    doc: ResourceArc<DocResource>,
    tree_id: String,
    parent_id: Option<String>,
) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let tree = guard.get_tree(tree_id.as_str());
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
    let tree = guard.get_tree(tree_id.as_str());
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
    let tree = guard.get_tree(tree_id.as_str());
    let node = parse_tree_id(&node_id)?;
    tree.delete(node).map_err(loro_err_to_nif)?;
    guard.commit();
    Ok(atoms::ok())
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tree_get_nodes(doc: ResourceArc<DocResource>, tree_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let value = guard.get_tree(tree_id.as_str()).get_value();
    serde_json::to_string(&value).map_err(json_err_to_nif)
}

// ---------------------------------------------------------------------------
// Subscriptions
// ---------------------------------------------------------------------------

/// Subscribe `pid` to local-update events on this doc. The subscribed pid
/// receives messages of the shape:
///
///   `{:loro_event, subscription_ref, update_bytes}`
///
/// where `update_bytes` is a binary that can be fed into `apply_update/2`
/// on a peer doc. This matches Loro's `subscribe_local_update` API.
///
/// ## Re-entrancy
///
/// The callback runs inside Loro's `commit()` / `import()` call path while
/// the doc mutex is already held by the caller thread. The callback MUST
/// NOT try to acquire the mutex again. Here we only encode and send — no
/// doc access.
#[rustler::nif(schedule = "DirtyCpu")]
fn subscribe(
    doc: ResourceArc<DocResource>,
    pid: LocalPid,
) -> NifResult<ResourceArc<SubscriptionResource>> {
    // Create the subscription resource up front so the callback can capture
    // its pid for the `loro_event` tuple. We use a plain Arc<Mutex<Option>>
    // pattern: Option::Some while active, None after unsubscribe.
    let sub_resource = ResourceArc::new(SubscriptionResource {
        inner: Mutex::new(None),
    });

    // The subscription handle itself is what Loro hands back; stash it in
    // the resource so drop/unsubscribe can cancel.
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;

    // Build the subscription resource, then clone the Arc into the callback
    // so the message tuple can include it as the `subscription_ref`.
    let sub_for_callback = sub_resource.clone();
    let subscription = guard.subscribe_local_update(Box::new(move |update_bytes: &Vec<u8>| {
        let target = pid;
        let bytes = update_bytes.clone();
        let sub_ref = sub_for_callback.clone();
        // Sending from inside `commit()` / `import()` happens on a BEAM
        // scheduler thread, where `OwnedEnv::send_and_clear` panics. We
        // spawn a short-lived thread per event to get us onto an unmanaged
        // thread. Replace with a dedicated background thread + mpsc channel
        // before high-throughput use.
        std::thread::spawn(move || {
            let mut msg_env = OwnedEnv::new();
            let _ = msg_env.send_and_clear(&target, |env| {
                // Encode bytes as a BEAM binary (not a list).
                let mut new_bin = rustler::NewBinary::new(env, bytes.len());
                new_bin.as_mut_slice().copy_from_slice(&bytes);
                let bin_term: rustler::Term = new_bin.into();
                (atoms::loro_event(), sub_ref, bin_term).encode(env)
            });
        });
        // Keep the subscription active.
        true
    }));

    // Stash the Subscription handle inside the resource.
    if let Ok(mut slot) = sub_resource.inner.lock() {
        *slot = Some(subscription);
    } else {
        return Err(poisoned_to_nif());
    }

    Ok(sub_resource)
}

/// Cancel a subscription. Safe to call more than once; second call is a
/// no-op. Does nothing if the subscription was already dropped via GC.
#[rustler::nif(schedule = "DirtyCpu")]
fn unsubscribe(sub: ResourceArc<SubscriptionResource>) -> NifResult<Atom> {
    let mut slot = sub.inner.lock().map_err(|_| poisoned_to_nif())?;
    // Dropping the Subscription is what actually cancels.
    *slot = None;
    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// Module init
// ---------------------------------------------------------------------------

rustler::init!("Elixir.LoroEx.Native");
