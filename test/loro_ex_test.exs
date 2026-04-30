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
end
