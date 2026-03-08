defmodule SymphonyElixir.Linear.Issue do
  @moduledoc """
  Compatibility wrapper for the generic tracker issue type.
  """

  alias SymphonyElixir.Tracker.Issue

  @type t :: Issue.t()

  @spec label_names(t()) :: [String.t()]
  defdelegate label_names(issue), to: Issue
end
