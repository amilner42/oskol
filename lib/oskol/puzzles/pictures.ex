defmodule Oskol.Puzzles.Pictures do
  @moduledoc """
  A puzzle's picture: the board drawn once, for the link preview.

  The drawing is Gleam's (`src/oskol/puzzles/picture.gleam`: the stored
  question in, an SVG out, the site's default colours). This is the IO
  around it -- rasterising the SVG with `rsvg-convert` and keeping the PNG
  in `puzzle_images` -- and the bookkeeping that keeps it bounded.

  **Never on a request.** A picture is drawn in the review job right after
  the game's puzzles are stored (`render_game/2`, behind the `puzzles.pictures`
  cap), and by the queue's minute sweep for whatever that missed
  (`render_owed/1`, one batch a minute). `GET /puzzles/:id.png` serves the
  row or the site's default picture; it draws nothing, so a stranger with a
  link cannot make the server work.

  **Bounded, and never silent.** Every try is charged to `attempts` before
  the render, a failure is logged, and the try that spends the last of
  three writes `error` and leaves the row out of the sweep until an
  operator reopens it (`reset_attempts/0`). One exception, on purpose: a
  missing `rsvg-convert` is the machine's fault, not the puzzle's, so it is
  logged and charged to nobody -- a deploy without the binary must not burn
  every puzzle's budget and leave them pictureless after the fix.

  The binary is `config :oskol, :rsvg` (`path`, `timeout_ms`); tests point
  it at a stub. The SVG goes in on stdin and the PNG comes out on stdout,
  with no file in between.
  """

  import Ecto.Query
  require Logger

  alias Oskol.Puzzles.{Image, Puzzle, Source}
  alias Oskol.Repo

  @max_attempts 3
  @width 1200
  @height 630
  # A single argument or environment string on Linux is 128 KB at most,
  # and a board is a tenth of that. Anything bigger is a bug, not a board.
  @max_svg 100_000
  @png_signature <<0x89, "PNG\r\n", 0x1A, "\n">>

  # The site's own picture, drawn once by the same renderer and committed
  # (`write_default!/1` regenerates it), so serving it needs neither the
  # binary nor a render at boot.
  @default_path Path.expand("../../../priv/static/images/puzzle-board.png", __DIR__)
  @external_resource @default_path
  @default_png File.read!(@default_path)

  # ---------- Reading ----------

  @doc "The stored PNG, or `:none` when it has not been drawn."
  def png(puzzle_id) when is_binary(puzzle_id) do
    case Repo.one(from(i in Image, where: i.puzzle_id == ^puzzle_id, select: i.png)) do
      nil -> :none
      png -> {:ok, png}
    end
  end

  @doc "Whether a puzzle with this id exists at all."
  def exists?(puzzle_id) when is_binary(puzzle_id) do
    Repo.exists?(from(p in Puzzle, where: p.id == ^puzzle_id))
  end

  @doc "The opening position in the site's colours: what a puzzle without a picture is shown as."
  def default_png, do: @default_png

  # ---------- Drawing ----------

  @doc """
  Draw one puzzle's picture and store it. `:ok`, or `{:error, reason}`
  with the try charged and logged -- unless the binary itself is missing,
  which charges nothing (see the module doc).

  `opts`: `rsvg:` the binary to run, `timeout:` in ms; both default to the
  config.
  """
  def render(puzzle_id, opts \\ []) when is_binary(puzzle_id) do
    case Repo.one(from(p in Puzzle, where: p.id == ^puzzle_id, select: p.question)) do
      nil ->
        {:error, "no such puzzle"}

      question ->
        case binary(opts) do
          {:error, reason} ->
            Logger.warning("puzzle picture #{puzzle_id} not drawn: #{reason}")
            {:error, reason}

          {:ok, exe} ->
            attempts = charge(puzzle_id)

            with {:ok, svg} <- svg(question),
                 {:ok, png} <- rasterise(svg, exe, opts) do
              store(puzzle_id, png)
              :ok
            else
              {:error, reason} ->
                gave_up(puzzle_id, reason, attempts)
                {:error, reason}
            end
        end
    end
  end

  @doc """
  Draw the pictures of the puzzles one game just wrote -- the ones with no
  picture yet and tries to spare. Called from the review job once `store`
  has succeeded for that game. Returns how many were drawn.
  """
  def render_game(game_id, game_number) when is_binary(game_id) and is_integer(game_number) do
    from(s in Source,
      where: s.game_id == ^game_id and s.game_number == ^game_number,
      where: not is_nil(s.puzzle_id),
      select: s.puzzle_id,
      distinct: true
    )
    |> Repo.all()
    |> Enum.filter(&owed?/1)
    |> render_each()
  end

  @doc """
  The sweep's batch: the newest puzzles with no picture and tries to
  spare, at most `limit` of them, drawn now. Returns how many were drawn.
  """
  def render_owed(limit \\ 20) when is_integer(limit) do
    owed_query() |> limit(^limit) |> Repo.all() |> render_each()
  end

  @doc "Whether any puzzle is still owed a picture. The sweep asks before queueing a job."
  def any_owed? do
    Repo.exists?(owed_query())
  end

  @doc """
  Let the rows that gave up be tried again: an operator has fixed whatever
  `error` was complaining about. Returns how many were reopened.
  """
  def reset_attempts do
    {count, _} =
      from(i in Image, where: is_nil(i.png), where: i.attempts >= @max_attempts)
      |> Repo.update_all(set: [attempts: 0, error: nil])

    count
  end

  @doc """
  Write the site's default picture to `path`: the opening position through
  the same renderer and the same binary. Run once, and again whenever the
  renderer changes what a board looks like:

      mix run -e 'Oskol.Puzzles.Pictures.write_default!()'
  """
  def write_default!(path \\ @default_path) do
    {:ok, exe} = binary([])
    {:ok, png} = rasterise(:oskol@puzzles@picture.default_svg(), exe, [])
    File.write!(path, png)
    byte_size(png)
  end

  @invite_path Path.expand("../../../priv/static/images/invite-board.png", __DIR__)

  @doc """
  The picture an invite link unfurls with (`priv/static/images/invite-board.png`):
  the opening position with the invitation's words, from the same renderer.
  Run once, and again whenever the renderer or the words change:

      mix run -e 'Oskol.Puzzles.Pictures.write_invite!()'
  """
  def write_invite!(path \\ @invite_path) do
    {:ok, exe} = binary([])
    {:ok, png} = rasterise(:oskol@puzzles@picture.invite_svg(), exe, [])
    File.write!(path, png)
    byte_size(png)
  end

  # ---------- The pieces ----------

  @doc "The SVG of a stored question (a `puzzles.question` map), for measuring and tooling."
  def svg(question) when is_map(question) do
    with {:ok, q} <- :oskol@puzzles.question_from_json(Jason.encode!(question)) do
      :oskol@puzzles@picture.checked_svg(q)
    end
  end

  @doc """
  Run the binary on an SVG: stdin to stdout, killed after the timeout.
  `{:ok, png}` only when it exited 0 and what came back is a PNG.
  """
  def rasterise(svg, exe, opts) when is_binary(svg) and is_binary(exe) do
    timeout = opts[:timeout] || config()[:timeout_ms] || 10_000

    if byte_size(svg) > @max_svg do
      {:error, "svg is #{byte_size(svg)} bytes, over the #{@max_svg} the shell can carry"}
    else
      # A port cannot close stdin without closing stdout, so the SVG rides
      # in as an environment string and a one-line shell pipes it. `%s`
      # prints it as it is.
      task =
        Task.async(fn ->
          System.cmd(
            "sh",
            [
              "-c",
              ~S(printf '%s' "$OSKOL_SVG" | exec "$OSKOL_RSVG" -w "$OSKOL_W" -h "$OSKOL_H" -f png)
            ],
            env: [
              {"OSKOL_SVG", svg},
              {"OSKOL_RSVG", exe},
              {"OSKOL_W", Integer.to_string(@width)},
              {"OSKOL_H", Integer.to_string(@height)}
            ]
          )
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {<<@png_signature, _::binary>> = png, 0}} -> {:ok, png}
        {:ok, {_out, 0}} -> {:error, "rsvg-convert exited 0 without a PNG"}
        {:ok, {_out, code}} -> {:error, "rsvg-convert exited #{code}"}
        {:exit, reason} -> {:error, "rsvg-convert crashed: #{inspect(reason)}"}
        nil -> {:error, "rsvg-convert took longer than #{timeout} ms"}
      end
    end
  end

  # The binary to run, resolved on the PATH or as given. `{:error, _}` when
  # there is none: the one failure that is not the puzzle's.
  defp binary(opts) do
    path = opts[:rsvg] || config()[:path] || "rsvg-convert"

    case System.find_executable(path) do
      nil -> {:error, "#{path} is not installed"}
      exe -> {:ok, exe}
    end
  end

  defp config, do: Application.get_env(:oskol, :rsvg, [])

  # A batch asks for the binary once: without it nothing can be drawn, and
  # one line says so rather than one per puzzle.
  defp render_each([]), do: 0

  defp render_each(ids) do
    case binary([]) do
      {:ok, exe} ->
        Enum.count(ids, fn id -> render(id, rsvg: exe) == :ok end)

      {:error, reason} ->
        Logger.warning("#{length(ids)} puzzle pictures not drawn: #{reason}")
        0
    end
  end

  defp owed?(puzzle_id) do
    Repo.exists?(from(p in Puzzle, where: p.id == ^puzzle_id) |> without_picture())
  end

  # Puzzles with no picture and tries to spare, newest first: a row never
  # tried, or one tried fewer than three times.
  defp owed_query do
    from(p in Puzzle, order_by: [desc: p.inserted_at], select: p.id) |> without_picture()
  end

  defp without_picture(query) do
    from(p in query,
      left_join: i in Image,
      on: i.puzzle_id == p.id,
      where: is_nil(i.png),
      where: is_nil(i.attempts) or i.attempts < @max_attempts
    )
  end

  # ---------- Bookkeeping ----------

  # Charged before the render, so a render that always dies still leaves
  # the sweep after three. Returns the count after this try.
  defp charge(puzzle_id) do
    now = DateTime.utc_now()

    {1, [%{attempts: attempts}]} =
      Repo.insert_all(
        Image,
        [%{puzzle_id: puzzle_id, attempts: 1, inserted_at: now, updated_at: now}],
        on_conflict: [inc: [attempts: 1], set: [updated_at: now]],
        conflict_target: :puzzle_id,
        returning: [:attempts]
      )

    attempts
  end

  defp store(puzzle_id, png) do
    now = DateTime.utc_now()

    from(i in Image, where: i.puzzle_id == ^puzzle_id)
    |> Repo.update_all(set: [png: png, rendered_at: now, error: nil, updated_at: now])
  end

  defp gave_up(puzzle_id, reason, attempts) do
    Logger.error(
      "puzzle picture #{puzzle_id} failed (attempt #{attempts}/#{@max_attempts}): #{reason}"
    )

    if attempts >= @max_attempts do
      Logger.error("puzzle picture #{puzzle_id} given up: #{reason}")

      from(i in Image, where: i.puzzle_id == ^puzzle_id)
      |> Repo.update_all(set: [error: String.slice(reason, 0, 500)])
    end

    :ok
  end
end
