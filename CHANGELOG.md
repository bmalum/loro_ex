# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] — 2026-05-14

The biggest single release since 0.5.0. Closes the largest functional gaps
in the binding: `MovableList` is now wrappable end-to-end (it was 0%
covered before), the tree container exposes proper structural queries
instead of forcing a full JSON decode, and the projection-pipeline
integration that prompted the release ships as `containers_touched_since/2`.

Public NIF surface goes from **73 → 115 functions** (≈24% → ≈45% of the
Loro 1.12 facade). Strictly additive — zero breaking changes for callers
of 0.7.x.

### Added — projection pipeline

- **`LoroEx.containers_touched_since/2`** — list the distinct
  `ContainerID` strings that received at least one op between a stored
  version vector and the doc's current state. The Layer-1 pre-filter
  for projection / cache rebuilders: cost is O(ops_since), not
  O(doc_size). For a single paragraph edit on a 500-block doc, this
  typically returns 1–3 CIDs in microseconds. Implementation goes
  through `export_json_updates_without_peer_compression` (the
  compressed variant rewrites peer ids in CID strings, which would
  break round-tripping).

### Added — `MovableList` full surface

Previously the `:movable_list` kind could be named as a child container
but the resulting handle was inert. 18 new NIFs cover the full
operational surface:

- **Mirror of `list_*`**: `movable_list_get_json/2`,
  `movable_list_length/2`, `movable_list_get_json_at/3`,
  `movable_list_push/3`, `movable_list_insert/4`,
  `movable_list_delete/4`, `movable_list_insert_container/4`,
  `movable_list_get_child_cid/3`,
  `movable_list_get_or_create_container/4`,
  `movable_list_get_cursor/4`.
- **`MovableList`-only**: `movable_list_set/4` (set-by-index),
  **`movable_list_move/4`** (the headline feature — preserves identity
  across moves so concurrent moves of the same element converge),
  `movable_list_pop/2`, `movable_list_clear/2`,
  `movable_list_set_container/4`, `movable_list_get_creator_at/3`,
  `movable_list_get_last_mover_at/3`,
  `movable_list_get_last_editor_at/3`.

A regression test exercises convergence: Alice moves index 0→2, Bob
concurrently moves index 2→0; after sync both peers see the same
list.

### Added — Tree structural queries

8 new query NIFs so consumers walking a tree don't have to decode
`tree_get_nodes/2`'s full JSON dump for every structural question:

- `tree_parent/3` — projected as `{:ok, parent_id}` | `:root` |
  `:deleted` | `:unexist`.
- `tree_children/3`, `tree_children_num/3`, `tree_roots/2`.
- `tree_contains/3` — answers _"has this id existed in this tree"_,
  not _"is currently live"_; pair with the next entry to disambiguate.
- `tree_is_node_deleted/3` — confirms cascade-on-parent-delete.
- `tree_fractional_index/3` — for stable relative ordering.
- `tree_get_value_with_meta/2` — JSON tree with each node's meta map
  inlined.

### Added — `revert_to/2`

- **`LoroEx.revert_to/2`** — rewind the doc to a previous frontier by
  emitting **new ops** that invert the changes since that point. NOT
  a checkout: the inverse ops sync to peers like any other edit, fire
  subscription callbacks, and integrate with `UndoManager`. The
  forward-compatible-undo distinction is documented prominently in
  the `@doc` because it is unintuitive.

### Added — `LoroDoc` admin & introspection (Tier A)

17 small additions filling gaps in the `LoroDoc` surface:

- **Identity**: `peer_id/1`, `set_peer_id/2`.
- **State predicates**: `shallow?/1`, `has_container/2`,
  `pending_txn_len/1`.
- **Sizing & analysis**: `len_ops/1`, `len_changes/1`, `analyze/1`
  (returns per-container size / depth / ops-num / dropped /
  last-edit-time as JSON).
- **Path & deep value**: `get_path_to_container/2` (returns the
  root-to-target path, eliminating the need for consumer apps to
  maintain their own CID-path index), `get_deep_value_with_id/1`
  (full state preserving CIDs).
- **Sync helpers**: `import_batch/2` (atomic batch import — single
  mutex / single commit), `from_snapshot/1` (one-shot constructor),
  `decode_import_blob_meta/2` (peek at a blob without importing —
  useful for auth, quota, corruption checks), `fork_at/2` (fork at
  a specific frontier).
