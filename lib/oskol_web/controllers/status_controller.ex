defmodule OskolWeb.StatusController do
  @moduledoc """
  `GET /status` — is the analysis engine answering?

  The engine is the one part of Oskol that runs somewhere we do not control
  the power to (see the Aveline ticket `bg-analysis-imac`): a machine in a
  house, reached over a tailnet. A game still plays when it is down — only
  the review after it waits — so nothing in the product surfaces the
  difference, which leaves "is my machine up" a question you can otherwise
  only answer by finishing a game and waiting.

  This is that answer as a page you can keep open. It asks along the road a
  review takes, `Oskol.Reviews.health/1`, so a green here means a review
  would reach the same engine; anything that checks something adjacent would
  be worse than nothing.

  Plain HTML, no Elm, no JSON: it has to render when the interesting failure
  is happening, which is not the moment to depend on a bundle.

  Answers are cached for a few seconds. The page is open to anyone, and an
  open page that makes an outbound request per hit is a page that can be
  used to make requests.
  """
  use OskolWeb, :controller

  alias Oskol.Reviews

  @cache_ms 5_000
  @key {__MODULE__, :last}

  def show(conn, _params) do
    {result, at, age} = cached()

    conn
    |> put_resp_content_type("text/html")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status_code(result), page(result, at, age))
  end

  # 200 when it answered, 503 when it did not, so this is watchable by
  # something other than a human reading a colour.
  defp status_code({:ok, _}), do: 200
  defp status_code({:error, _}), do: 503

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

  defp page(result, at, age) do
    {word, detail, colour} =
      case result do
        {:ok, ms} -> {"UP", "answered in #{ms} ms", "#0E8A16"}
        {:error, reason} -> {"DOWN", reason, "#D1242F"}
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
      body { margin: 0; min-height: 100vh; display: grid; place-items: center;
             font: 16px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace }
      main { text-align: center; padding: 1.5rem }
      .word { font-size: clamp(3rem, 18vw, 6rem); font-weight: 700;
              color: #{colour}; letter-spacing: -0.02em }
      .detail { opacity: 0.8 }
      .when { opacity: 0.55; font-size: 0.85em; margin-top: 1.25rem }
    </style>
    <main>
      <div class="word">#{word}</div>
      <div class="detail">#{Plug.HTML.html_escape(detail)}</div>
      <div class="when">the analysis engine, checked #{checked}#{cache_note(age)}</div>
    </main>
    """
  end

  defp cache_note(0), do: ""
  defp cache_note(age), do: " (cached #{div(age, 1000)}s)"
end
