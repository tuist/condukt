defmodule Condukt.SessionStore.Memory do
  @moduledoc """
  ETS-backed session store for restoring sessions within the current VM.
  """

  @behaviour Condukt.SessionStore

  alias Condukt.SessionStore.Snapshot

  @table __MODULE__

  @impl true
  def load(opts) do
    ensure_table!()

    case :ets.lookup(@table, key(opts)) do
      [{_, %Snapshot{} = snapshot}] -> {:ok, snapshot}
      [] -> :not_found
    end
  end

  @impl true
  def save(%Snapshot{} = snapshot, opts) do
    ensure_table!()
    true = :ets.insert(@table, {key(opts), snapshot})
    :ok
  end

  @impl true
  def clear(opts) do
    ensure_table!()
    true = :ets.delete(@table, key(opts))
    :ok
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :global.trans({__MODULE__, :ensure_table}, &ensure_table_exists/0)

      tid ->
        tid
    end
  end

  defp ensure_table_exists do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
      tid -> tid
    end
  end

  defp key(opts) do
    Keyword.get_lazy(opts, :key, fn ->
      {
        Keyword.get(opts, :agent_module),
        Keyword.get(opts, :cwd),
        Keyword.get(opts, :id)
      }
    end)
  end
end
