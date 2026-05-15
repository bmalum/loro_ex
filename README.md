# LoroEx

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Elixir](https://img.shields.io/badge/elixir-~%3E%201.17-purple.svg)](https://elixir-lang.org)
[![Loro](https://img.shields.io/badge/loro-1.12-green.svg)](https://loro.dev)

Elixir bindings for the [Loro](https://loro.dev) CRDT library, via a
[Rustler](https://github.com/rusterlium/rustler) NIF.

LoroEx exposes Loro's document model — text with Peritext formatting,
maps, lists, movable lists, a movable block tree, and counters — to
Elixir, so you can build collaborative editors, offline-first mobile
backends, or multiplayer server-side state without reinventing merge
logic.

It's factored as a standalone library so the NIF can evolve on its own
cadence: independent Rust toolchain, Loro version bumps, precompiled
artifact publishing.

---

## Table of contents

- [Quick start](#quick-start)
- [Installation](#installation)
- [Why Loro](#why-loro-vs-yjs--automerge)
- [Concepts](#concepts)
- [Guides](#guides)
- [Documentation](#documentation)
- [Building from source](#building-from-source)
- [Testing](#testing)
- [Project status & roadmap](#project-status--roadmap)
- [Contributing](#contributing)
- [License](#license)

---

## Quick start

```elixir
# Add to your mix.exs deps:
{:loro_ex, git: "https://github.com/bmalum/loro_ex.git", tag: "v0.9.0"}
```

```elixir
# Create a doc and edit a text container.
doc = LoroEx.new()
:ok = LoroEx.insert_text(doc, "body", 0, "hello, world")
LoroEx.get_text(doc, "body")
# => "hello, world"

# Sync with another peer via a snapshot.
snap  = LoroEx.export_snapshot(doc)
other = LoroEx.new()
:ok   = LoroEx.apply_update(other, snap)
LoroEx.get_text(other, "body")
# => "hello, world"

# Incremental sync: ship only the delta since the other side's version.
v = LoroEx.oplog_version(other)
:ok = LoroEx.insert_text(doc, "body", 12, "!")
delta = LoroEx.export_updates(doc, v)
:ok = LoroEx.apply_update(other, delta)
LoroEx.get_text(other, "body")
# => "hello, world!"
```

A movable block tree (Notion-style nested blocks):

```elixir
doc = LoroEx.new()
page  = LoroEx.tree_create_node(doc, "blocks", nil)
intro = LoroEx.tree_create_node(doc, "blocks", page)
body  = LoroEx.tree_create_node(doc, "blocks", page)

:ok = LoroEx.tree_move_node(doc, "blocks", intro, body, 0)

LoroEx.tree_children(doc, "blocks", body)
# => [intro_id]
```

## Installation

Add LoroEx as a git dependency in your `mix.exs`:

```elixir
def deps do
  [
    {:loro_ex,
     git: "https://github.com/bmalum/loro_ex.git",
     tag: "v0.8.0"}
  ]
end
```

Or, during local development, point at a checkout:

```elixir
def deps do
  [{:loro_ex, path: "../loro_ex"}]
end
```

### Precompiled NIFs (0.9.0+)

Starting with **0.9.0**, LoroEx ships precompiled NIF artifacts for the
common targets, so you don't need a Rust toolchain to install:

| Target triple | Who it serves |
|---|---|
| `aarch64-apple-darwin` | Apple Silicon Mac (M1/M2/M3) |
| `x86_64-apple-darwin` | Intel Mac |
| `aarch64-unknown-linux-gnu` | ARM Linux (Graviton, Hetzner ARM, Pi) |
| `x86_64-unknown-linux-gnu` | AMD64 Linux (most cloud, Intel/AMD servers) |

Linux artifacts are built against glibc 2.31 (Debian 11+, Ubuntu 20.04+).
Windows is not yet a target — open an issue if you need it.

If your platform isn't in the matrix, or you want to debug NIF code
locally, set `FORCE_LORO_EX_BUILD=1` to fall back to a source build.
Source builds need a recent Rust toolchain — see
[Building from source](#building-from-source).

## Why Loro vs Yjs / Automerge

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
hard to give up. The cost is a week of NIF integration work; LoroEx
absorbs that for you.

## Concepts

A Loro document is a **container forest** — a tree of containers, each
of which is one of:

- **`Text`** — a sequence of characters with Peritext formatting
- **`Map`** — a key/value store
- **`List`** / **`MovableList`** — ordered sequences (the movable
  variant preserves element identity across moves)
- **`Tree`** — a hierarchical tree of nodes with metadata maps,
  supporting concurrent moves without cycles
- **`Counter`** — a sum-CRDT (added in 0.9.0)

Every edit produces an **operation** with a unique id `(peer_id, counter)`,
appended to a per-peer **op log**. Peers exchange state by encoding a
**version vector** and pulling the operations the other side is missing.
The on-disk format is columnar and RLE-compressed so typical sync
payloads are small.

For the algorithmic detail, see Loro's
[official docs](https://loro.dev/docs); for the invariants this
binding relies on, see [`docs/design.md`](docs/design.md).

## Guides

Task-oriented tutorials with runnable examples:

- **[Getting started](docs/guides/getting_started.md)** — from `new()` to two-peer sync in ten minutes
- **[Rich text](docs/guides/rich_text.md)** — Peritext marks, Quill deltas, editor integration
- **[Sync & persistence](docs/guides/sync_and_persistence.md)** — snapshots vs deltas, server architecture, storage patterns
- **[Presence & cursors](docs/guides/presence_and_cursors.md)** — multi-user state that survives concurrent edits
- **[Tree & blocks](docs/guides/tree_and_blocks.md)** — Notion-style nested blocks with drag-to-reorder
- **[Undo](docs/guides/undo.md)** — `Ctrl+Z` / `Ctrl+Shift+Z` with proper grouping

Generate them locally as HTML with `mix docs`.

## Documentation

The full API is documented in the modules themselves; run `mix docs`
to generate HTML, or browse the source:

- `LoroEx` — the friendly Elixir API (lifecycle, sync, containers,
  cursors, time travel, JSON-path)
- `LoroEx.UndoManager` — per-peer undo history
- `LoroEx.Presence` — ephemeral KV with TTL for cursors and selections
- `LoroEx.Native` — the raw NIF bindings (prefer the friendly API)

For architectural invariants (mutex strategy, scheduler choice,
subscription contract) see [`docs/design.md`](docs/design.md).

## Building from source

You only need this section if your platform isn't in the prebuilt
matrix or you set `FORCE_LORO_EX_BUILD=1`.

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

Tests that load the NIF are tagged `:nif`. They're excluded from the
default `mix test` run so CI jobs on a machine without Rust can still
verify the pure-Elixir wrapper compiles:

```bash
# Pure-Elixir tests only
mix test

# NIF-backed acceptance + unit tests
mix test --only nif

# Everything (includes :nif)
mix test --include nif

# Property-based convergence tests (slower; 0.9.0+)
mix test --include nif --include property
```

CI runs `mix format --check-formatted`, `mix credo --strict`,
`cargo fmt --check`, `cargo clippy -D warnings`, `mix dialyzer`,
`mix docs` (with warnings-as-errors), and `mix test --include nif`
on every PR.

## Project status & roadmap

LoroEx is **production-ready for early adopters**: the NIF surface is
stable and 100% of Loro's container types are wrapped, but the public
Elixir API still gets refinements between minor releases. Don't pin to
the `main` branch in production — pin to a tag.

### Released

- **0.5.0** — Tier-1 collaboration APIs (UndoManager, Presence, marks)
- **0.6.0** — nested-container ergonomics, structured map/list values
- **0.7.0** — `LoroEx.fork/1` for off-GenServer snapshot export
- **0.8.0** — projection-pipeline NIF, MovableList, tree queries,
  `revert_to/2`, 17 small `LoroDoc` additions

### In flight (0.9.0)

- [ ] Precompiled NIF artifacts via `rustler_precompiled`
- [ ] Time travel API: `checkout/2`, `attach/1`, `detach/1`,
      `detached?/1`, `checkout_to_latest/1`, `set_detached_editing/2`
- [ ] JSON-path queries: `get_by_str_path/2`, `jsonpath/2`
- [ ] `LoroCounter` container — closes container-coverage gap to 100%
- [ ] Background-thread subscription dispatcher (mpsc, no per-event spawn)
- [ ] `subscribe_pre_commit/2`, `subscribe_peer_id_change/2`
- [ ] Property-based convergence tests with `stream_data`

### 1.0.0 (planned)

- [ ] Stable public API, semver guarantees
- [ ] Hex.pm publication
- [ ] Sigstore-signed NIF artifacts
- [ ] Upstream Loro major bumps validated via property tests

## Contributing

PRs welcome. For non-trivial changes, please open an issue first so we
can discuss scope. CI runs `cargo fmt`, `cargo clippy`, `credo`,
`dialyzer`, and the full NIF tests on every PR.

When bumping Loro:

1. Update the exact version in `native/loro_nif/Cargo.toml`.
2. Run `mix test --only nif` against the new version.
3. If anything fails, check the
   [Loro changelog](https://github.com/loro-dev/loro/blob/main/CHANGELOG.md).
4. Record the bump in `CHANGELOG.md`.

## License

Apache-2.0. See [LICENSE](LICENSE).
