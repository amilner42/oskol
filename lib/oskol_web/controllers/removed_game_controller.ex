defmodule OskolWeb.RemovedGameController do
  @moduledoc """
  Oskol used to host poker, go and chess. Their old links -- a start page,
  an invite (`?game=`), a seat at a table -- lead home rather than to a 404,
  so a bookmark or a link in an old chat still lands somewhere that plays.
  """
  use OskolWeb, :controller

  def home(conn, _params), do: redirect(conn, to: ~p"/")
end
