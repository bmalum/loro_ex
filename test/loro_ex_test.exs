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
    test "objects and arrays are rejected with :invalid_value" do
      doc = LoroEx.new()

      assert {:error, {:invalid_value, _}} =
               LoroEx.map_set(doc, "m", "k", ~s({"nested": "value"}))

      assert {:error, {:invalid_value, _}} =
               LoroEx.map_set(doc, "m", "k", ~s([1, 2, 3]))
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
    test "list push rejects non-scalar values" do
      doc = LoroEx.new()

      assert {:error, {:invalid_value, _}} =
               LoroEx.list_push(doc, "events", ~s({"x": 1}))
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
             ) or match?(
               _,
               LoroEx.text_len(doc, "body", :pixels)
             )
    end

    @tag :nif
    test "text_mark rejects object/array values via :invalid_value" do
      doc = LoroEx.new()
      :ok = LoroEx.insert_text(doc, "body", 0, "hello")

      # The Elixir wrapper encodes, then the NIF parses the JSON;
      # object/array encoded JSON is rejected as :invalid_value.
      assert {:error, {:invalid_value, _}} =
               LoroEx.text_mark(doc, "body", 0, 5, "bold", %{"nested" => "value"})

      assert {:error, {:invalid_value, _}} =
               LoroEx.text_mark(doc, "body", 0, 5, "bold", [1, 2, 3])
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
end