defmodule OskolWeb.Plugs.PuzzlePictureTest do
  @moduledoc """
  `GET /puzzles/:id.png`: the stored picture with a year's cache, the
  site's default board with a short one while a puzzle has none, a 404 for
  an id that names no puzzle, and nothing drawn by any of them.
  """
  use OskolWeb.ConnCase, async: false

  alias Oskol.Puzzles
  alias Oskol.Puzzles.Pictures
  alias Oskol.Repo

  @png_signature <<0x89, "PNG\r\n", 0x1A, "\n">>

  setup do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  defp a_puzzle do
    id = :crypto.strong_rand_bytes(5) |> Base.encode32(padding: false) |> binary_part(0, 8)
    now = DateTime.utc_now()

    Repo.insert!(%Puzzles.Puzzle{
      id: id,
      key: "k-" <> id,
      kind: "move",
      question: %{
        "kind" => "move",
        "board" => [
          0,
          -2,
          0,
          0,
          0,
          0,
          5,
          0,
          3,
          0,
          0,
          0,
          -5,
          5,
          0,
          0,
          0,
          -3,
          0,
          -5,
          0,
          0,
          0,
          0,
          2,
          0
        ],
        "dice" => [3, 1],
        "cube" => %{"value" => 1, "owner" => "center"},
        "score" => nil,
        "crawford" => false,
        "jacoby" => false
      },
      answer: %{"kind" => "move", "complete" => true, "outcomes" => []},
      inserted_at: now,
      updated_at: now
    })

    id
  end

  defp a_drawn_puzzle do
    id = a_puzzle()
    :ok = Pictures.render(id)
    id
  end

  test "a drawn puzzle's picture is served as an immutable PNG with an ETag", %{conn: conn} do
    id = a_drawn_puzzle()
    {:ok, png} = Pictures.png(id)

    conn = get(conn, "/puzzles/#{id}.png")

    assert conn.status == 200
    # A bare image type: no charset on bytes.
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert [etag] = get_resp_header(conn, "etag")
    assert conn.resp_body == png
    assert <<@png_signature, _::binary>> = conn.resp_body

    # Nothing of the browser pipeline ran: no guest cookie was minted.
    assert conn.resp_cookies == %{}

    # The same bytes again are a 304.
    again = build_conn() |> put_req_header("if-none-match", etag) |> get("/puzzles/#{id}.png")
    assert again.status == 304
    assert again.resp_body == ""
  end

  test "a puzzle with no picture yet is served the site's board, briefly cached", %{conn: conn} do
    id = a_puzzle()

    conn = get(conn, "/puzzles/#{id}.png")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=300"]
    assert conn.resp_body == Pictures.default_png()
    assert <<@png_signature, _::binary>> = conn.resp_body
    # And serving it drew nothing: no attempt was spent.
    assert Repo.get(Puzzles.Image, id) == nil
  end

  test "the story token in the query string changes nothing", %{conn: conn} do
    id = a_drawn_puzzle()
    plain = get(conn, "/puzzles/#{id}.png")
    story = get(build_conn(), "/puzzles/#{id}.png?s=abc123")
    assert story.status == 200
    assert story.resp_body == plain.resp_body
    assert get_resp_header(story, "etag") == get_resp_header(plain, "etag")
  end

  test "an id that names no puzzle is a 404", %{conn: conn} do
    conn = get(conn, "/puzzles/nothere1.png")
    assert conn.status == 404
    refute response_content_type(conn, :text) =~ "png"
  end

  test "the puzzle page itself is not an image", %{conn: conn} do
    # Without the suffix the plug steps aside for the router; whatever the
    # router answers, it is not this plug's PNG.
    conn = get(conn, "/puzzles/#{a_drawn_puzzle()}")
    refute get_resp_header(conn, "content-type") |> Enum.any?(&(&1 =~ "image/png"))
    assert get_resp_header(conn, "cache-control") != ["public, max-age=31536000, immutable"]
  end
end