- **Memory hygiene**: `free_history_cache/1`, `free_diff_calculator/1`,
  `compact_change_store/1`.

### API decisions documented in this release

- `shallow?/1` is the public Elixir-idiomatic name; the Native stub
  keeps `is_shallow` (matching Loro's Rust function) with a Credo
  override.
- `movable_list_move/4` uses the full Elixir verb rather than Loro's
  Rust abbreviation `mov`.
- Tree parent variants project as the atoms `:root`, `:deleted`,
  `:unexist`, with `{:ok, id}` for the value case.
- All Rust struct returns (`DocAnalysis`, `ImportBlobMetadata`,
  container path, deep value with id) are JSON strings, matching the
  existing `get_map_json` / `tree_get_nodes` pattern.

### Internal

- Adds `:root`, `:deleted`, `:unexist` atoms for tree-parent variants.
- New helper `get_movable_list_handle/2` next to the existing
  `get_list_handle` / `get_tree_handle`.
- 42 new tests; suite grows from 91 → 133 `:nif`-tagged tests.

## [0.7.0] — 2026-05-12

### Added

- **`LoroEx.fork/1`** — return an independent clone of a document.
  The clone observes the parent's full op history at the moment of
  the call but lives in a separate Rust resource; mutations and
  exports on the fork do not affect the parent, and vice versa. Loro
  assigns the clone a new random peer id. O(n) in op-log size but
  considerably cheaper than `export_snapshot/1` because no
  serialization to bytes happens. Primary use case: move an
  expensive `export_snapshot/1` or `export_shallow_snapshot/2` call
  off a doc-owning GenServer's mailbox by forking synchronously
  (fast) and exporting the fork inside a `Task`.

## [0.6.0] — 2026-05-10

Both changes in this release are strictly additive — zero breaking
changes for callers of the 0.5.x API. Inputs that previously errored
now succeed; all previously-working calls keep their behavior.

### Added

- **`LoroEx.map_get_or_create_container/4`** and
  **`LoroEx.list_get_or_create_container/4`** — idempotent,
  race-free "ensure a child container exists" operations. The
  check-and-insert happens under a single doc-mutex lock, so there
  is no window where concurrent callers can both see a missing CID
  and both insert. Directly retires the
  `map_get_child_cid || map_insert_container` dance and the
  hydrate-safety footgun in super_loop's
  `Doc.Server.ensure_root_children_cid/1`. Behavior:
  - Existing container of the same kind → return its CID unchanged.
  - Existing container of a different kind →
    `{:error, {:invalid_container_kind, _}}`.
  - Scalar at the key/index → `{:error, {:invalid_value, _}}`
    (never clobbers data).
  - Absent → insert and return new CID.
  - `list_get_or_create_container` additionally treats
    `index == length` as "append at end" and
    `index > length` as `{:error, {:out_of_bound, _}}`.
- **`LoroEx.map_get_child_cid/3`** and **`LoroEx.list_get_child_cid/3`**
  — return the serialized `ContainerID` of a child container, or
  `nil` for scalar/absent/out-of-bounds cases. The return shape
  matches `map_insert_container/4` / `list_insert_container/4`
  (a bare CID string, no `{:ok, _}` wrapping). Enables path-based
  descent into nested container structures (e.g.
  `root.children[0].children`) without going through
  `get_map_json`/`list_get_json`, which call Loro's `get_deep_value`
  and strip container IDs. Two primary uses:
  - **Nested block writes**: agent-facing block-edit tools can now
    resolve a path like `[N, M, ...]` to the CID of an arbitrary
    descendant and pass it to any map/list/text function.
  - **Hydrate-safe path caches**: after `apply_update`, consumers that
    keep a `path → cid` cache can re-derive it instead of
    re-creating containers (which would clobber content).
- **`LoroEx.map_keys/2`** and **`LoroEx.map_size/2`** — cheap map
  introspection. O(n) and O(1) respectively at the CRDT layer,
  avoiding the full deep-JSON-encode cost of `get_map_json/2 |>
  Jason.decode!() |> Map.keys()` when the caller only needs keys or
  a count.
- **`LoroEx.list_length/2`** and **`LoroEx.list_get_json_at/3`** —
  symmetric with `map_size/2` / `map_get_json/3`. `list_length` is
  O(1); `list_get_json_at` returns one element as JSON (the literal
  string `"null"` for out-of-bounds, matching `map_get_json/3`'s
  missing-key behavior). For nested container elements returns the
  deep value; use `list_get_child_cid/3` to recover the CID.
- **`LoroEx.list_insert/4`** — insert a JSON value at a specific
  position (shifts tail). Closes the API symmetry gap vs
  `list_push/3` (end) and `list_insert_container/4` (container at
  position). Same value rules as `list_push/3`.

### Changed

- **`LoroEx.map_set/4` and `LoroEx.list_push/3` now accept JSON-encoded
  objects and arrays** as values, not just scalars. The
  `parse_scalar_json`/`json_to_loro_value` helpers now route
  structured values through Loro's built-in
  `LoroValue::from(serde_json::Value)` impl, producing
  `LoroValue::Map` and `LoroValue::List` variants. The helpers keep
  their names for source-compat; their `@doc` strings are updated.
  Structured values are stored as **frozen** values inside the parent
  — for CRDT-level merging on nested fields, use
  `map_insert_container/4` / `list_insert_container/4` to materialize
  a nested container instead. The same relaxation applies to
  `text_mark/6` (which also goes through `parse_scalar_json`), so
  structured mark values (e.g. complex attribute objects) now
  round-trip through `text_to_delta/2`.
- **Tests reflecting the old scalar-only behavior were updated**:
  the `map mutation`, `list mutation`, and `bad inputs to new NIFs`
  describes previously asserted `{:error, {:invalid_value, _}}` for
  objects/arrays. They now verify successful round-trips.

## [0.5.2] — 2026-05-01

### Changed
- `cargo fmt` run across `native/loro_nif/src/lib.rs`. Pure
  formatting; no behavior change. The 0.5.1 CI workflow caught
  that the file had never been fmt'd, and the `cargo fmt --check`
  job failed on the 0.5.1 commit. This patch resolves that so CI
  is green on `main`.

## [0.5.1] — 2026-05-01

### Fixed
- **`jason` is now a declared runtime dependency.** v0.5.0 called
  `Jason.encode!/1` and `Jason.decode!/1` from `text_to_delta/2`,
  `text_apply_delta/3`, `text_get_richtext_value/2`, and every
  `LoroEx.Presence` function, but never declared `:jason` in
  `mix.exs`. Applications that didn't already have Jason
  transitively via another dep would crash at runtime with
  `UndefinedFunctionError`. Caught by dialyzer once it had a full
  PLT; fixed by adding `{:jason, "~> 1.4"}` as a runtime dep.

### Added
- **CI workflow** at `.github/workflows/ci.yml`. Runs on every push
  and pull request to `main`: `mix format --check-formatted`,
  `mix credo --strict`, `mix dialyzer`, `cargo fmt --check`,
  `cargo clippy -D warnings`, `mix test --include nif`, `mix docs`
  (fails on any warning). Seven parallel jobs with per-job caching
  of `deps`, `_build`, and the Rust target directory.

### Changed
- `mix format` run across the tree — minor style fixes in
  `lib/loro_ex.ex`, `mix.exs`, and `test/loro_ex_test.exs`. No
  behavior change.

## [0.5.0] — 2026-05-01

### Added

All the "Tier 1" features — the minimum surface for a collaborative editor
product — are now exposed.

**Rich text (Peritext).**
- `LoroEx.text_mark/6`, `text_unmark/5` — apply and remove formatting marks
  (bold, italic, link, color, …) over Unicode ranges.
- `LoroEx.text_to_delta/2`, `text_apply_delta/3` — Quill-compatible deltas
  for interop with TipTap, ProseMirror, and CodeMirror rich-text editors.
- `LoroEx.text_get_richtext_value/2` — decoded rich-text segments with
  per-run attributes.
- `LoroEx.text_len/3` — length in `:unicode | :utf8 | :utf16` units.
- `LoroEx.text_convert_pos/5` — convert an index between unit systems.
  Useful at the browser/server boundary (UTF-16 ↔ Unicode).

**Cursors (stable positions).**
- `LoroEx.text_get_cursor/4`, `list_get_cursor/4` — produce an opaque
  binary that tracks a position across concurrent edits.
- `LoroEx.cursor_resolve/2` — resolve a cursor to its current
  `{pos, side}`. Returns `{:error, {:history_cleared | :container_deleted
  | :id_not_found, _}}` when the anchor is gone.
- New atoms: `:left | :middle | :right`, `:unicode | :utf8 | :utf16`.

**Undo / redo.**
- New module `LoroEx.UndoManager` with `new/1`, `undo/1`, `redo/1`,
  `can_undo/1`, `can_redo/1`, `record_new_checkpoint/1`,
  `set_max_undo_steps/2`, `set_merge_interval/2`. Local-only per Loro's
  semantics: only undoes operations from the bound peer.

**Ephemeral / awareness (presence).**
- New module `LoroEx.Presence` wrapping Loro's `EphemeralStore`.
- `new/1`, `set/3`, `get/2`, `delete/2`, `keys/1`, `get_all_states/1`,
  `encode/2`, `encode_all/1`, `apply/2`, `remove_outdated/1`,
  `subscribe/2`. Subscription callback delivers
  `{:loro_ephemeral, ref, bytes}` — bytes are ready to feed into
  `apply/2` on a peer store.

**Structured diff subscriptions.**
- `LoroEx.subscribe_container/3` — subscribe `pid` to diffs on one
  container (root name or nested ContainerID).
- `LoroEx.subscribe_root/2` — subscribe to diffs across the whole doc.
- Both deliver `{:loro_diff, ref, events_json_binary}` with a structured
  diff payload (text ops, map updates, list ops, tree actions).

**Nested containers.**
- `LoroEx.map_insert_container/4`, `list_insert_container/4` — create a
  new `:text | :map | :list | :movable_list` nested inside a parent
  container. Returns the new container's serialized id.
- `LoroEx.tree_get_meta/3` — return the id of a tree node's metadata
  map. Pass it to `map_set/4` / `map_get_json/3` to store per-node data
  (title, icon, props).
- All container-taking NIFs accept serialized `ContainerID` strings in
  addition to root names.

### Changed
- Container-id resolution is unified: functions try `ContainerID::try_from`
  first and fall back to root-name lookup. No API break.

### New error reasons
`:invalid_cursor`, `:invalid_delta`, `:invalid_container_kind`,
`:history_cleared`, `:id_not_found`, `:ephemeral_apply_failed`.

### Tested
Sixteen new `:nif` tests across seven describe blocks: text marks,
length helpers, cursors, undo manager, presence, structured diff
subscriptions, nested containers, plus one end-to-end cross-feature
test (edit + mark + cursor survives concurrent insert + undo + presence)
that exercises every Tier-1 surface together.

39 `:nif` tests total, all passing.

### Documentation
- Every public function in `LoroEx`, `LoroEx.UndoManager`, and
  `LoroEx.Presence` now has a `@doc` block with Purpose / Use cases /
  Example / Errors / See also sections.
- New topic guides under `docs/guides/`:
  [Getting started](docs/guides/getting_started.md),
  [Rich text](docs/guides/rich_text.md),
  [Sync & persistence](docs/guides/sync_and_persistence.md),
  [Presence & cursors](docs/guides/presence_and_cursors.md),
  [Tree & blocks](docs/guides/tree_and_blocks.md),
  [Undo](docs/guides/undo.md).
- `mix.exs` wires all guides into ExDoc with sidebar groups.
  `mix docs` now builds without warnings.

### Build
- `loro` pinned exactly at `=1.12.0` in `Cargo.toml` (was `"1.10"`
  caret range; the lockfile was already resolving to 1.12.0).
- `rust-version` bumped to 1.91 in `Cargo.toml` to match the Rustler
  0.37 MSRV stated in the README and `rust-toolchain.toml`.

### Behavior notes (not a break in practice)
- `container_id` strings starting with `"cid:"` are now parsed as
  serialized `ContainerID`s rather than treated as root-container
  names. If you were using a literal `"cid:…"` string as a root name
  in v0.4.0 (extremely unusual), rename it. Any other root name
  (`"body"`, `"settings"`, etc.) is unaffected.

### Known limitations
- **Subscriptions must be unsubscribed explicitly.** Due to an
  Arc cycle between the subscription handle and its delivery
  closure, dropping a subscription reference without calling
  `unsubscribe/1` leaks the subscription (and its captured doc ref)
  until BEAM exits. Always pair every `subscribe/*` with an
  `unsubscribe/1` at shutdown. Fix planned for 0.5.1 via a global
  subscription registry.
- `text_len/3` with an unknown unit atom returns
  `{:error, {:invalid_value, _}}` instead of raising
  `FunctionClauseError` (added in this release). Previously unknown
  units crashed the caller.

## [0.4.0] — 2026-05-01

### Added
- `LoroEx.oplog_frontiers/1`, `state_frontiers/1`, and
  `shallow_since_frontiers/1`. Frontiers are a distinct version type
  from the existing version vectors — they're a set of op ids,
  not a per-peer counter map. All three NIFs return an opaque binary
  suitable for passing to `export_shallow_snapshot/2`.

### Why
Callers building shallow-snapshot storage tiers (Super Loop's
time-travel reader, for example) need to capture the doc's current
frontier so a later snapshot can be anchored against it. Without
these the shallow snapshot API was not usable end-to-end from
Elixir.

### Tested
New `frontiers` describe block with three `:nif` tests, including a
round-trip that exports a shallow snapshot against the current
frontier and hydrates a fresh doc from it.

## [0.3.0] — 2026-05-01

### Added
- `LoroEx.map_set/4`, `map_delete/3`, `map_get_json/3` — mutate a
  root-level Map container with scalar JSON values (`null`, `bool`,
  number, string). Objects and arrays return `{:error, {:invalid_value, _}}`
  — nested containers need a dedicated init API (not yet exposed).
- `LoroEx.list_push/3`, `list_delete/4`, `list_get_json/2` — same
  scalar rules, appended onto a root-level List container.
- New error reason atom `:invalid_value`, returned by the map/list
  setters when the JSON value isn't a supported scalar.

### Why
Comments, presence metadata, arbitrary app-level KV now live on the
Elixir side without the client having to round-trip Loro update bytes
through the server. Matches the mutation surface of the text and tree
APIs.

## [0.2.0] — 2026-04-28

### Added
- `LoroEx.subscribe/2` and `LoroEx.unsubscribe/1`. Subscribed pids
  receive `{:loro_event, subscription_ref, update_bytes}` on every local
  commit. `update_bytes` is a BEAM binary ready for `apply_update/2` on
  a peer doc — no post-processing needed.
- Structured error atoms. NIF errors now return
  `{:error, {reason_atom, detail_string}}` with a fixed set of reasons:
  `:invalid_update`, `:invalid_version_vector`, `:invalid_frontier`,
  `:invalid_tree_id`, `:invalid_peer_id`, `:checksum_mismatch`,
  `:incompatible_version`, `:not_found`, `:out_of_bound`,
  `:cyclic_move`, `:tree_node_not_found`, `:fractional_index_not_enabled`,
  `:index_out_of_bound`, `:container_deleted`, `:lock_poisoned`,
  `:unknown`. See `LoroEx` moduledoc for the full map.
- Seven new acceptance tests: subscription delivery, multi-edit
  subscription, unsubscribe stops delivery, mirror-via-subscription,
  invalid-update error shape, invalid-VV error shape, invalid-tree-id
  error shape.

### Notes
- The subscription callback spawns a short-lived thread per event to
  satisfy rustler's "no OwnedEnv send from a managed thread" rule.
  This is acceptable for PoC throughput (tens of events/sec) but should
  be replaced with a dedicated background thread + mpsc channel before
  any high-throughput workload.

## [0.1.0] — 2026-04-28

Initial release.

### Added
- Phase-1 NIF API:
  - Lifecycle: `new/0`, `new/1` (with peer id)
  - Sync primitives: `apply_update/2`, `export_snapshot/1`,
    `export_shallow_snapshot/2`, `export_updates/2`,
    `oplog_version/1`, `state_vector/1`
  - Text container: `get_text/2`, `insert_text/4`, `delete_text/4`
  - Map container: `get_map_json/2`
  - Movable tree: `tree_create_node/3`, `tree_move_node/5`,
    `tree_delete_node/3`, `tree_get_nodes/2`
- Three acceptance tests (convergence, delta < snapshot,
  concurrent tree moves) proving the NIF works end-to-end.
- Design document (`docs/design.md`) capturing the DirtyCpu,
  Mutex, OwnedBinary, opaque-version-vector, and callback-reentrancy
  invariants.
- Rust toolchain pin via `rust-toolchain.toml` (stable, Rustler 0.37
  requires rustc ≥ 1.91).
- `mix.exs` with `{:rustup, "stable"}` cargo routing so Homebrew's
  older `cargo` doesn't shadow the required rustup toolchain.
