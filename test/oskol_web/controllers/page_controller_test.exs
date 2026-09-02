defmodule OskolWeb.PageControllerTest do
  use OskolWeb.ConnCase

  test "GET / renders the game library", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "Games for two"
    assert html =~ "Tilt"
  end
end
