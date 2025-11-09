defmodule OskolWeb.PageController do
  use OskolWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
