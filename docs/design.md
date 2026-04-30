# LoroEx design notes

## Why a NIF at all?

Loro's performance model assumes in-memory mutation of a single document
handle. A pure-Elixir CRDT (e.g. Delta-CRDTs, Riak's riak_dt) would avoid
the NIF complexity but sacrifice the whole reason we're on Loro: Movable
Tree and Peritext rich text. Those features are Loro-specific and not
available in any Elixir-native library.

## Non-negotiable invariants

### 1. DirtyCpu scheduling for every NIF

Loro operations on non-trivial documents take tens of milliseconds.
Regular BEAM schedulers budget ~1ms; block one and the entire VM
stutters. Every NIF in this crate is annotated
`#[rustler::nif(schedule = "DirtyCpu")]`.

### 2. Mutex<LoroDoc>, not RwLock

Rustler NIFs can be invoked from any dirty scheduler thread. `LoroDoc`
is `Send + Sync` but its operations mutate internal indices; concurrent
mutation is UB. We wrap in `Mutex`, not `RwLock`, because writes (edits
applied, updates imported) are the hot path. `RwLock` would add read
contention for pure-reader NIFs (`export_*`) in exchange for allowing
concurrent readers — but we have no pure-reader hot path.

### 3. OwnedBinary for returned bytes

A `Vec<u8>` crossing back into the BEAM heap costs one extra copy.
`OwnedBinary` is allocated on the BEAM heap directly. For a 10MB
snapshot this is the difference between a 30ms and a 15ms call.

### 4. Opaque version-vector binaries

Loro has three related but non-interchangeable version types:

* `oplog_vv()` — the full oplog frontier
* `state_vv()` — the state frontier (may lag behind oplog)
* `Frontiers` — specific op ids

Passing these as structured Elixir terms invites silent confusion.
Instead we pass them as opaque binaries produced by `encode()` and
decoded inside Rust. Elixir callers must treat them as opaque.

### 5. No subscription callback may re-enter the doc

`subscribe(doc, pid)` (to be implemented) ships raw change bytes to the
pid. The callback MUST NOT acquire the doc's mutex — that would deadlock
if the subscription fires from inside an `import`/`commit` call path,
which does in fact happen. The callback does encoding and
`env.send` only.

## Memory profile

A "hot" document (100k ops, no GC) occupies ~50MB. In a server process
holding N hot docs we'll see `N * 50MB` of Rust heap out of BEAM's
accounting. Two mitigations:

* Idle shutdown of doc GenServers (evicts the resource).
* `export_shallow_snapshot` trims history on snapshot to S3.

## Build & release

Development uses `mix compile` which invokes `cargo build` via the
rustler compiler. Releases use `rustler_precompiled` to fetch signed
`.so` artifacts from the GitLab Package Registry, so prod containers
don't need a Rust toolchain.

Target triples:

* `x86_64-unknown-linux-gnu` (generic glibc Linux)
* `aarch64-unknown-linux-gnu` (ARM64 Linux)
* `aarch64-apple-darwin` (local dev on Apple Silicon)
* `x86_64-apple-darwin` (local dev on Intel Macs)

## Upstream version pinning

Loro is pre-1.0 by semver attitude despite the 1.x major. Pin exactly in
`Cargo.toml` (`loro = "=1.10.0"`) and bump deliberately after running
the full test suite.
