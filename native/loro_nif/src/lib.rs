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
    LoroTreeError, LoroValue, Subscription, TextDelta, TreeID, UndoManager, VersionVector,
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
        serde_json::Value::Array(_) | serde_json::Value::Object(_) => Err(invalid_value_err(
            "objects and arrays are not scalar; use container init APIs",
        )),
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

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

#[rustler::nif(schedule = "DirtyCpu")]
fn list_get_json(doc: ResourceArc<DocResource>, container_id: String) -> NifResult<String> {
    let guard = doc.inner.lock().map_err(|_| poisoned_to_nif())?;
    let value = get_list_handle(&guard, &container_id).get_deep_value();
    serde_json::to_string(&value).map_err(json_err_to_nif)
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
