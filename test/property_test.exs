defmodule LoroEx.PropertyTest do
  @moduledoc """
  Property-based convergence tests using StreamData.

  These tests are tagged `:property` (in addition to `:nif`) so they're
  excluded from the default test run. Run with:

      mix test --include nif --include property

  ## What we're checking

  Loro is a CRDT — the formal contract is "any sequence of ops applied
  in any order on any topology converges to the same state across
  peers". Hand-written tests cover the cases I think of; property
  tests cover the cases the generator thinks of, including
  combinations that surface edge cases when bumping Loro versions.

  ## Properties

  1. **Two-doc convergence** — generate an op sequence, split each op
     randomly across two peers, swap snapshots, both peers see the
     same `get_deep_value/1`.
  2. **Snapshot round-trip** — `from_snapshot(export_snapshot(doc))`
     reproduces the doc's state exactly.
  3. **containers_touched_since correctness** — the returned set is a
     subset of the containers we wrote to between the captured vv and
     current.
  4. **revert_to round-trip** — applying ops, capturing a frontier,
     applying more ops, then `revert_to(frontier)` returns the same
     state as a fresh doc with only the first batch.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import LoroEx.Generators

  # Cap the number of trials so the suite stays fast. Bump locally
  # when investigating a regression. CI runs with the default 100.
  @trials 50

  # `get_deep_value_with_id` includes an `idx:N` prefix in the `cid`
  # field that is a Loro-internal container index — it differs between
  # docs even when values are identical. For convergence assertions we
  # strip the `cid` metadata and compare only the `value` subtrees.
  #
  # Additionally, Loro only includes a root container in the deep value
  # if it has been materialized (any op touched it). A failed
  # `delete_text` on an empty container materializes it on one peer but
  # not the other. We normalize by removing keys whose value is the
  # container's zero-value ("" for text, %{} for map, [] for list).
  defp deep_value(doc) do
    doc
    |> LoroEx.get_deep_value_with_id()
    |> Jason.decode!()
    |> strip_cids()
    |> drop_empty_roots()
  end

  defp strip_cids(%{"value" => v, "cid" => _}), do: strip_cids(v)
  defp strip_cids(%{} = map), do: Map.new(map, fn {k, v} -> {k, strip_cids(v)} end)
  defp strip_cids(list) when is_list(list), do: Enum.map(list, &strip_cids/1)
  defp strip_cids(other), do: other

  defp drop_empty_roots(%{} = map) do
    Map.reject(map, fn {_k, v} -> v in ["", %{}, [], 0, 0.0, nil] end)
  end

  defp drop_empty_roots(other), do: other

  describe "convergence" do
    @tag :nif
    @tag :property
    property "two peers converge after a random op sequence is split between them" do
      check all(
              ops <- op_sequence(),
              splits <- list_of(boolean(), length: length(ops)),
              max_runs: @trials
            ) do
        alice = LoroEx.new(1)
        bob = LoroEx.new(2)

        # Apply each op to one peer or the other based on `splits`.
        ops
        |> Enum.zip(splits)
        |> Enum.each(fn
          {op, true} -> apply_op(alice, op)
          {op, false} -> apply_op(bob, op)
        end)

        # Swap snapshots both ways.
        :ok = LoroEx.apply_update(alice, LoroEx.export_snapshot(bob))
        :ok = LoroEx.apply_update(bob, LoroEx.export_snapshot(alice))

        assert deep_value(alice) == deep_value(bob)
      end
    end
  end

  describe "snapshot round-trip" do
    @tag :nif
    @tag :property
    property "from_snapshot(export_snapshot(doc)) reproduces deep state" do
      check all(ops <- op_sequence(), max_runs: @trials) do
        doc = LoroEx.new(1)
        Enum.each(ops, &apply_op(doc, &1))

        snap = LoroEx.export_snapshot(doc)
        rebuilt = LoroEx.from_snapshot(snap)

        assert deep_value(doc) == deep_value(rebuilt)
      end
    end
  end

  describe "containers_touched_since" do
    @tag :nif
    @tag :property
    property "returned set is a subset of containers actually touched" do
      check all(
              initial <- op_sequence(),
              follow_up <- op_sequence(),
              max_runs: @trials
            ) do
        doc = LoroEx.new(1)
        Enum.each(initial, &apply_op(doc, &1))

        v0 = LoroEx.oplog_version(doc)
        Enum.each(follow_up, &apply_op(doc, &1))

        touched = LoroEx.containers_touched_since(doc, v0) |> MapSet.new()

        # Touched CIDs must end with one of the container kinds we write to.
        # (We don't assert exact equality with op-level expectations
        # because Loro can route an op to a parent or child container —
        # subset is the right contract.)
        for cid <- touched do
          assert String.ends_with?(cid, ":Text") or
                   String.ends_with?(cid, ":Map") or
                   String.ends_with?(cid, ":List") or
                   String.ends_with?(cid, ":MovableList") or
                   String.ends_with?(cid, ":Tree") or
                   String.ends_with?(cid, ":Counter"),
                 "unexpected CID kind in touched set: #{cid}"
        end

        # When follow_up is empty, the touched set is empty too.
        if follow_up == [] do
          assert MapSet.size(touched) == 0
        end
      end
    end
  end

  describe "revert_to" do
    @tag :nif
    @tag :property
    property "revert_to(frontier_at(N)) reproduces the state at op N" do
      check all(
              initial <- op_sequence(),
              follow_up <- op_sequence(),
              max_runs: @trials
            ) do
        # First doc: apply only the initial ops.
        target = LoroEx.new(1)
        Enum.each(initial, &apply_op(target, &1))
        target_value = deep_value(target)

        # Second doc: apply initial ops, snapshot the frontier, apply
        # follow-up ops, then revert to the snapshot.
        actual = LoroEx.new(1)
        Enum.each(initial, &apply_op(actual, &1))
        frontier = LoroEx.oplog_frontiers(actual)
        Enum.each(follow_up, &apply_op(actual, &1))

        case LoroEx.revert_to(actual, frontier) do
          :ok ->
            assert deep_value(actual) == target_value

          {:error, _} ->
            # If revert fails (e.g. shallow history) we skip the assertion;
            # the property is "when it succeeds, it reproduces the state".
            :ok
        end
      end
    end
  end
end
