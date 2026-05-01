# Tree & blocks

Loro's **movable tree** is the feature that makes LoroEx a good choice
for Notion-shaped products — nested blocks, drag-to-reorder, toggles,
columns, callouts. A pure-text CRDT can't model "this paragraph
becomes a nested bullet under that one" cleanly; the movable tree
can.

This guide covers how to use the tree, how to attach per-node data,
and how to build a block editor on top.

## What's a movable tree?

A tree CRDT where:

- Every node has a unique, stable id
- Nodes can have children (nested to any depth)
- Any node can be **moved** to a new parent (or to the root) without
  being deleted and recreated
- Concurrent moves from different peers are resolved without cycles
  and without losing any node

The last point is the hard one. Imagine Alice moves node A under node
B, while Bob concurrently moves B under A. A pure-tree data structure
would end up with a cycle or would silently drop a node. Loro's CRDT
detects this and cancels the lower-priority op *locally* while keeping
it in the oplog for convergence. All peers end up with the same tree
and no cycle.

## Create and move nodes

```elixir
iex> doc = LoroEx.new()

iex> page = LoroEx.tree_create_node(doc, "blocks", nil)
iex> intro = LoroEx.tree_create_node(doc, "blocks", page)
iex> body = LoroEx.tree_create_node(doc, "blocks", page)

iex> LoroEx.tree_get_nodes(doc, "blocks") |> Jason.decode!()
# => [ %{"id" => page, "parent" => nil, "index" => 0, ...},
#      %{"id" => intro, "parent" => page, "index" => 0, ...},
#      %{"id" => body, "parent" => page, "index" => 1, ...} ]
```

`tree_create_node/3` takes the doc, the tree container id, and an
optional parent. Returns a `TreeID` string you hang on to for future
operations.

Move:

```elixir
# Move `intro` to be the last child of `body`
iex> :ok = LoroEx.tree_move_node(doc, "blocks", intro, body, 0)
```

Move to root:

```elixir
iex> :ok = LoroEx.tree_move_node(doc, "blocks", intro, nil, 0)
```

Delete:

```elixir
iex> :ok = LoroEx.tree_delete_node(doc, "blocks", intro)
```

Deleting a node removes all its descendants too.

## Per-node metadata

Every tree node has an attached `LoroMap` for metadata. This is how
you store titles, icons, block kinds, custom properties:

```elixir
iex> page = LoroEx.tree_create_node(doc, "blocks", nil)
iex> meta = LoroEx.tree_get_meta(doc, "blocks", page)

iex> :ok = LoroEx.map_set(doc, meta, "title", ~s("My page"))
iex> :ok = LoroEx.map_set(doc, meta, "icon", ~s("📄"))
iex> :ok = LoroEx.map_set(doc, meta, "kind", ~s("document"))

iex> LoroEx.get_map_json(doc, meta) |> Jason.decode!()
%{"title" => "My page", "icon" => "📄", "kind" => "document"}
```

`tree_get_meta/3` returns the serialized id of the metadata map,
which you pass to `map_set/4` / `map_get_json/3` exactly like a root
map. The two share the exact same API.

## Per-block content

For a block editor, each block typically holds a text container with
its body. Put the text container inside the metadata map:

```elixir
iex> block = LoroEx.tree_create_node(doc, "blocks", nil)
iex> meta = LoroEx.tree_get_meta(doc, "blocks", block)

iex> :ok = LoroEx.map_set(doc, meta, "kind", ~s("paragraph"))

# The "content" key holds a nested text container
iex> content_cid = LoroEx.map_insert_container(doc, meta, "content", :text)
iex> :ok = LoroEx.insert_text(doc, content_cid, 0, "Hello, world!")

iex> :ok = LoroEx.text_mark(doc, content_cid, 0, 5, "bold", true)

iex> LoroEx.text_to_delta(doc, content_cid)
[
  %{"insert" => "Hello", "attributes" => %{"bold" => true}},
  %{"insert" => ", world!"}
]
```

Rich text on every block, with marks, without the block's position in
the tree ever affecting the text itself.

## A complete block schema

For a Notion-like editor, a reasonable shape:

```
tree "blocks"
├── node "page_id"
│   meta: { title, icon, kind: "page" }
│   children:
│     ├── node "heading_id"
│     │   meta: { kind: "heading", level: 1 }
│     │   meta.content: text "Introduction"
│     ├── node "para_id"
│     │   meta: { kind: "paragraph" }
│     │   meta.content: text "Body of the page…"
│     └── node "list_id"
│         meta: { kind: "bulleted_list" }
│         children:
│           ├── node "item1_id"
│           │   meta: { kind: "list_item" }
│           │   meta.content: text "First bullet"
│           └── node "item2_id"
│               meta: { kind: "list_item" }
│               meta.content: text "Second bullet"
```

Creating this structure:

