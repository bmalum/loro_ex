# Rich text

Loro's headline text feature is **Peritext**: formatting that survives
concurrent edits correctly. If Alice bolds "hello" while Bob
simultaneously inserts "!" in the middle, the result on both sides is
bolded "hel!lo" — not two separate bolded runs with an unbolded "!"
gap. This guide covers how to use Peritext from LoroEx and how to
integrate with TipTap, ProseMirror, CodeMirror, or any Quill-compatible
editor.

## Insert text, apply marks

```elixir
iex> doc = LoroEx.new()
iex> :ok = LoroEx.insert_text(doc, "body", 0, "Hello, world!")
iex> :ok = LoroEx.text_mark(doc, "body", 0, 5, "bold", true)
iex> :ok = LoroEx.text_mark(doc, "body", 7, 12, "link", "https://loro.dev")
```

`text_mark/6` takes:
- the doc
- the container id (root name or nested id)
- start and end (Unicode codepoint indices, half-open range)
- the mark key (e.g. `"bold"`, `"italic"`, `"link"`, `"color"`)
- a JSON-encodable scalar value

Values are scalars only — boolean, number, string, or `nil`. This
matches `map_set/4`. For a boolean mark like `bold`, pass `true`. For
a link, pass the URL as a string. For a color, pass the hex string.

## Remove a mark

```elixir
iex> :ok = LoroEx.text_unmark(doc, "body", 2, 4, "bold")
```

Only the portion of the mark that falls inside `start..end` is
removed. A bold mark from 0..10 with `text_unmark(3, 7, "bold")`
becomes two marks: 0..3 and 7..10.

## Read as a Quill delta

```elixir
iex> doc = LoroEx.new()
iex> :ok = LoroEx.insert_text(doc, "body", 0, "Hello world!")
iex> :ok = LoroEx.text_mark(doc, "body", 0, 5, "bold", true)
iex> LoroEx.text_to_delta(doc, "body")
[
  %{"insert" => "Hello", "attributes" => %{"bold" => true}},
  %{"insert" => " world!"}
]
```

This is the [Quill delta format](https://quilljs.com/docs/delta/), the
lingua franca of rich-text editors on the web. TipTap, ProseMirror,
and CodeMirror all speak it.

## Apply a delta

Inverse of `text_to_delta/2`. Useful when bootstrapping a mirror doc
from another peer, or applying an editor's output delta:

```elixir
iex> source = LoroEx.new(1)
iex> :ok = LoroEx.insert_text(source, "body", 0, "Hello")
iex> :ok = LoroEx.text_mark(source, "body", 0, 5, "bold", true)
iex> delta = LoroEx.text_to_delta(source, "body")

iex> mirror = LoroEx.new(2)
iex> :ok = LoroEx.text_apply_delta(mirror, "body", delta)
iex> LoroEx.text_to_delta(mirror, "body") == delta
true
```

## Choosing mark keys

Use lowercase keys that match your editor's attribute names. Standard
conventions:

| Key | Value shape | Notes |
|---|---|---|
| `"bold"` | `true` | Boolean flag |
| `"italic"` | `true` | |
| `"underline"` | `true` | |
| `"strike"` | `true` | |
| `"code"` | `true` | Inline code |
| `"link"` | `"https://…"` (string) | URL |
| `"color"` | `"#ff0000"` (string) | Hex or named |
| `"background"` | `"#ffff00"` (string) | Highlighter |
| `"size"` | `14` (number) | Font size in pt/px |
| `"align"` | `"left" | "center" | "right"` | Block-level |
| `"mention"` | `"@alice"` (string) | Or a JSON-stringified payload |

**A mark key should always carry the same expand behavior.** Loro's
internal model is: when you insert text at a mark's boundary, does
the mark expand to include the new text? Boolean formatting marks
like `bold` should expand *after* the range (typing past a bolded
word keeps bolding). Links should **not** expand (typing past a link
shouldn't extend the URL). Loro sets the default per key based on its
own rules; changing a key's expand behavior later breaks existing
marks.

## Integrating with TipTap / ProseMirror / CodeMirror

The pattern on the browser side:

1. On editor mount, call the server for the initial doc state.
2. The server responds with a Quill delta from `text_to_delta/2`.
3. The editor applies the delta to its internal model.
4. On every editor change, it emits an output delta.
5. You ship that delta to the server.
6. The server calls `text_apply_delta/3` and broadcasts the resulting
   update bytes (via `subscribe/2`) to other clients.

A rough server-side GenServer loop:

```elixir
def handle_call({:apply_editor_delta, delta}, _from, state) do
  case LoroEx.text_apply_delta(state.doc, "body", delta) do
    :ok ->
      # subscribe/2 callback will broadcast bytes to peers
      {:reply, :ok, state}

    {:error, {reason, _}} = err ->
      Logger.warning("editor delta rejected: \#{reason}")
      {:reply, err, state}
  end
end
```

## Structured diff subscriptions for editors

For editors, raw update bytes (`subscribe/2`) are less useful than
**structured diff events** (`subscribe_container/3`). The latter tells
you exactly what changed, in Quill delta format, ready to feed into
the editor's apply-op path:

```elixir
iex> doc = LoroEx.new()
iex> _sub = LoroEx.subscribe_container(doc, "body", self())

iex> :ok = LoroEx.insert_text(doc, "body", 0, "hi")

iex> receive do
...>   {:loro_diff, _sub, events_json} ->
...>     events = Jason.decode!(events_json)
...>     # events[0]["diff"]["ops"] is a Quill delta:
...>     # [%{"insert" => "hi"}]
...> end
```

## UTF-16 positions (browser editors)

Browsers index text in UTF-16 code units; Loro uses Unicode
codepoints. The difference only matters for characters outside the
Basic Multilingual Plane (emoji, some CJK), but when it matters it
breaks in *subtle* ways — cursors land in the wrong place, marks
extend one character too far.

Convert at the boundary:

```elixir
# Browser says "user clicked at UTF-16 index 42"
browser_pos = 42
unicode_pos = LoroEx.text_convert_pos(doc, "body", browser_pos, :utf16, :unicode)

# ...use unicode_pos for LoroEx.insert_text, text_mark, etc.

# Send a position back to the browser
reply_pos = LoroEx.text_convert_pos(doc, "body", unicode_pos, :unicode, :utf16)
```

Lengths follow the same pattern:

```elixir
LoroEx.text_len(doc, "body", :unicode)   # default
LoroEx.text_len(doc, "body", :utf8)      # for byte-indexed tokenizers
LoroEx.text_len(doc, "body", :utf16)     # for browser editors
```

## Stable cursors for selections

An editor cursor/selection is really "where in the text am I?" — an
integer index that breaks the moment someone else edits above you.
Use stable cursors to preserve selections across concurrent edits:

```elixir
# On selection change, convert to cursors
start_cursor = LoroEx.text_get_cursor(doc, "body", selection_start, :left)
end_cursor   = LoroEx.text_get_cursor(doc, "body", selection_end, :right)

# ...arbitrary concurrent edits happen...

# On next render, resolve back
{start_pos, _} = LoroEx.cursor_resolve(doc, start_cursor)
{end_pos, _}   = LoroEx.cursor_resolve(doc, end_cursor)
# feed (start_pos, end_pos) to the editor
```

See [Presence & cursors](presence_and_cursors.md) for the full
multi-user cursor pattern.

## What about undo?

`Ctrl+Z` in a rich-text editor spans multiple keystrokes (undo a whole
word, not one character). See the [Undo guide](undo.md) for the
checkpoint pattern and merge-interval tuning.
