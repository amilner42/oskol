defmodule OskolWeb.PageControllerTest do
  use OskolWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "New Game"
  end
end
