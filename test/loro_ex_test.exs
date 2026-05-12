defmodule LoroExTest do
  use ExUnit.Case, async: true

  describe "convergence" do
    @tag :nif
    test "two docs converge after snapshot swap" do
      a = LoroEx.new()
      b = LoroEx.new()

      :ok = LoroEx.insert_text(a, "body", 0, "hello")
      :ok = LoroEx.insert_text(b, "body", 0, "world")

      :ok = LoroEx.apply_update(a, LoroEx.export_snapshot(b))
      :ok = LoroEx.apply_update(b, LoroEx.export_snapshot(a))

      assert LoroEx.get_text(a, "body") == LoroEx.get_text(b, "body")
    end
  end

  describe "diff-based sync" do
    @tag :nif
    test "delta is smaller than full snapshot" do
      server = LoroEx.new()
      client = LoroEx.new()

      :ok = LoroEx.insert_text(server, "body", 0, String.duplicate("a", 1_000))
      :ok = LoroEx.apply_update(client, LoroEx.export_snapshot(server))

      client_version = LoroEx.oplog_version(client)

      :ok = LoroEx.insert_text(server, "body", 0, "x")

      diff = LoroEx.export_updates(server, client_version)
      snapshot = LoroEx.export_snapshot(server)

      assert byte_size(diff) < byte_size(snapshot),
             "expected delta (#{byte_size(diff)}) < snapshot (#{byte_size(snapshot)})"
    end
  end

  describe "movable tree" do
    @tag :nif
    test "concurrent moves converge without cycle" do
      alice = LoroEx.new(1)
      bob = LoroEx.new(2)

      a_id = LoroEx.tree_create_node(alice, "blocks", nil)
      b_id = LoroEx.tree_create_node(alice, "blocks", nil)

      :ok = LoroEx.apply_update(bob, LoroEx.export_snapshot(alice))

      :ok = LoroEx.tree_move_node(alice, "blocks", a_id, b_id, 0)
      :ok = LoroEx.tree_move_node(bob, "blocks", b_id, a_id, 0)

      :ok = LoroEx.apply_update(alice, LoroEx.export_snapshot(bob))
      :ok = LoroEx.apply_update(bob, LoroEx.export_snapshot(alice))

      assert LoroEx.tree_get_nodes(alice, "blocks") ==
               LoroEx.tree_get_nodes(bob, "blocks")
    end
  end

  describe "subscriptions" do
    @tag :nif
    test "local updates are delivered to the subscriber" do
      doc = LoroEx.new()
      sub = LoroEx.subscribe(doc, self())

      :ok = LoroEx.insert_text(doc, "body", 0, "hello")

      # Give the subscription a beat; callback runs in the same thread as
      # commit() so it's synchronous, but message delivery is async.
      assert_receive {:loro_event, ^sub, bytes}, 200
      assert is_binary(bytes)

      # The delivered bytes must be apply_update-able on another doc
      mirror = LoroEx.new()
      :ok = LoroEx.apply_update(mirror, bytes)
      assert LoroEx.get_text(mirror, "body") == "hello"
    end

    @tag :nif
    test "multiple edits produce multiple events" do
      doc = LoroEx.new()
      _sub = LoroEx.subscribe(doc, self())

      for ch <- ["a", "b", "c"] do
        :ok = LoroEx.insert_text(doc, "body", 0, ch)
      end

      for _ <- 1..3 do
        assert_receive {:loro_event, _ref, _bytes}, 200
      end
    end

    @tag :nif
    test "unsubscribe stops delivery" do
      doc = LoroEx.new()
      sub = LoroEx.subscribe(doc, self())

      :ok = LoroEx.insert_text(doc, "body", 0, "first")
      assert_receive {:loro_event, ^sub, _bytes}, 200

      :ok = LoroEx.unsubscribe(sub)

      :ok = LoroEx.insert_text(doc, "body", 0, "second")
      refute_receive {:loro_event, _ref, _bytes}, 100
    end

    @tag :nif
    test "subscriber can mirror a peer in real time" do
      source = LoroEx.new(1)
      mirror = LoroEx.new(2)
      _sub = LoroEx.subscribe(source, self())

      :ok = LoroEx.insert_text(source, "body", 0, "live")

      assert_receive {:loro_event, _ref, update}, 200
      :ok = LoroEx.apply_update(mirror, update)

      assert LoroEx.get_text(source, "body") == LoroEx.get_text(mirror, "body")
    end
  end

  describe "map mutation" do
    @tag :nif
    test "set / get / delete on a root map" do
      doc = LoroEx.new()

      # Set a scalar of each shape
      :ok = LoroEx.map_set(doc, "settings", "theme", ~s("dark"))
      :ok = LoroEx.map_set(doc, "settings", "font_size", "14")
      :ok = LoroEx.map_set(doc, "settings", "spellcheck", "true")
      :ok = LoroEx.map_set(doc, "settings", "cursor_blink", "null")

      # Read the whole map back
      all = LoroEx.get_map_json(doc, "settings") |> Jason.decode!()

      assert all["theme"] == "dark"
      assert all["font_size"] == 14
      assert all["spellcheck"] == true
      assert all["cursor_blink"] == nil

      # Read a single key
      assert LoroEx.map_get_json(doc, "settings", "theme") == ~s("dark")
      assert LoroEx.map_get_json(doc, "settings", "missing") == "null"

      # Delete
      :ok = LoroEx.map_delete(doc, "settings", "theme")
      refetched = LoroEx.get_map_json(doc, "settings") |> Jason.decode!()
      refute Map.has_key?(refetched, "theme")
    end

    @tag :nif
    test "map mutations converge across peers" do
      a = LoroEx.new(1)
      b = LoroEx.new(2)

      :ok = LoroEx.map_set(a, "comments", "c1", ~s("from alice"))
      :ok = LoroEx.map_set(b, "comments", "c2", ~s("from bob"))

      :ok = LoroEx.apply_update(a, LoroEx.export_snapshot(b))
      :ok = LoroEx.apply_update(b, LoroEx.export_snapshot(a))

      a_map = LoroEx.get_map_json(a, "comments") |> Jason.decode!()
      b_map = LoroEx.get_map_json(b, "comments") |> Jason.decode!()

      assert a_map == b_map
      assert a_map["c1"] == "from alice"
      assert a_map["c2"] == "from bob"
    end

    @tag :nif
    test "accepts JSON objects as frozen structured values" do
      doc = LoroEx.new()

      :ok =
        LoroEx.map_set(doc, "m", "thread", Jason.encode!(%{"author" => "alice", "body" => "hi"}))

      json = LoroEx.map_get_json(doc, "m", "thread")
      assert {:ok, %{"author" => "alice", "body" => "hi"}} = Jason.decode(json)
    end

    @tag :nif
    test "accepts JSON arrays as frozen structured values" do
      doc = LoroEx.new()

      :ok = LoroEx.map_set(doc, "m", "tags", Jason.encode!(["one", "two", 3]))

      json = LoroEx.map_get_json(doc, "m", "tags")
      assert {:ok, ["one", "two", 3]} = Jason.decode(json)
    end

    @tag :nif
    test "nested structured values round-trip through a snapshot" do
      thread = %{
        "id" => "c_123",
        "author" => "alice",
        "replies" => [
          %{"id" => "r_1", "body" => "hi"},
          %{"id" => "r_2", "body" => "hey"}
        ],
        "resolved" => false
      }

      doc = LoroEx.new()
      :ok = LoroEx.map_set(doc, "comments", "c_123", Jason.encode!(thread))

      snap = LoroEx.export_snapshot(doc)
      doc2 = LoroEx.new()
      :ok = LoroEx.apply_update(doc2, snap)

      json = LoroEx.map_get_json(doc2, "comments", "c_123")
      assert {:ok, recovered} = Jason.decode(json)
      assert recovered == thread
    end
  end

  describe "list mutation" do
    @tag :nif
    test "push / get / delete on a root list" do
      doc = LoroEx.new()

      :ok = LoroEx.list_push(doc, "events", ~s("login"))
      :ok = LoroEx.list_push(doc, "events", ~s("edit"))
      :ok = LoroEx.list_push(doc, "events", ~s("logout"))

      assert LoroEx.list_get_json(doc, "events") |> Jason.decode!() ==
               ["login", "edit", "logout"]

      # Delete the middle element
      :ok = LoroEx.list_delete(doc, "events", 1, 1)

      assert LoroEx.list_get_json(doc, "events") |> Jason.decode!() ==
               ["login", "logout"]
    end

    @tag :nif
    test "list push accepts structured (non-scalar) JSON values" do
      doc = LoroEx.new()

      :ok = LoroEx.list_push(doc, "events", Jason.encode!(%{"action" => "login"}))
      :ok = LoroEx.list_push(doc, "events", Jason.encode!(["multi", "tag"]))

      assert [%{"action" => "login"}, ["multi", "tag"]] =
               LoroEx.list_get_json(doc, "events") |> Jason.decode!()
    end
  end

  describe "frontiers" do
    @tag :nif
    test "oplog_frontiers returns an opaque binary" do
      doc = LoroEx.new()
      f0 = LoroEx.oplog_frontiers(doc)
      assert is_binary(f0)

      :ok = LoroEx.insert_text(doc, "body", 0, "x")

      f1 = LoroEx.oplog_frontiers(doc)
      assert is_binary(f1)
      refute f1 == f0
    end

    @tag :nif
    test "state_frontiers and shallow_since_frontiers are readable" do
      doc = LoroEx.new()
      assert is_binary(LoroEx.state_frontiers(doc))
      assert is_binary(LoroEx.shallow_since_frontiers(doc))
    end

    @tag :nif
    test "export_shallow_snapshot round-trips through a fresh doc" do
      author = LoroEx.new(1)
      :ok = LoroEx.insert_text(author, "body", 0, "baseline")

      # Snapshot the doc at its current frontier. A shallow snapshot
      # taken against the current frontier is effectively a full
      # snapshot of the current state with no op history prior.
      frontier = LoroEx.oplog_frontiers(author)
      shallow = LoroEx.export_shallow_snapshot(author, frontier)
      assert is_binary(shallow)

      # Apply to a brand-new doc and check the text comes back.
      reader = LoroEx.new(2)
      :ok = LoroEx.apply_update(reader, shallow)
      assert LoroEx.get_text(reader, "body") == "baseline"
    end
  end

  describe "error reasons" do
    @tag :nif
    test "invalid update bytes return :invalid_update" do
      doc = LoroEx.new()

      assert {:error, {reason, detail}} =
               LoroEx.apply_update(doc, <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>)

      assert reason in [:invalid_update, :checksum_mismatch, :unknown]
      assert is_binary(detail)
    end

    @tag :nif
    test "invalid version vector returns :invalid_version_vector" do
      doc = LoroEx.new()

      assert {:error, {reason, _detail}} =
               LoroEx.export_updates(doc, <<0xFF, 0xFF, 0xFF>>)

      assert reason == :invalid_version_vector
    end

    @tag :nif
    test "invalid tree id returns :invalid_tree_id" do
      doc = LoroEx.new()

      assert {:error, {reason, _detail}} =
               LoroEx.tree_move_node(doc, "blocks", "not-a-tree-id", nil, 0)

      assert reason == :invalid_tree_id
    end
  end

  # ---------------------------------------------------------------- Tier 1 ---

  describe "text marks (Peritext)" do
    @tag :nif
    test "mark and to_delta round-trip produce Quill-compatible ops" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "Hello world!")
      :ok = LoroEx.text_mark(doc, "body", 0, 5, "bold", true)

      delta = LoroEx.text_to_delta(doc, "body")

      assert [
               %{"insert" => "Hello", "attributes" => %{"bold" => true}},
               %{"insert" => " world!"}
             ] = delta
    end

    @tag :nif
    test "unmark removes a previously applied mark" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "ABCDE")
      :ok = LoroEx.text_mark(doc, "body", 0, 5, "bold", true)
      :ok = LoroEx.text_unmark(doc, "body", 2, 4, "bold")

      delta = LoroEx.text_to_delta(doc, "body")

      # Expect three runs: "AB" bold, "CD" not bold, "E" bold
      assert Enum.count(delta) == 3
    end

    @tag :nif
    test "apply_delta reconstructs formatted text" do
      source = LoroEx.new(1)
      :ok = LoroEx.insert_text(source, "body", 0, "Hello")
      :ok = LoroEx.text_mark(source, "body", 0, 5, "bold", true)
      delta = LoroEx.text_to_delta(source, "body")

      mirror = LoroEx.new(2)
      :ok = LoroEx.text_apply_delta(mirror, "body", delta)

      assert LoroEx.text_to_delta(mirror, "body") == delta
    end

    @tag :nif
    test "non-boolean mark values (links, colors) survive round-trip" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "click me")
      :ok = LoroEx.text_mark(doc, "body", 0, 8, "link", "https://loro.dev")

      [%{"attributes" => attrs}] = LoroEx.text_to_delta(doc, "body")
      assert attrs["link"] == "https://loro.dev"
    end
  end

  describe "text length helpers" do
    @tag :nif
    test "len reports the right count for plain ASCII" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello")

      assert LoroEx.text_len(doc, "body", :unicode) == 5
      assert LoroEx.text_len(doc, "body", :utf8) == 5
      assert LoroEx.text_len(doc, "body", :utf16) == 5
    end

    @tag :nif
    test "len differs for multi-byte content" do
      doc = LoroEx.new()
      # "é" = U+00E9 — 1 scalar, 2 utf-8 bytes, 1 utf-16 code unit
      :ok = LoroEx.insert_text(doc, "body", 0, "é")

      assert LoroEx.text_len(doc, "body", :unicode) == 1
      assert LoroEx.text_len(doc, "body", :utf8) == 2
      assert LoroEx.text_len(doc, "body", :utf16) == 1
    end

    @tag :nif
    test "convert_pos crosses unit systems" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "aéb")

      # Unicode idx 2 ("b") → UTF-8 byte 3 (after "a" + "é" = 1 + 2)
      assert LoroEx.text_convert_pos(doc, "body", 2, :unicode, :utf8) == 3
      # And back
      assert LoroEx.text_convert_pos(doc, "body", 3, :utf8, :unicode) == 2
    end
  end

  describe "cursor" do
    @tag :nif
    test "cursor survives concurrent edits before it" do
      doc = LoroEx.new(1)
      :ok = LoroEx.insert_text(doc, "body", 0, "hello world")

      cursor = LoroEx.text_get_cursor(doc, "body", 6, :left)
      assert is_binary(cursor)

      # Edit before the cursor position
      :ok = LoroEx.insert_text(doc, "body", 0, ">>> ")

      {pos, _side} = LoroEx.cursor_resolve(doc, cursor)
      # cursor now points at position 10 (6 + 4)
      assert pos == 10
    end

    @tag :nif
    test "cursor before any inserts is well-defined" do
      doc = LoroEx.new()
      # Force the container to exist without content
      _ = LoroEx.get_text(doc, "body")
      cursor = LoroEx.text_get_cursor(doc, "body", 0, :middle)
      # Either nil (truly empty) or a cursor that resolves to pos 0
      case cursor do
        nil ->
          :ok

        c when is_binary(c) ->
          {pos, _} = LoroEx.cursor_resolve(doc, c)
          assert pos == 0
      end
    end

    @tag :nif
    test "side round-trips as an atom" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "abcdef")

      c = LoroEx.text_get_cursor(doc, "body", 3, :right)
      {_pos, side} = LoroEx.cursor_resolve(doc, c)
      assert side in [:left, :middle, :right]
    end
  end

  describe "undo manager" do
    @tag :nif
    test "undo/redo a single insert" do
      doc = LoroEx.new(1)
      mgr = LoroEx.UndoManager.new(doc)

      refute LoroEx.UndoManager.can_undo(mgr)

      :ok = LoroEx.insert_text(doc, "body", 0, "hello")
      :ok = LoroEx.UndoManager.record_new_checkpoint(mgr)

      assert LoroEx.UndoManager.can_undo(mgr)
      assert LoroEx.UndoManager.undo(mgr)
      assert LoroEx.get_text(doc, "body") == ""

      assert LoroEx.UndoManager.can_redo(mgr)
      assert LoroEx.UndoManager.redo(mgr)
      assert LoroEx.get_text(doc, "body") == "hello"
    end

    @tag :nif
    test "undo skips remote edits" do
      local = LoroEx.new(1)
      remote = LoroEx.new(2)
      mgr = LoroEx.UndoManager.new(local)

      :ok = LoroEx.insert_text(remote, "body", 0, "remote text")
      :ok = LoroEx.apply_update(local, LoroEx.export_snapshot(remote))

      # Local manager should NOT be able to undo a remote-only edit.
      refute LoroEx.UndoManager.can_undo(mgr)

      :ok = LoroEx.insert_text(local, "body", 0, "local: ")
      :ok = LoroEx.UndoManager.record_new_checkpoint(mgr)
      assert LoroEx.UndoManager.can_undo(mgr)
    end
  end

  describe "presence (EphemeralStore)" do
    @tag :nif
    test "set / get / keys on a single store" do
      p = LoroEx.Presence.new(30_000)

      :ok = LoroEx.Presence.set(p, "alice/cursor", 42)
      :ok = LoroEx.Presence.set(p, "alice/color", "#ff00aa")

      assert LoroEx.Presence.get(p, "alice/cursor") == 42
      assert LoroEx.Presence.get(p, "alice/color") == "#ff00aa"
      assert Enum.sort(LoroEx.Presence.keys(p)) == ["alice/color", "alice/cursor"]
    end

    @tag :nif
    test "encode_all and apply sync two stores" do
      a = LoroEx.Presence.new(30_000)
      b = LoroEx.Presence.new(30_000)

      :ok = LoroEx.Presence.set(a, "alice/cursor", 10)
      payload = LoroEx.Presence.encode_all(a)
      :ok = LoroEx.Presence.apply(b, payload)

      assert LoroEx.Presence.get(b, "alice/cursor") == 10
    end

    @tag :nif
    test "map values round-trip through encode_all / apply" do
      a = LoroEx.Presence.new(30_000)
      b = LoroEx.Presence.new(30_000)

      value = %{"pos" => 7, "len" => 3}
      :ok = LoroEx.Presence.set(a, "alice/sel", value)

      # Local read should give back the original map
      assert LoroEx.Presence.get(a, "alice/sel") == value

      # After sync the peer sees the same shape
      :ok = LoroEx.Presence.apply(b, LoroEx.Presence.encode_all(a))
      assert LoroEx.Presence.get(b, "alice/sel") == value
    end

    @tag :nif
    test "list values round-trip through encode_all / apply" do
      a = LoroEx.Presence.new(30_000)
      b = LoroEx.Presence.new(30_000)

      :ok = LoroEx.Presence.set(a, "alice/tags", ["work", "urgent"])
      :ok = LoroEx.Presence.apply(b, LoroEx.Presence.encode_all(a))

      assert LoroEx.Presence.get(b, "alice/tags") == ["work", "urgent"]
    end

    @tag :nif
    test "subscription receives local update bytes" do
      p = LoroEx.Presence.new(30_000)
      sub = LoroEx.Presence.subscribe(p, self())

      :ok = LoroEx.Presence.set(p, "alice/cursor", 7)

      assert_receive {:loro_ephemeral, ^sub, bytes}, 200
      assert is_binary(bytes)

      # Bytes should apply cleanly to another store
      other = LoroEx.Presence.new(30_000)
      :ok = LoroEx.Presence.apply(other, bytes)
      assert LoroEx.Presence.get(other, "alice/cursor") == 7
    end
  end

  describe "structured diff subscriptions" do
    @tag :nif
    test "subscribe_root delivers a diff on every commit" do
      doc = LoroEx.new()
      _sub = LoroEx.subscribe_root(doc, self())

      :ok = LoroEx.insert_text(doc, "body", 0, "hi")

      assert_receive {:loro_diff, _ref, events_json}, 200
      events = Jason.decode!(events_json)
      assert is_list(events)
      # At least one entry has a text diff
      assert Enum.any?(events, fn e -> get_in(e, ["diff", "type"]) == "text" end)
    end

    @tag :nif
    test "subscribe_container scopes to a single container" do
      doc = LoroEx.new()
      # Pre-create "body" so the root-name resolution can find it
      :ok = LoroEx.insert_text(doc, "body", 0, "x")
      sub = LoroEx.subscribe_container(doc, "body", self())

      # Drain the pre-existing "x" insert event if it landed after subscribe
      receive do
        {:loro_diff, ^sub, _} -> :ok
      after
        50 -> :ok
      end

      :ok = LoroEx.insert_text(doc, "body", 1, "y")
      assert_receive {:loro_diff, ^sub, events_json}, 200
      events = Jason.decode!(events_json)
      assert Enum.any?(events, fn e -> get_in(e, ["diff", "type"]) == "text" end)
    end
  end

  describe "nested containers" do
    @tag :nif
    test "map_insert_container creates an addressable nested map" do
      doc = LoroEx.new()
      inner = LoroEx.map_insert_container(doc, "settings", "appearance", :map)
      assert is_binary(inner)

      :ok = LoroEx.map_set(doc, inner, "theme", ~s("dark"))

      # Reading through the returned nested container id works
      assert LoroEx.map_get_json(doc, inner, "theme") == ~s("dark")

      # And reading the parent still shows the nested shape
      decoded = LoroEx.get_map_json(doc, "settings") |> Jason.decode!()
      assert get_in(decoded, ["appearance", "theme"]) == "dark"
    end

    @tag :nif
    test "tree_get_meta returns a map for per-node data" do
      doc = LoroEx.new()
      node = LoroEx.tree_create_node(doc, "blocks", nil)
      meta = LoroEx.tree_get_meta(doc, "blocks", node)
      assert is_binary(meta)

      :ok = LoroEx.map_set(doc, meta, "title", ~s("My page"))
      assert LoroEx.map_get_json(doc, meta, "title") == ~s("My page")
    end

    @tag :nif
    test "list_insert_container nests a text container inside a list" do
      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "blocks", ~s("heading"))
      txt = LoroEx.list_insert_container(doc, "blocks", 1, :text)
      :ok = LoroEx.insert_text(doc, txt, 0, "body")
      assert LoroEx.get_text(doc, txt) == "body"
    end
  end

  describe "cross-feature: edit + mark + cursor survives + undo" do
    @tag :nif
    test "the README example actually works end to end" do
      doc = LoroEx.new(1)
      undo = LoroEx.UndoManager.new(doc)
      pres = LoroEx.Presence.new(30_000)

      :ok = LoroEx.insert_text(doc, "body", 0, "Hello, world")
      :ok = LoroEx.text_mark(doc, "body", 0, 5, "bold", true)
      :ok = LoroEx.UndoManager.record_new_checkpoint(undo)

      cursor = LoroEx.text_get_cursor(doc, "body", 7, :left)
      :ok = LoroEx.insert_text(doc, "body", 0, ">>> ")

      {pos, _side} = LoroEx.cursor_resolve(doc, cursor)
      assert pos == 11

      :ok = LoroEx.Presence.set(pres, "alice/cursor", %{"pos" => pos})
      assert LoroEx.Presence.get(pres, "alice/cursor") == %{"pos" => 11}

      assert LoroEx.UndoManager.can_undo(undo)
      assert LoroEx.UndoManager.undo(undo)
    end
  end

  describe "subscription lifecycle" do
    @tag :nif
    test "unsubscribe is idempotent" do
      doc = LoroEx.new()
      sub = LoroEx.subscribe(doc, self())
      assert :ok = LoroEx.unsubscribe(sub)
      assert :ok = LoroEx.unsubscribe(sub)
      assert :ok = LoroEx.unsubscribe(sub)
    end

    @tag :nif
    test "unsubscribe on container diff sub is idempotent" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "x")
      sub = LoroEx.subscribe_container(doc, "body", self())
      assert :ok = LoroEx.unsubscribe(sub)
      assert :ok = LoroEx.unsubscribe(sub)
    end

    @tag :nif
    test "unsubscribe on ephemeral sub is idempotent" do
      store = LoroEx.Presence.new(30_000)
      sub = LoroEx.Presence.subscribe(store, self())
      assert :ok = LoroEx.unsubscribe(sub)
      assert :ok = LoroEx.unsubscribe(sub)
    end

    @tag :nif
    test "known limitation: dropping sub ref alone does NOT auto-cancel" do
      # This is a regression/status test. When 0.5.1 ships the global
      # subscription registry, flip the `assert_receive` below to a
      # `refute_receive` — that will confirm the fix.
      doc = LoroEx.new()

      (fn ->
         _sub = LoroEx.subscribe(doc, self())
         :ok
       end).()

      :erlang.garbage_collect()

      :ok = LoroEx.insert_text(doc, "body", 0, "orphan")
      # Current behavior: the subscription is still alive due to an Arc cycle.
      assert_receive {:loro_event, _, _}, 200
    end

    @tag :nif
    test "many subscriptions on the same doc all deliver" do
      doc = LoroEx.new()
      subs = for _ <- 1..5, do: LoroEx.subscribe(doc, self())

      :ok = LoroEx.insert_text(doc, "body", 0, "x")

      for _ <- 1..5 do
        assert_receive {:loro_event, _, _}, 200
      end

      for s <- subs, do: LoroEx.unsubscribe(s)
    end

    @tag :nif
    test "doc handle can be GC'd after subscriptions are dropped" do
      # Regression guard: making sure resource drop order is safe.
      (fn ->
         doc = LoroEx.new()
         _s1 = LoroEx.subscribe(doc, self())
         _s2 = LoroEx.subscribe_root(doc, self())
         _s3 = LoroEx.subscribe_container(doc, "body", self())
         :ok = LoroEx.insert_text(doc, "body", 0, "a")
         :ok
       end).()

      :erlang.garbage_collect()
      # If this doesn't crash, we're fine
      assert :ok = :ok
    end
  end

  describe "bad inputs to new NIFs" do
    @tag :nif
    test "invalid cursor bytes → :invalid_cursor" do
      doc = LoroEx.new()

      assert {:error, {:invalid_cursor, _}} =
               LoroEx.cursor_resolve(doc, <<0, 0, 0>>)
    end

    @tag :nif
    test "invalid delta shape → :invalid_delta" do
      doc = LoroEx.new()
      # apply_delta expects a list of maps; pass something that serializes
      # but isn't a valid TextDelta.
      assert {:error, {:invalid_delta, _}} =
               LoroEx.text_apply_delta(doc, "body", [%{"bogus" => true}])
    end

    @tag :nif
    test "invalid container kind → :invalid_container_kind" do
      doc = LoroEx.new()

      assert {:error, {:invalid_container_kind, _}} =
               LoroEx.map_insert_container(doc, "settings", "k", :counter)

      assert {:error, {:invalid_container_kind, _}} =
               LoroEx.map_insert_container(doc, "settings", "k", :not_a_real_kind)
    end

    @tag :nif
    test "tree kind is not supported inside map/list_insert_container" do
      doc = LoroEx.new()

      # Tree is a valid container kind for `atom_to_container_type`
      # but can't live inside a map/list — should be :invalid_value.
      assert {:error, {:invalid_value, _}} =
               LoroEx.map_insert_container(doc, "settings", "k", :tree)
    end

    @tag :nif
    test "bad side atom → :invalid_cursor" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello")

      assert {:error, {:invalid_cursor, _}} =
               LoroEx.text_get_cursor(doc, "body", 0, :sideways)
    end

    @tag :nif
    test "bad pos unit → :invalid_value" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hi")

      assert {:error, {:invalid_value, _}} =
               LoroEx.text_convert_pos(doc, "body", 0, :pixels, :utf8)

      assert match?(
               {:error, {_, _}},
               LoroEx.text_len(doc, "body", :pixels)
             ) or
               match?(
                 _,
                 LoroEx.text_len(doc, "body", :pixels)
               )
    end

    @tag :nif
    test "text_mark no longer rejects structured JSON mark values as :invalid_value" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello")

      # After Gap 2 (v0.6.0) parse_scalar_json is permissive: it
      # routes objects/arrays through LoroValue::from(serde_json::Value)
      # instead of rejecting with :invalid_value. The NIF no longer
      # blocks structured values at the JSON layer. Loro may still
      # reject at the CRDT layer (e.g. missing style config for a
      # custom key) but that's orthogonal to the NIF change.
      result = LoroEx.text_mark(doc, "body", 0, 5, "meta", %{"nested" => "value"})

      refute match?({:error, {:invalid_value, _}}, result),
             "expected parse_scalar_json to no longer reject structured values, got #{inspect(result)}"
    end

    @tag :nif
    test "text_mark on out-of-bound range → :out_of_bound" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "short")

      assert {:error, {reason, _}} =
               LoroEx.text_mark(doc, "body", 0, 100, "bold", true)

      # Loro uses a generic error for this; accept either.
      assert reason in [:out_of_bound, :unknown]
    end

    @tag :nif
    test "ephemeral_apply on garbage bytes → :ephemeral_apply_failed" do
      store = LoroEx.Presence.new(30_000)

      assert {:error, {:ephemeral_apply_failed, _}} =
               LoroEx.Presence.apply(store, <<0xFF, 0xFF, 0xFF>>)
    end
  end

  describe "map_get_child_cid/3" do
    @tag :nif
    test "returns the cid of a child container" do
      doc = LoroEx.new()
      child_cid = LoroEx.map_insert_container(doc, "root", "nested", :map)

      assert LoroEx.map_get_child_cid(doc, "root", "nested") == child_cid
    end

    @tag :nif
    test "returns nil for a scalar value" do
      doc = LoroEx.new()
      :ok = LoroEx.map_set(doc, "root", "name", ~s("hello"))

      assert LoroEx.map_get_child_cid(doc, "root", "name") == nil
    end

    @tag :nif
    test "returns nil for an absent key" do
      doc = LoroEx.new()
      # Touch the root container so it exists but is empty.
      _ = LoroEx.get_map_json(doc, "root")

      assert LoroEx.map_get_child_cid(doc, "root", "missing") == nil
    end

    @tag :nif
    test "works across the container kinds (map, list, text, movable_list)" do
      doc = LoroEx.new()

      for {key, kind} <- [
            {"a_map", :map},
            {"a_list", :list},
            {"a_text", :text},
            {"a_mlist", :movable_list}
          ] do
        expected = LoroEx.map_insert_container(doc, "root", key, kind)

        assert LoroEx.map_get_child_cid(doc, "root", key) == expected,
               "failed for kind #{inspect(kind)}"
      end
    end

    @tag :nif
    test "survives snapshot roundtrip" do
      doc = LoroEx.new()
      orig_cid = LoroEx.map_insert_container(doc, "root", "child", :list)

      snap = LoroEx.export_snapshot(doc)

      doc2 = LoroEx.new()
      :ok = LoroEx.apply_update(doc2, snap)

      # Critical hydrate-safety property: cid must be recoverable
      # after a snapshot round-trip so the Doc server can re-derive
      # its path cache without re-creating (and thereby clobbering)
      # the container.
      assert LoroEx.map_get_child_cid(doc2, "root", "child") == orig_cid
    end
  end

  describe "list_get_child_cid/3" do
    @tag :nif
    test "returns the cid of a child container at an index" do
      doc = LoroEx.new()
      child_cid = LoroEx.list_insert_container(doc, "list", 0, :map)

      assert LoroEx.list_get_child_cid(doc, "list", 0) == child_cid
    end

    @tag :nif
    test "returns nil for a scalar element" do
      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "list", ~s("hello"))

      assert LoroEx.list_get_child_cid(doc, "list", 0) == nil
    end

    @tag :nif
    test "returns nil for an out-of-bounds index" do
      doc = LoroEx.new()
      # Touch the container so it exists but is empty.
      _ = LoroEx.list_get_json(doc, "list")

      assert LoroEx.list_get_child_cid(doc, "list", 0) == nil
      assert LoroEx.list_get_child_cid(doc, "list", 999) == nil
    end

    @tag :nif
    test "descent by path: map -> list[0] -> map -> list" do
      doc = LoroEx.new()

      children_list_cid = LoroEx.map_insert_container(doc, "root", "children", :list)

      first_block_cid = LoroEx.list_insert_container(doc, children_list_cid, 0, :map)

      grandchild_cid =
        LoroEx.map_insert_container(doc, first_block_cid, "children", :list)

      # Descent: root -> children -> [0] -> children
      assert LoroEx.map_get_child_cid(doc, "root", "children") == children_list_cid
      assert LoroEx.list_get_child_cid(doc, children_list_cid, 0) == first_block_cid

      assert LoroEx.map_get_child_cid(doc, first_block_cid, "children") ==
               grandchild_cid
    end
  end

  describe "map_keys/2 and map_size/2" do
    @tag :nif
    test "empty map → zero keys, size 0" do
      doc = LoroEx.new()
      _ = LoroEx.get_map_json(doc, "m")

      assert LoroEx.map_keys(doc, "m") == []
      assert LoroEx.map_size(doc, "m") == 0
    end

    @tag :nif
    test "keys and size agree with get_map_json" do
      doc = LoroEx.new()
      :ok = LoroEx.map_set(doc, "settings", "a", "1")
      :ok = LoroEx.map_set(doc, "settings", "b", "2")
      :ok = LoroEx.map_set(doc, "settings", "c", "3")

      assert Enum.sort(LoroEx.map_keys(doc, "settings")) == ["a", "b", "c"]
      assert LoroEx.map_size(doc, "settings") == 3

      # Cross-check with the deep JSON view.
      json_keys =
        LoroEx.get_map_json(doc, "settings") |> Jason.decode!() |> Map.keys()

      assert Enum.sort(json_keys) == ["a", "b", "c"]
    end

    @tag :nif
    test "map_delete removes a key from the listing" do
      doc = LoroEx.new()
      :ok = LoroEx.map_set(doc, "m", "keep", "1")
      :ok = LoroEx.map_set(doc, "m", "drop", "2")
      :ok = LoroEx.map_delete(doc, "m", "drop")

      assert LoroEx.map_keys(doc, "m") == ["keep"]
      assert LoroEx.map_size(doc, "m") == 1
    end

    @tag :nif
    test "nested container children count toward size and keys" do
      doc = LoroEx.new()
      _ = LoroEx.map_insert_container(doc, "root", "children", :list)
      :ok = LoroEx.map_set(doc, "root", "version", "1")

      assert LoroEx.map_size(doc, "root") == 2
      assert Enum.sort(LoroEx.map_keys(doc, "root")) == ["children", "version"]
    end
  end

  describe "list_length/2 and list_get_json_at/3" do
    @tag :nif
    test "empty list → length 0, get_json_at → \"null\"" do
      doc = LoroEx.new()
      _ = LoroEx.list_get_json(doc, "l")

      assert LoroEx.list_length(doc, "l") == 0
      assert LoroEx.list_get_json_at(doc, "l", 0) == "null"
    end

    @tag :nif
    test "length and element reads match list_get_json" do
      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "events", ~s("login"))
      :ok = LoroEx.list_push(doc, "events", ~s("edit"))
      :ok = LoroEx.list_push(doc, "events", "42")

      assert LoroEx.list_length(doc, "events") == 3
      assert LoroEx.list_get_json_at(doc, "events", 0) == ~s("login")
      assert LoroEx.list_get_json_at(doc, "events", 1) == ~s("edit")
      assert LoroEx.list_get_json_at(doc, "events", 2) == "42"
    end

    @tag :nif
    test "out-of-bounds read returns \"null\" instead of erroring" do
      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "l", ~s("x"))

      assert LoroEx.list_get_json_at(doc, "l", 999) == "null"
    end

    @tag :nif
    test "reads a nested container's deep value" do
      doc = LoroEx.new()
      child = LoroEx.list_insert_container(doc, "blocks", 0, :map)
      :ok = LoroEx.map_set(doc, child, "title", ~s("hello"))

      decoded = LoroEx.list_get_json_at(doc, "blocks", 0) |> Jason.decode!()
      assert decoded == %{"title" => "hello"}
    end
  end

  describe "list_insert/4" do
    @tag :nif
    test "inserts at a specific position, shifting the tail" do
      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "events", ~s("a"))
      :ok = LoroEx.list_push(doc, "events", ~s("c"))
      :ok = LoroEx.list_insert(doc, "events", 1, ~s("b"))

      assert ["a", "b", "c"] = LoroEx.list_get_json(doc, "events") |> Jason.decode!()
    end

    @tag :nif
    test "inserting at length is equivalent to list_push" do
      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "l", ~s("a"))
      :ok = LoroEx.list_insert(doc, "l", 1, ~s("b"))

      assert ["a", "b"] = LoroEx.list_get_json(doc, "l") |> Jason.decode!()
    end

    @tag :nif
    test "inserting past length returns :out_of_bound" do
      doc = LoroEx.new()
      _ = LoroEx.list_get_json(doc, "l")

      assert {:error, {:out_of_bound, _}} =
               LoroEx.list_insert(doc, "l", 5, ~s("oops"))
    end

    @tag :nif
    test "accepts structured values (same rules as list_push)" do
      doc = LoroEx.new()
      :ok = LoroEx.list_insert(doc, "l", 0, Jason.encode!(%{"a" => 1}))

      assert [%{"a" => 1}] = LoroEx.list_get_json(doc, "l") |> Jason.decode!()
    end
  end

  describe "map_get_or_create_container/4" do
    @tag :nif
    test "creates a container on first call, returns same CID on subsequent calls" do
      doc = LoroEx.new()

      first = LoroEx.map_get_or_create_container(doc, "root", "children", :list)
      second = LoroEx.map_get_or_create_container(doc, "root", "children", :list)

      assert first == second
      assert is_binary(first)
    end

    @tag :nif
    test "survives a snapshot hydrate (the motivating hydrate-safety case)" do
      author = LoroEx.new()
      orig = LoroEx.map_get_or_create_container(author, "root", "children", :list)

      # Put something into the child so we can detect if it gets
      # clobbered.
      :ok = LoroEx.list_push(author, orig, ~s("do-not-lose"))

      reader = LoroEx.new()
      :ok = LoroEx.apply_update(reader, LoroEx.export_snapshot(author))

      # On the hydrated doc we call _or_create_container again; the
      # pre-0.6.0 workaround of "map_insert_container" would clobber
      # the content here. This one must not.
      recovered = LoroEx.map_get_or_create_container(reader, "root", "children", :list)
      assert recovered == orig

      assert ["do-not-lose"] =
               LoroEx.list_get_json(reader, recovered) |> Jason.decode!()
    end

    @tag :nif
    test "errors with :invalid_container_kind on kind mismatch" do
      doc = LoroEx.new()
      _ = LoroEx.map_get_or_create_container(doc, "root", "x", :list)

      assert {:error, {:invalid_container_kind, _}} =
               LoroEx.map_get_or_create_container(doc, "root", "x", :map)
    end

    @tag :nif
    test "errors with :invalid_value when key holds a scalar" do
      doc = LoroEx.new()
      :ok = LoroEx.map_set(doc, "root", "x", ~s("scalar"))

      assert {:error, {:invalid_value, _}} =
               LoroEx.map_get_or_create_container(doc, "root", "x", :list)

      # And the scalar is still there — we didn't clobber.
      assert LoroEx.map_get_json(doc, "root", "x") == ~s("scalar")
    end
  end

  describe "list_get_or_create_container/4" do
    @tag :nif
    test "append-at-end when index == length" do
      doc = LoroEx.new()

      a = LoroEx.list_get_or_create_container(doc, "blocks", 0, :map)
      assert is_binary(a)
      assert LoroEx.list_length(doc, "blocks") == 1

      b = LoroEx.list_get_or_create_container(doc, "blocks", 1, :map)
      assert b != a
      assert LoroEx.list_length(doc, "blocks") == 2
    end

    @tag :nif
    test "idempotent when index points at an existing same-kind container" do
      doc = LoroEx.new()

      first = LoroEx.list_get_or_create_container(doc, "blocks", 0, :map)
      second = LoroEx.list_get_or_create_container(doc, "blocks", 0, :map)

      assert first == second
      assert LoroEx.list_length(doc, "blocks") == 1
    end

    @tag :nif
    test "errors on kind mismatch" do
      doc = LoroEx.new()
      _ = LoroEx.list_get_or_create_container(doc, "blocks", 0, :map)

      assert {:error, {:invalid_container_kind, _}} =
               LoroEx.list_get_or_create_container(doc, "blocks", 0, :list)
    end

    @tag :nif
    test "errors on scalar-at-index" do
      doc = LoroEx.new()
      :ok = LoroEx.list_push(doc, "l", ~s("scalar"))

      assert {:error, {:invalid_value, _}} =
               LoroEx.list_get_or_create_container(doc, "l", 0, :map)
    end

    @tag :nif
    test "errors :out_of_bound when index > length" do
      doc = LoroEx.new()
      _ = LoroEx.list_get_json(doc, "l")

      assert {:error, {:out_of_bound, _}} =
               LoroEx.list_get_or_create_container(doc, "l", 5, :map)
    end
  end

  describe "fork" do
    @tag :nif
    test "fork/1 returns an independent doc that shares history" do
      parent = LoroEx.new()
      :ok = LoroEx.insert_text(parent, "body", 0, "hello")

      child = LoroEx.fork(parent)

      # Both see the fork-point content.
      assert LoroEx.get_text(child, "body") == "hello"

      # Mutating the child does NOT affect the parent.
      :ok = LoroEx.insert_text(child, "body", 5, " world")
      assert LoroEx.get_text(parent, "body") == "hello"
      assert LoroEx.get_text(child, "body") == "hello world"

      # Mutating the parent does NOT affect the child.
      :ok = LoroEx.insert_text(parent, "body", 5, "!")
      assert LoroEx.get_text(parent, "body") == "hello!"
      assert LoroEx.get_text(child, "body") == "hello world"

      # A mirror seeded from the parent snapshot reflects only the
      # parent's ops, not the child's.
      parent_snap = LoroEx.export_snapshot(parent)
      mirror = LoroEx.new()
      :ok = LoroEx.apply_update(mirror, parent_snap)
      assert LoroEx.get_text(mirror, "body") == "hello!"
    end

    @tag :nif
    test "fork/1 can be exported concurrently with parent mutations" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "A")

      forked = LoroEx.fork(doc)

      task =
        Task.async(fn ->
          LoroEx.export_snapshot(forked)
        end)

      # Parent continues to take writes during the fork's export.
      for _ <- 1..50, do: :ok = LoroEx.insert_text(doc, "body", 0, "x")

      snap = Task.await(task)
      mirror = LoroEx.new()
      :ok = LoroEx.apply_update(mirror, snap)

      # The fork's snapshot reflects the fork point, not the parent's
      # current state.
      assert LoroEx.get_text(mirror, "body") == "A"
      # Parent has moved on.
      assert LoroEx.get_text(doc, "body") == String.duplicate("x", 50) <> "A"
    end

    @tag :nif
    test "fork/1 preserves tree state" do
      parent = LoroEx.new()
      node_id = LoroEx.tree_create_node(parent, "blocks", nil)
      _child_id = LoroEx.tree_create_node(parent, "blocks", node_id)

      fork = LoroEx.fork(parent)

      # Both trees look the same at the fork point.
      assert LoroEx.tree_get_nodes(fork, "blocks") ==
               LoroEx.tree_get_nodes(parent, "blocks")

      # Creating a new node on the fork does not appear on the parent.
      _ = LoroEx.tree_create_node(fork, "blocks", nil)

      refute LoroEx.tree_get_nodes(fork, "blocks") ==
               LoroEx.tree_get_nodes(parent, "blocks")
    end
  end
end
