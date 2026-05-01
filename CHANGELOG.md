# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
