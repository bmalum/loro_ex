# LoroEx

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/elixir-~%3E%201.17-purple.svg)](https://elixir-lang.org)
[![Rust](https://img.shields.io/badge/rust-stable%20(%E2%89%A5%201.91)-orange.svg)](https://www.rust-lang.org)
[![Loro](https://img.shields.io/badge/loro-1.12-green.svg)](https://loro.dev)

Elixir bindings for the [Loro](https://loro.dev) CRDT library, via a
[Rustler](https://github.com/rusterlium/rustler) NIF.

LoroEx exposes Loro's document model — text with Peritext formatting,
maps, lists, and a movable block tree — to Elixir, so you can build
collaborative editors, offline-first mobile backends, or multiplayer
server-side state without reinventing merge logic.

It's factored as a standalone library so the NIF can evolve on its own
cadence: independent Rust toolchain, Loro version bumps, precompiled
artifact publishing.

---

## Table of contents

- [What is Loro?](#what-is-loro)
- [Why Loro over Yjs / Automerge?](#why-loro-over-yjs--automerge)
- [How Loro works (short version)](#how-loro-works-short-version)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Guides](#guides)
- [API overview](#api-overview)
- [Architecture & invariants](#architecture--invariants)
- [Building from source](#building-from-source)
- [Testing](#testing)
- [Project layout](#project-layout)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## What is Loro?

[Loro](https://loro.dev) is a high-performance CRDT (Conflict-free
Replicated Data Type) framework, written in Rust with bindings for
JavaScript (WASM) and Swift. CRDTs are data structures that can be
replicated across multiple peers and updated independently; they
guarantee that all replicas converge to the same state once they've
exchanged the same set of operations, **regardless of the order those
operations arrive**.

In practical terms that's the mathematics that lets Google Docs,
Figma, Linear, or Notion support live collaboration without a lock
server, and lets the same app keep working offline and merge back in
when it reconnects.

Loro in particular focuses on:

- **Rich text with Peritext semantics.** Formatting (bold, links,
  mentions) is preserved faithfully across concurrent edits — no mark
  split at insertion points, no "bold leaked over the linebreak."
- **Movable tree.** You can represent a block-based document (like a
  Notion page — nested toggles, columns, callouts) as a tree and allow
  concurrent moves without cycles, without losing nodes, and with a
  deterministic conflict winner. Pure-text CRDTs can't express this.
- **Time travel & version control.** A Loro doc keeps enough history to
  check out any previous state, export a shallow "starting-point"
  snapshot, or diff two versions.
- **Fast.** Orders of magnitude faster than earlier Rust CRDT libraries
  on typical editing benchmarks, thanks to an RLE-encoded op log and a
  column-oriented storage format.

Loro is pre-1.0 by culture but 1.x by version number — the on-disk
format is stable, but the API still gets refactors between minors. This
library pins Loro exactly in `Cargo.toml` and bumps deliberately.

## Why Loro over Yjs / Automerge?

CRDT choice is mostly about which features you need and how much upfront
integration work you can afford.

|                         | Yjs               | Automerge         | **Loro**          |
|-------------------------|-------------------|-------------------|-------------------|
| Rich text               | Markdown-ish      | Text only         | **Peritext**      |
| Block tree w/ moves     | Manual (fragile)  | No                | **Built-in**      |
| Time travel             | Limited           | Yes               | **Yes**           |
| Native Elixir story     | via Ex-Yjs ports  | via automerge-nif | via this library  |
| Snapshot size           | Small             | Medium            | Small (columnar)  |
| Maturity                | Very mature       | Very mature       | 1.x, production-ready |
| Editor integrations     | Many              | Few               | TipTap, ProseMirror, CodeMirror |

For a Notion-shaped product the Peritext + movable-tree combination is
hard to give up. The cost is Phase-1 week of NIF work that doesn't exist
with Yjs (which has a mature Elixir port).

## How Loro works (short version)

A Loro document is a **container forest** — a tree of containers, each
of which is one of:

- **`Text`** — a sequence of characters with Peritext-style formatting
- **`Map`** — a key/value store (JSON-ish)
- **`List`** / **`MovableList`** — ordered sequences
- **`Tree`** — a hierarchical tree of nodes, each with a metadata map,
  supporting concurrent moves without cycles (the feature we care about)

Every edit produces an **operation** with a unique id
`(peer_id, counter)`. Operations are stored in an **oplog** — an
append-only log per peer. The oplog is the source of truth; all
document state is derivable from it.

Peers exchange state by encoding a **version vector** (the set of ops
each peer has seen) and pulling the operations the other side is
missing. Loro's wire format is columnar + RLE-compressed, so typical
sync payloads are small.

The magic that makes the movable tree work is called a
**Tree CRDT with undo** — concurrent moves are detected by comparing
op ids, and cycles are broken by un-doing the lower-priority move
locally while keeping the op in the log for convergence. See Loro's
[docs on the movable tree](https://loro.dev/docs/tutorial/tree) for
the full algorithm; our design doc covers the invariants we rely on.

## Installation

LoroEx isn't on hex.pm yet. Add it as a git dependency in your
application's `mix.exs`:

```elixir
def deps do
  [
    {:loro_ex,
     git: "https://github.com/bmalum/loro_ex.git",
     tag: "v0.5.0"}
  ]
end
```

Or, during development, point at a local checkout:

```elixir
def deps do
  [{:loro_ex, path: "../loro_ex"}]
end
```

> **NIF compilation requires a Rust toolchain (stable, ≥ 1.91).**
> See [Building from source](#building-from-source) for details. Once we
> publish signed precompiled NIFs via `rustler_precompiled`, consumers
> won't need Rust on their machines.

## Quick start

```elixir
# Create a doc
doc = LoroEx.new()

# Edit a text container
:ok = LoroEx.insert_text(doc, "body", 0, "hello, ")
:ok = LoroEx.insert_text(doc, "body", 7, "world")
LoroEx.get_text(doc, "body")
# => "hello, world"

# Export the current state as a self-contained snapshot
snapshot = LoroEx.export_snapshot(doc)

# Create a second doc and sync
other = LoroEx.new()
:ok = LoroEx.apply_update(other, snapshot)
LoroEx.get_text(other, "body")
# => "hello, world"

# Incremental sync: export only the delta since the other side's version
version = LoroEx.oplog_version(other)
:ok = LoroEx.insert_text(doc, "body", 12, "!")
delta = LoroEx.export_updates(doc, version)
:ok = LoroEx.apply_update(other, delta)
LoroEx.get_text(other, "body")
# => "hello, world!"
```

### Movable tree example

```elixir
doc = LoroEx.new()

# Create three nodes, nest them
page_id = LoroEx.tree_create_node(doc, "blocks", nil)
intro_id = LoroEx.tree_create_node(doc, "blocks", page_id)
body_id = LoroEx.tree_create_node(doc, "blocks", page_id)

# Move intro to be a child of body
:ok = LoroEx.tree_move_node(doc, "blocks", intro_id, body_id, 0)

# Inspect
LoroEx.tree_get_nodes(doc, "blocks")
# => JSON string with the full tree structure
```

## Guides

Task-oriented tutorials with runnable examples:

- **[Getting started](docs/guides/getting_started.md)** — from `new()` to two-peer sync in ten minutes
- **[Rich text](docs/guides/rich_text.md)** — Peritext marks, Quill deltas, editor integration
- **[Sync & persistence](docs/guides/sync_and_persistence.md)** — snapshots vs deltas, server architecture, storage patterns
- **[Presence & cursors](docs/guides/presence_and_cursors.md)** — multi-user state that survives concurrent edits
- **[Tree & blocks](docs/guides/tree_and_blocks.md)** — Notion-style nested blocks with drag-to-reorder
- **[Undo](docs/guides/undo.md)** — `Ctrl+Z` / `Ctrl+Shift+Z` with proper grouping

Generate them locally as HTML with `mix docs`.

## API overview

The full API is documented in the modules themselves; `mix docs`
generates HTML. High-level surface:

### Lifecycle
- `LoroEx.new/0` — new doc with random peer id
- `LoroEx.new/1` — new doc with explicit peer id (deterministic tests)

### Sync primitives
- `LoroEx.apply_update/2` — apply bytes from `export_snapshot` or
  `export_updates`
- `LoroEx.export_snapshot/1` — full state, self-contained
- `LoroEx.export_shallow_snapshot/2` — trimmed snapshot starting at a
  frontier (for new joiners)
- `LoroEx.export_updates/2` — delta since a version
- `LoroEx.oplog_version/1`, `state_vector/1` — opaque version vectors
- `LoroEx.oplog_frontiers/1`, `state_frontiers/1`,
  `shallow_since_frontiers/1` — opaque frontiers

### Text containers — plain
- `LoroEx.get_text/2`, `insert_text/4`, `delete_text/4`
- `LoroEx.text_len/3` — count in `:unicode | :utf8 | :utf16`
- `LoroEx.text_convert_pos/5` — translate between unit systems

### Text containers — rich text (Peritext)
- `LoroEx.text_mark/6`, `text_unmark/5` — apply and remove marks
- `LoroEx.text_to_delta/2`, `text_apply_delta/3` — Quill-compatible deltas
- `LoroEx.text_get_richtext_value/2` — decoded segment list

### Cursors (stable positions)
- `LoroEx.text_get_cursor/4`, `list_get_cursor/4` — produce an opaque cursor
- `LoroEx.cursor_resolve/2` — resolve a cursor to its current `{pos, side}`

### Map containers
- `LoroEx.get_map_json/2`, `map_set/4`, `map_delete/3`, `map_get_json/3`
- `LoroEx.map_insert_container/4` — nest a text/map/list/movable_list

### List containers
- `LoroEx.list_get_json/2`, `list_push/3`, `list_delete/4`
- `LoroEx.list_insert_container/4`

### Movable tree
- `LoroEx.tree_create_node/3`, `tree_move_node/5`, `tree_delete_node/3`,
  `tree_get_nodes/2`
- `LoroEx.tree_get_meta/3` — per-node metadata map

### Undo / redo
`LoroEx.UndoManager` — per-peer undo history. See the
[Undo guide](docs/guides/undo.md).

### Presence / awareness
`LoroEx.Presence` — ephemeral KV with TTL for cursors, selections,
typing indicators. See the
[Presence & cursors guide](docs/guides/presence_and_cursors.md).

### Subscriptions
- `LoroEx.subscribe/2` — raw local-update bytes for sync
- `LoroEx.subscribe_container/3` — structured diff events per container
- `LoroEx.subscribe_root/2` — structured diff events across the whole doc
- `LoroEx.unsubscribe/1` — eager cancellation

## Architecture & invariants

See [`docs/design.md`](docs/design.md) for the full treatment. The five
non-negotiable rules:

1. **Every NIF is `DirtyCpu`-scheduled.** Loro operations on non-trivial
   docs take tens of milliseconds, which would starve a normal BEAM
   scheduler and stutter the whole VM.
2. **`Mutex<LoroDoc>`, not `RwLock`.** Writes are the hot path; there's
   no pure-reader hot path to benefit from concurrent reads.
3. **`OwnedBinary` for returned bytes.** Saves a copy from Rust heap
   into the BEAM heap.
4. **Version vectors are opaque binaries.** Loro has three related
   version types (`oplog_vv`, `state_vv`, `Frontiers`); they are not
   interchangeable. We pass them as binaries produced by `encode()`
   and decoded inside Rust so Elixir callers can't mix them up.
5. **Subscription callbacks never re-enter the doc.** Callbacks send
   bytes to a pid via message passing; they must not acquire the doc
   mutex, or a nested `import` call path will deadlock.

Concurrency model: pass doc handles between Elixir processes all you
want, but mutations serialize on the internal mutex. Expected usage is
**one GenServer per doc** that owns the handle, with all mutations
flowing through that GenServer's mailbox.

## Building from source

### Prerequisites

| Tool | Version | How to get it |
|------|---------|---------------|
| Erlang/OTP | 26+ | [asdf](https://asdf-vm.com/) or your package manager |
| Elixir | 1.17+ | `asdf install elixir 1.17.3-otp-27` |
| Rust | **≥ 1.91** stable | [rustup.rs](https://rustup.rs) |

The NIF uses Rustler 0.37 which mandates rustc ≥ 1.91. If you have both
a Homebrew / apt `cargo` and a rustup `cargo`, make sure rustup's is
first on `PATH`:

```bash
export PATH="$HOME/.cargo/bin:$PATH"
```

Or on every Mix invocation:

```bash
PATH="$HOME/.cargo/bin:$PATH" mix compile
```

### Build

```bash
mix deps.get
mix compile
```

The first build takes 2–5 minutes (Loro is a non-trivial Rust crate and
LTO is on for release mode). Incremental rebuilds take under 10 seconds.

### Run

LoroEx is a library, so there's no `mix run` target. Open IEx:

```bash
iex -S mix
iex> doc = LoroEx.new()
iex> LoroEx.insert_text(doc, "body", 0, "hello")
iex> LoroEx.get_text(doc, "body")
"hello"
```

## Testing

Tests that actually load the NIF are tagged `:nif`. They're excluded
from the default `mix test` run so CI jobs on a machine without Rust
can still verify the pure-Elixir wrapper compiles:

```bash
# Pure-Elixir tests only
mix test

# NIF-backed acceptance tests
mix test --only nif

# Both
mix test --include nif
```

Three Phase-1 acceptance tests currently pass and gate the NIF work
being "done":

1. **Convergence** — two docs exchange snapshots and reach the same
   text.
2. **Delta < snapshot** — for a shared baseline plus a small server
   edit, the delta is smaller than a full snapshot.
3. **Concurrent tree moves** — Alice moves A under B, Bob concurrently
   moves B under A; after sync both sides converge to the same tree
   with no cycle and a deterministic winner.

## Project layout

```
loro_ex/
├── lib/
│   ├── loro_ex.ex            # friendly Elixir API
│   └── loro_ex/native.ex     # NIF stubs (`use Rustler`)
├── native/
│   └── loro_nif/
│       ├── Cargo.toml
│       └── src/lib.rs        # the NIF itself
├── test/
│   └── loro_ex_test.exs      # phase-1 acceptance tests
├── docs/
│   └── design.md             # invariants & reasoning
├── rust-toolchain.toml       # pin Rust to stable
├── mix.exs
└── README.md                 # you are here
```

## Roadmap

### 0.1.0 (current)

- [x] Phase-1 NIF API: lifecycle, sync primitives, text, map, tree
- [x] Three convergence acceptance tests passing
- [x] Design doc & invariants
- [ ] Initial public release

### 0.2.0 (current)

- [x] `subscribe/2` & `unsubscribe/1` NIFs with the no-re-entrancy
      callback contract
- [x] Structured error atoms (`:invalid_update`, `:cyclic_move`, …)
- [ ] `rustler_precompiled` setup with signed artifacts per platform
      (x86_64-linux-gnu, aarch64-linux-gnu, aarch64-apple-darwin)
- [ ] Property-based convergence tests with `stream_data`
- [ ] Formatter + Credo + Clippy CI job
- [ ] Dedicated background thread + mpsc for subscription sends
      (replace per-event `std::thread::spawn`)

### 0.3.0

- [ ] Awareness / presence container integration
- [ ] `UndoManager` per-peer wiring
- [ ] JSON-path query API (Loro supports it natively)

### 1.0.0

- [ ] Stable public API, semver guarantees
- [ ] Hex.pm publication
- [ ] Upstream Loro major bumps validated via property tests

## Contributing

PRs welcome. For non-trivial changes, please open an issue first so we
can discuss scope. CI runs `cargo fmt`, `cargo clippy`, `credo`,
`dialyzer`, and the NIF tests on every PR.

When bumping Loro:

1. Update the exact version in `native/loro_nif/Cargo.toml`.
2. Run `mix test --only nif` against the new version.
3. If anything fails, check the
   [Loro changelog](https://github.com/loro-dev/loro/blob/main/CHANGELOG.md).
4. Record the bump in `CHANGELOG.md`.

## License

Apache-2.0. See [LICENSE](LICENSE).
