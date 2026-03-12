defmodule SymphonyElixir.Observability.CodexMessage do
  @moduledoc """
  Shared Codex message humanization for operator-facing observability surfaces.
  """

  alias SymphonyElixir.StatusDashboard

  @spec humanize(term()) :: String.t()
  def humanize(message), do: StatusDashboard.humanize_codex_message(message)
end
