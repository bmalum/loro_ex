defmodule LoroEx.Generators do
  @moduledoc false
  # StreamData generators for property-based testing of LoroEx.
  #
  # Operations are intentionally constrained to a small, finite domain:
  # a fixed set of container names, bounded positions and lengths, and
  # a curated subset of mutation kinds. This keeps shrinking tractable
  # — when a property fails, StreamData can shrink to a 3-op sequence
  # rather than something pathological.
  #
  # Tree ops are deliberately excluded for now: TreeID flow makes the
  # state-tracking generator significantly more complex, and the four
  # ops covered here exercise enough of the merge logic to catch
  # convergence regressions in practice.

  use ExUnitProperties

  @text_containers ~w(body title)
  @map_containers ~w(settings metadata)
  @list_containers ~w(events log)

  @doc """
  Generate a single operation. Each op is a tuple that
  `LoroEx.Generators.apply_op/2` can interpret against any doc.
  """
  def op do
    one_of([
      insert_text_op(),
      delete_text_op(),
      map_set_op(),
      list_push_op()
    ])
  end

  @doc "Generate a list of `1..max` operations."
  def op_sequence(max \\ 25) when is_integer(max) and max >= 1 do
    list_of(op(), min_length: 1, max_length: max)
  end

  defp insert_text_op do
    tuple({
      constant(:insert_text),
      member_of(@text_containers),
      integer(0..32),
      string(:alphanumeric, min_length: 1, max_length: 8)
    })
  end

  defp delete_text_op do
    tuple({
      constant(:delete_text),
      member_of(@text_containers),
      integer(0..32),
      integer(1..8)
    })
  end

  defp map_set_op do
    tuple({
      constant(:map_set),
      member_of(@map_containers),
      member_of(~w(theme size locale)),
      one_of([
        constant(~s("dark")),
        constant(~s("light")),
        constant("12"),
        constant("true"),
        constant("null")
      ])
    })
  end

  defp list_push_op do
    tuple({
      constant(:list_push),
      member_of(@list_containers),
      one_of([
        constant(~s("login")),
        constant(~s("edit")),
        constant("42")
      ])
    })
  end

  @doc """
  Apply a single op to a doc. Errors from out-of-bounds inputs (a
  text container shorter than the requested position, a delete past
  the end, etc.) are swallowed because they're not what we're
  testing — convergence assertions only need each peer to apply the
  *same* op or skip it for the *same* reason.
  """
  def apply_op(doc, {:insert_text, container, pos, value}) do
    _ = LoroEx.insert_text(doc, container, pos, value)
    :ok
  end

  def apply_op(doc, {:delete_text, container, pos, len}) do
    _ = LoroEx.delete_text(doc, container, pos, len)
    :ok
  end

  def apply_op(doc, {:map_set, container, key, value_json}) do
    _ = LoroEx.map_set(doc, container, key, value_json)
    :ok
  end

  def apply_op(doc, {:list_push, container, value_json}) do
    _ = LoroEx.list_push(doc, container, value_json)
    :ok
  end
end
