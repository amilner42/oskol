defmodule OskolWeb.NotFoundError do
  @moduledoc "Raised for a path that names no game; renders as a 404."
  defexception message: "not found", plug_status: 404
end