```elixir
def create_block(doc, kind, parent \\ nil, props \\ %{}) do
  node = LoroEx.tree_create_node(doc, "blocks", parent)
  meta = LoroEx.tree_get_meta(doc, "blocks", node)

  :ok = LoroEx.map_set(doc, meta, "kind", Jason.encode!(kind))
  for {k, v} <- props do
    :ok = LoroEx.map_set(doc, meta, k, Jason.encode!(v))
  end

  # Every block has a content text container
  content = LoroEx.map_insert_container(doc, meta, "content", :text)
  {node, content}
end

# Usage
{page, _} = create_block(doc, "page", nil, %{"title" => "My page"})
{heading, heading_content} = create_block(doc, "heading", page, %{"level" => 1})
:ok = LoroEx.insert_text(doc, heading_content, 0, "Introduction")

{para, para_content} = create_block(doc, "paragraph", page)
:ok = LoroEx.insert_text(doc, para_content, 0, "Body of the page…")
```

## Drag-to-reorder

The whole point of a movable tree is that drag-to-reorder Just Works:

```elixir
# User drags the heading to be the 3rd child instead of the 1st
:ok = LoroEx.tree_move_node(doc, "blocks", heading, page, 2)
```

No recreation of the node, no descendant loss. A concurrent drag on
another peer (moving the same heading elsewhere) is resolved
automatically.

## Concurrent moves — the guarantee

The classic test:

```elixir
iex> alice = LoroEx.new(1)
iex> bob = LoroEx.new(2)

iex> a = LoroEx.tree_create_node(alice, "blocks", nil)
iex> b = LoroEx.tree_create_node(alice, "blocks", nil)

iex> :ok = LoroEx.apply_update(bob, LoroEx.export_snapshot(alice))

# Concurrent moves: alice puts a under b; bob puts b under a
iex> :ok = LoroEx.tree_move_node(alice, "blocks", a, b, 0)
iex> :ok = LoroEx.tree_move_node(bob, "blocks", b, a, 0)

# After sync, both converge
iex> :ok = LoroEx.apply_update(alice, LoroEx.export_snapshot(bob))
iex> :ok = LoroEx.apply_update(bob, LoroEx.export_snapshot(alice))

iex> LoroEx.tree_get_nodes(alice, "blocks") == LoroEx.tree_get_nodes(bob, "blocks")
true
```

Both sides end up with the same tree. The "lower-priority" move is
canceled locally but remains in the oplog so all peers eventually
agree.

## Structured diff subscriptions for the tree

An editor UI rendering the block tree needs to know what changed.
`subscribe_container/3` on the tree delivers structured diffs:

```elixir
_sub = LoroEx.subscribe_container(doc, "blocks", self())

:ok = LoroEx.tree_create_node(doc, "blocks", page_id)

# Receive:
# {:loro_diff, _sub, json}
# Decoded:
# [
#   %{"target" => "cid:root-blocks:Tree",
#     "path" => [],
#     "diff" => %{"type" => "tree", "diff" => [
#       %{"action" => "create", "target" => "0@1", "parent" => page_id, "index" => 0, "position" => "..."}
#     ]}}
# ]
```

Tree diff actions are `create`, `move`, `delete`. For `move` the
entry includes both the old and new parent/index.

To hook this up to an editor, map each action:

```elixir
def handle_info({:loro_diff, _sub, json}, state) do
  events = Jason.decode!(json)

  for event <- events, tree_diff = get_in(event, ["diff", "diff"]) do
    for action <- tree_diff do
      case action["action"] do
        "create" ->
          render_insert_block(action["target"], action["parent"], action["index"])

        "move" ->
          render_move_block(
            action["target"],
            action["old_parent"], action["old_index"],
            action["parent"], action["index"]
          )

        "delete" ->
          render_remove_block(action["target"])
      end
    end
  end

  {:noreply, state}
end
```

## Common pitfalls

### Don't hold on to node ids after peers have diverged

A TreeID from peer A is valid in peer B *only after B has synced A's
ops*. Don't pass a freshly-created TreeID to another peer before
syncing; the other peer will return `{:error, {:tree_node_not_found,
_}}`.

### Index is relative to the parent

When you move a node with `index: 2`, you're saying "be the 3rd
child of the new parent." If the parent has only 2 children already,
`index: 2` means "append." If the parent has 5 children, `index: 2`
means "insert at position 2, shift others down."

### Fractional indices are enabled automatically

LoroEx enables fractional indexing on every tree it touches (via
`enable_fractional_index(0)`). You don't need to think about this.
Fractional indices are what make the tree's ordering stable under
concurrent reorders — Loro assigns each node a sort key like `"0.5"`
so inserting between `"0.5"` and `"0.6"` becomes `"0.55"` rather than
shifting everything.

## What's not covered

These are on the roadmap but not yet exposed:

- Direct `children/2` / `parent/2` queries (today you parse
  `tree_get_nodes/2` JSON).
- `mov_after/3` / `mov_before/3` for relative-sibling moves.
- `roots/1` — get just the top-level nodes.

For each of these, you can work from `tree_get_nodes/2` today.
