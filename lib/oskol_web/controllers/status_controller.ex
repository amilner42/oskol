defmodule OskolWeb.StatusController do
  @moduledoc """
  `GET /status` — is the analysis engine answering, and is it really the
  engine?

  The engine is the one part of Oskol that runs somewhere we do not control
  the power to (see the Aveline ticket `bg-analysis-imac`): a machine in a
  house, reached over a tailnet. A game still plays when it is down — only
  the review after it waits — so nothing in the product surfaces the
  difference, which leaves "is my machine up" a question you can otherwise
  only answer by finishing a game and waiting.

  This is that answer as a page you can keep open. It asks two things.

  **Is it there?** `Oskol.Reviews.health/1`, down the same road a review
  takes, so a green here means a review would reach the same engine.
  Anything that checked something adjacent would be worse than nothing.

  **Is it the engine?** A real position out of a real game, sent to it and
  answered by it, drawn with the plays it named underneath. `/health` is a
  line of Python and a stub answers it — one did, for most of an evening,
  while the engine behind it was not running (the Aveline doc
  `bgsage-gotchas`). Naming the best play of a board it has never seen is
  not something a stub does, so the board below the word is the part of
  this page that cannot be faked.

  Plain HTML, no Elm, no JSON: it has to render when the interesting
  failure is happening, which is not the moment to depend on a bundle.

  **Nothing here waits on the engine.** The health check is cached for a
  few seconds and the board for a minute, and the board is looked at in the
  background — the page serves the last one it saw and starts a fresh look
  when that is old. A page that blocked on the engine would stop rendering
  exactly when the engine is the thing that has gone wrong. The caching is
  also why an open page cannot be used to make requests: the engine is
  asked once a minute however many people are watching.
  """
  use OskolWeb, :controller

  alias Oskol.Puzzles
  alias Oskol.Reviews

  @cache_ms 5_000
  @key {__MODULE__, :last}

  @board_ms 60_000
  @board_key {__MODULE__, :board}
  @refresher __MODULE__.Refresh

  # The engine is a desktop in a house, and one 4-ply turn takes a few
  # seconds there. Nothing is waiting on this — the page was sent long
  # before the answer comes — so the timeout can be generous.
  @ask_ms 30_000

  def show(conn, _params) do
    {result, at, age} = cached()
    board = board()
    verdict = verdict(result, board)

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(code(verdict), page(verdict, at, age, board))
  end

  # One reading, out of both questions, and the word and the status code are
  # both it — a page that said UP in green while answering 503 would be
  # two readings, and the reader would believe the green one.
  #
  # An engine that answers `/health` and cannot analyse a position is not up:
  # that is the failure the board is here to catch. Having nothing drawn yet
  # is not that — it is not an answer about the engine at all, and reads as
  # whatever health said.
  defp verdict({:error, reason}, _board), do: {:down, reason}

  defp verdict({:ok, _ms}, {{:error, _reason}, _age}) do
    {:down, "answered, but did not analyse a position"}
  end

  defp verdict({:ok, ms}, _board), do: {:up, "answered in #{ms} ms"}

  # 200 when it answered, 503 when it did not, so this is watchable by
  # something other than a human reading a colour.
  defp code({:up, _}), do: 200
  defp code({:down, _}), do: 503

  # ---------- Is it there? ----------

  defp cached do
    now = System.system_time(:millisecond)

    case :persistent_term.get(@key, nil) do
      {result, at} when now - at < @cache_ms ->
        {result, at, now - at}

      _ ->
        result = Reviews.health()
        :persistent_term.put(@key, {result, now})
        {result, now, 0}
    end
  end

  # ---------- Is it the engine? ----------

  # The last board and how old it is, or `:none` before there has been one.
  # A stale board is served as it is and a fresh look started behind it;
  # nothing here blocks.
  defp board do
    now = System.system_time(:millisecond)
    stored = :persistent_term.get(@board_key, nil)

    case stored do
      {result, at} when now - at < @board_ms ->
        {result, now - at}

      _ ->
        look_again()

        case stored do
          {result, at} -> {result, now - at}
          nil -> :none
        end
    end
  end

  defp look_again do
    Task.Supervisor.start_child(Oskol.Reviews.TaskSupervisor, fn ->
      # One look at a time. The lock is a registered name rather than a flag
      # in a term because it is held by a process: a look that crashes frees
      # it, and a flag would still be set.
      if claim(@refresher) do
        refresh()
      end
    end)

    :ok
  end

  defp claim(name) do
    Process.register(self(), name)
  rescue
    ArgumentError -> false
  end

  @doc """
  Draw a fresh board and keep it: pick a position, ask the engine what it
  would play, store the answer for the page to serve.

  The page never calls this inline — `look_again/0` runs it in a task — and
  it is public so a test can take the look itself rather than race one.
  """
  def refresh do
    :persistent_term.put(@board_key, {look(), System.system_time(:millisecond)})
  end

  defp look do
    with {:ok, puzzle} <- a_position(),
         {:ok, question} <- :oskol@puzzles.question_from_json(Jason.encode!(puzzle.question)),
         {:ok, body} <- askable(question),
         {:ok, svg} <- :oskol@puzzles@picture.checked_svg(question),
         {:ok, answered} <- Reviews.ask(:oskol@status.route(), body, @ask_ms),
         {:ok, answer} <- :oskol@status.read(answered) do
      {:ok, Map.put(Jason.decode!(answer), "svg", svg)}
    else
      # Neither of these is the engine's fault, and neither is a reason to
      # read down: a site with no games yet has nothing to draw, and a row
      # the engine cannot be asked about is ours to skip.
      :none -> {:nothing, "no stored position to draw yet"}
      {:unaskable, why} -> {:nothing, why}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp askable(question) do
    case :oskol@status.request(question) do
      {:ok, body} -> {:ok, body}
      {:error, why} -> {:unaskable, why}
    end
  end

  defp a_position do
    case Puzzles.sample_move() do
      nil -> :none
      puzzle -> {:ok, puzzle}
    end
  end

  # ---------- The page ----------

  defp page({reading, detail}, at, age, board) do
    {word, colour} =
      case reading do
        :up -> {"UP", "#0E8A16"}
        :down -> {"DOWN", "#D1242F"}
      end

    checked =
      at |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")

    """
    <!doctype html>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="robots" content="noindex">
    <title>analysis: #{word}</title>
    <style>
      :root { color-scheme: light dark }
      body { margin: 0; min-height: 100vh; display: grid;
             grid-template-columns: minmax(0, 1fr); place-items: center;
             font: 16px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace }
      main { text-align: center; padding: 1.5rem; width: 100%; max-width: 34rem;
             box-sizing: border-box }
      .word { font-size: clamp(2.5rem, 12vw, 4rem); font-weight: 700;
              color: #{colour}; letter-spacing: -0.02em; line-height: 1.1 }
      .detail { opacity: 0.8 }
      .when { opacity: 0.55; font-size: 0.85em; margin-top: 1.25rem }
      .proof { margin-top: 1.75rem }
      .proof svg { display: block; width: 100%; height: auto; border-radius: 10px }
      .plays { width: 100%; margin-top: 0.85rem; border-collapse: collapse;
               font-size: 0.9em }
      .plays td { padding: 0.2rem 0; vertical-align: baseline }
      .plays .play { text-align: left }
      .plays .eq { text-align: right; opacity: 0.8; padding-left: 0.75rem }
      .plays .win { text-align: right; opacity: 0.55; padding-left: 0.75rem }
      .plays tr:first-child td { font-weight: 700; opacity: 1 }
      .took { opacity: 0.55; font-size: 0.8em; margin-top: 0.6rem }
      .pending, .quiet { opacity: 0.55; font-size: 0.85em }
      .bad { color: #D1242F; font-size: 0.85em }
    </style>
    <main>
      <div class="word">#{word}</div>
      <div class="detail">#{esc(detail)}</div>
      #{proof(board)}
      <div class="when">the analysis engine, checked #{checked}#{cache_note(age)}</div>
    </main>
    """
  end

  # The position and what the engine made of it: the part of this page a
  # stub cannot answer.
  defp proof(:none) do
    ~s{<div class="proof pending">asking the engine about a position&hellip;</div>}
  end

  defp proof({{:nothing, reason}, _age}) do
    ~s{<div class="proof quiet">#{esc(reason)}</div>}
  end

  defp proof({{:error, reason}, age}) do
    ~s{<div class="proof bad">#{esc(reason)} — #{ago(age)}</div>}
  end

  defp proof({{:ok, seen}, age}) do
    """
    <div class="proof">
      #{seen["svg"]}
      <table class="plays">#{Enum.map_join(seen["plays"], "", &play/1)}</table>
      <div class="took">#{esc(took(seen))}the engine's own answer, #{ago(age)}</div>
    </div>
    """
  end

  defp play(%{"notation" => notation, "equity" => equity, "win" => win}) do
    ~s{<tr><td class="play">#{esc(notation)}</td>} <>
      ~s{<td class="eq">#{signed(equity)}</td>} <>
      ~s{<td class="win">#{percent(win)}</td></tr>}
  end

  defp took(seen) do
    [level(seen["level"]), seconds(seen["took_ms"])]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ""
      bits -> Enum.join(bits, " · ") <> " · "
    end
  end

  defp level(name) when is_binary(name) and name != "", do: name
  defp level(_), do: nil

  defp seconds(ms) when is_integer(ms) and ms > 0 do
    :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"
  end

  defp seconds(_), do: nil

  # Equity is signed on purpose: a play worth less than nothing should look
  # it, and the best play's sign is the first thing a reader checks.
  defp signed(n) when is_number(n) do
    written = :erlang.float_to_binary(n * 1.0, decimals: 3)
    if n >= 0, do: "+" <> written, else: written
  end

  defp signed(_), do: ""

  defp percent(n) when is_number(n) and n > 0 do
    :erlang.float_to_binary(n * 100.0, decimals: 1) <> "%"
  end

  defp percent(_), do: ""

  defp ago(age) when age < 1_000, do: "just now"
  defp ago(age), do: "#{div(age, 1000)}s ago"

  defp esc(text), do: Plug.HTML.html_escape(text)

  defp cache_note(0), do: ""
  defp cache_note(age), do: " (cached #{div(age, 1000)}s)"
end
