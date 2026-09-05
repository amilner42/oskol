defmodule OskolWeb.LandingLive do
  @moduledoc """
  The front door, as one LiveView so moving between the library and a game's
  start page is a patch, not a page load:

    * `/` the library: every registered game as a poster.
    * `/:slug` one game's start page. The creator picks a mode, its settings
      and a clock, types a name and gets a link. The opponent opens the link,
      types a name, and the game starts.
  """
  use OskolWeb, :live_view

  alias Oskol.Game
  alias Oskol.Game.GameServerState
  alias Oskol.GameKit
  alias OskolWeb.GameArt
  alias OskolWeb.GameCopy

  # ---------- Mount and navigation ----------

  @impl true
  def mount(params, _session, socket) do
    socket =
      assign(socket,
        games: GameKit.games(),
        clock_presets: GameKit.clock_presets(),
        page: :library,
        slug: nil,
        info: nil,
        copy: nil,
        meta_description: nil,
        canonical: nil,
        og_title: nil,
        og_description: nil,
        json_ld: nil,
        step: :create,
        setup: nil,
        game_name: "",
        player_name: "",
        error: nil,
        inviter_name: nil,
        setup_summary: nil,
        player_id: nil,
        seat_token: nil,
        server_state: nil,
        disconnected_players: [],
        page_title: nil,
        join_open: false,
        join_code: "",
        join_error: nil
      )

    case socket.assigns.live_action do
      :game ->
        case GameKit.game_info(params["slug"]) do
          {:ok, _} -> {:ok, socket}
          # A real 404 (not a redirect): crawlers and typos should not land on the library.
          :error -> raise OskolWeb.NotFoundError
        end

      _ ->
        {:ok, socket}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :library ->
        site = GameCopy.site()

        {:noreply,
         assign(socket,
           page: :library,
           slug: nil,
           info: nil,
           copy: nil,
           error: nil,
           page_title: site.title,
           meta_description: site.description,
           canonical: url(~p"/"),
           og_title: nil,
           og_description: nil,
           json_ld: library_json_ld(socket.assigns.games)
         )}

      :game ->
        slug = params["slug"]

        case GameKit.game_info(slug) do
          {:ok, info} ->
            copy = GameCopy.for_game(info)

            socket =
              if socket.assigns.slug != slug do
                # Fresh game page: reset the flow, and stop listening to a
                # room from the previous page.
                if socket.assigns.game_name not in [nil, ""] do
                  Phoenix.PubSub.unsubscribe(Oskol.PubSub, "game:#{socket.assigns.game_name}")
                end

                assign(socket,
                  page: :game,
                  slug: slug,
                  info: info,
                  copy: copy,
                  page_title: copy.title,
                  meta_description: copy.description,
                  canonical: url(~p"/#{slug}"),
                  og_title: copy.title,
                  og_description: copy.description,
                  json_ld: game_json_ld(info, copy),
                  step: :create,
                  setup: GameServerState.default_setup(info),
                  game_name: "",
                  player_name: nil,
                  error: nil,
                  inviter_name: nil,
                  setup_summary: nil,
                  player_id: nil,
                  seat_token: nil,
                  server_state: nil,
                  disconnected_players: []
                )
              else
                assign(socket, page: :game)
              end

            {:noreply, route_game(socket, params)}

          :error ->
            {:noreply, push_patch(socket, to: ~p"/")}
        end
    end
  end

  # Decide which step of the game page to show from `?game=` and `?t=`.
  #
  # `?t=` is a seat token: the only thing that attaches to a seat. Without
  # one this is the plain invite link, and what it offers depends on the
  # room (see `route_invite/2`). A name in the URL is not identity and is
  # not read here.
  defp route_game(socket, params) do
    game_name = params["game"] || ""
    token = params["t"]

    socket =
      if game_name != "" && !token do
        set_invite_meta_tags(socket, game_name)
      else
        socket
      end

    cond do
      game_name == "" ->
        assign(socket, step: :create, game_name: "", seat_token: nil)

      socket.assigns.step == :waiting and socket.assigns.game_name == game_name ->
        socket

      # Attaching claims a seat, so it waits for the live connection: the
      # static render's process is about to go away.
      is_binary(token) && token != "" ->
        if connected?(socket),
          do: attach_with_token(socket, game_name, token),
          else: assign(socket, step: :player_name, game_name: game_name)

      # Deciding what the invite offers is a read, and it runs on the static
      # render too, so a visitor never sees a join form the table has no
      # room for.
      true ->
        route_invite(socket, game_name)
    end
  end

  defp set_invite_meta_tags(socket, game_name) do
    with {:ok, _pid} <- Game.lookup_game(game_name),
         server_state <- Game.get_server_state(game_name),
         {_id, conn} <- Enum.find(server_state.connections, fn {_id, c} -> c.connected end) do
      assign(socket,
        og_title: "#{conn.name} challenged you to #{socket.assigns.info["name"]}",
        og_description: GameServerState.summary(server_state)
      )
    else
      _ -> socket
    end
  end

  # A player came back holding their seat token: attach them to that seat.
  # A token that is not current grants nothing — it falls through to the
  # plain invite, which may still offer the seat if its player is away.
  defp attach_with_token(socket, game_name, token) do
    case Game.lookup_game(game_name) do
      {:ok, _pid} ->
        Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_name}")

        case Game.attach(game_name, token, self()) do
          {:ok, player_id, new_state} ->
            seated(socket, game_name, player_id, token, new_state)

          {:error, _reason} ->
            route_invite(assign(socket, seat_token: nil), game_name)
        end

      :not_found ->
        assign(socket, step: :player_name, game_name: game_name, seat_token: nil)
    end
  end

  # The plain invite link. What it offers depends on the table:
  #
  #   * room with a free seat -> the normal join flow (type a name).
  #   * full, everyone connected -> nothing at all. No seat, no scene.
  #   * full, someone away -> offer their seat back (one name, or a choice
  #     of both when the table emptied out).
  #
  # A visitor who is not (yet) a player never gets the room struct into
  # their assigns: it holds both seats' tokens, and only the strings a view
  # actually shows have any business being here.
  defp route_invite(socket, game_name) do
    socket = assign(socket, server_state: nil)

    case Game.lookup_game(game_name) do
      {:ok, _pid} ->
        server_state = Game.get_server_state(game_name)
        disconnected = GameServerState.disconnected_seats(server_state)

        cond do
          not GameServerState.full?(server_state) ->
            assign(socket,
              step: :player_name,
              game_name: game_name,
              inviter_name: inviter_name(server_state),
              setup_summary: GameServerState.summary(server_state),
              disconnected_players: disconnected
            )

          disconnected == [] ->
            assign(socket,
              step: :table_full,
              game_name: game_name,
              disconnected_players: []
            )

          true ->
            assign(socket,
              step: :reconnect,
              game_name: game_name,
              disconnected_players: disconnected
            )
        end

      :not_found ->
        assign(socket, step: :player_name, game_name: game_name)
    end
  end

  defp inviter_name(server_state) do
    case Enum.find(server_state.connections, fn {_id, c} -> c.connected end) do
      {_id, c} -> c.name
      nil -> nil
    end
  end

  defp enter_waiting(socket, game_name, player_id, token, server_state) do
    assign(socket,
      step: :waiting,
      game_name: game_name,
      player_name: get_in(server_state.connections, [player_id, :name]) || "",
      player_id: player_id,
      seat_token: token,
      server_state: server_state,
      error: nil
    )
  end

  # A seat is ours and we hold its token: straight into the game if it has
  # started, else wait in the lobby. Either way the URL now carries the
  # token, so a refresh comes back to the same seat.
  defp seated(socket, game_name, player_id, token, server_state) do
    if server_state.instance != nil do
      socket
      |> assign(seat_token: token, player_id: player_id)
      |> push_navigate(to: play_path(socket, game_name, token))
    else
      socket
      |> enter_waiting(game_name, player_id, token, server_state)
      |> push_patch(to: lobby_path(socket, game_name, token))
    end
  end

  # ---------- Events ----------

  @impl true
  def handle_event("pick_format", %{"format" => format_id}, socket) when is_binary(format_id) do
    setup = %{socket.assigns.setup | format: format_id, selections: %{}}
    {:noreply, assign(socket, setup: setup, error: nil)}
  end

  def handle_event("pick_setting", %{"setting" => setting, "choice" => choice}, socket)
      when is_binary(setting) and is_binary(choice) do
    setup = socket.assigns.setup
    setup = %{setup | selections: Map.put(setup.selections, setting, choice)}
    {:noreply, assign(socket, setup: setup, error: nil)}
  end

  def handle_event("pick_clock", %{"clock" => clock_id}, socket) when is_binary(clock_id) do
    {:noreply, assign(socket, setup: %{socket.assigns.setup | clock: clock_id}, error: nil)}
  end

  def handle_event("new_game", %{"player_name" => player_name}, socket) do
    case clean_name(player_name) do
      {:error, message} ->
        {:noreply, assign(socket, error: message)}

      {:ok, player_name} ->
        {:ok, game_id} = Game.create_game(socket.assigns.slug)
        Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

        with {:ok, _} <- Game.configure(game_id, socket.assigns.setup),
             {:ok, player_id, new_state} <- Game.join_game(game_id, player_name, self()) do
          token = GameServerState.token_for(new_state, player_id)
          {:noreply, seated(socket, game_id, player_id, token, new_state)}
        else
          {:error, reason} -> {:noreply, assign(socket, error: format_error(reason))}
        end
    end
  end

  # Joining never creates a room: an invite to a room that is gone (idle for
  # an hour, or a restart) says so rather than quietly seating the guest as
  # the host of a fresh game with default settings.
  def handle_event("submit_player_name", %{"player_name" => player_name}, socket) do
    game_id = socket.assigns.game_name

    with {:ok, player_name} <- clean_name(player_name),
         {:ok, _pid} <- Game.lookup_game(game_id) do
      Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")
      server_state = Game.get_server_state(game_id)

      socket =
        assign(socket,
          player_name: player_name,
          setup_summary: GameServerState.summary(server_state),
          disconnected_players: GameServerState.disconnected_seats(server_state)
        )

      case Game.join_game(game_id, player_name, self()) do
        {:ok, player_id, new_state} ->
          token = GameServerState.token_for(new_state, player_id)
          {:noreply, seated(socket, game_id, player_id, token, new_state)}

        # A name is not a seat: a clash is just a clash, and the table
        # decides on its own whether there is anything else to offer.
        {:error, :name_taken} ->
          {:noreply, assign(socket, error: "That name is already taken")}

        {:error, reason} when reason in [:game_full, :game_already_started] ->
          {:noreply, route_invite(assign(socket, error: nil), game_id)}

        {:error, reason} ->
          {:noreply, assign(socket, error: format_error(reason))}
      end
    else
      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, error: message)}

      _ ->
        {:noreply,
         assign(socket,
           step: :create,
           game_name: "",
           error: "That game is over. Start a new one and send a fresh link."
         )}
    end
  end

  # Taking a seat back from the invite link. Its token is rotated first, so
  # whatever link the previous occupant of this browser had is dead and only
  # the URL we are about to hand out opens the seat.
  def handle_event("reclaim_seat", %{"player_id" => player_id}, socket) do
    game_id = socket.assigns.game_name

    Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

    case Game.claim_seat(game_id, player_id, self()) do
      {:ok, ^player_id, token, new_state} ->
        {:noreply, seated(socket, game_id, player_id, token, new_state)}

      {:error, reason} ->
        {:noreply, route_invite(assign(socket, error: format_error(reason)), game_id)}
    end
  end

  # ---------- Join by code ----------
  #
  # The top-right JOIN GAME prompt: 6 digits in, and out comes a
  # push_navigate to that room's normal invite link — the same flow a
  # shared base link takes. Nothing is duplicated here, and nothing about
  # the room is revealed beyond "a live game answers to this code".

  def handle_event("open_join", _params, socket) do
    {:noreply, assign(socket, join_open: true, join_code: "", join_error: nil)}
  end

  def handle_event("close_join", _params, socket) do
    {:noreply, assign(socket, join_open: false, join_code: "", join_error: nil)}
  end

  # Auto-submit: the moment a sixth digit lands, try the code.
  def handle_event("join_change", %{"code" => code}, socket) do
    code = clean_code(code)

    if String.length(code) == 6 do
      {:noreply, try_join(socket, code)}
    else
      {:noreply, assign(socket, join_code: code, join_error: nil)}
    end
  end

  def handle_event("join_submit", %{"code" => code}, socket) do
    code = clean_code(code)

    if String.length(code) == 6 do
      {:noreply, try_join(socket, code)}
    else
      {:noreply, assign(socket, join_code: code, join_error: "Enter the 6-digit game code")}
    end
  end

  defp clean_code(code) when is_binary(code) do
    code |> String.replace(~r/\D/, "") |> String.slice(0, 6)
  end

  defp clean_code(_), do: ""

  defp try_join(socket, code) do
    case Game.lookup_slug(code) do
      {:ok, slug} ->
        push_navigate(socket, to: ~p"/#{slug}?game=#{code}")

      :not_found ->
        assign(socket, join_code: code, join_error: "No game with that code")
    end
  end

  @impl true
  def handle_info({:game_state_updated, new_state, _events}, socket) do
    # Only a client that holds a seat token follows the room into the game.
    if new_state.instance != nil and socket.assigns.seat_token != nil do
      {:noreply,
       push_navigate(socket,
         to: play_path(socket, socket.assigns.game_name, socket.assigns.seat_token)
       )}
    else
      {:noreply,
       assign(socket,
         server_state: new_state,
         disconnected_players: GameServerState.disconnected_seats(new_state)
       )}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # Structured data for search engines: the catalog, and one game. Encoded
  # HTML-safe because it is rendered raw inside a <script> tag.
  defp library_json_ld(games) do
    json_ld(%{
      "@context" => "https://schema.org",
      "@type" => "WebSite",
      "name" => "Oskol",
      "url" => url(~p"/"),
      "description" => GameCopy.site().description,
      "hasPart" =>
        Enum.map(games, fn game ->
          %{"@type" => "VideoGame", "name" => game["name"], "url" => url(~p"/#{game["slug"]}")}
        end)
    })
  end

  defp game_json_ld(info, copy) do
    json_ld(%{
      "@context" => "https://schema.org",
      "@type" => "VideoGame",
      "name" => info["name"],
      "url" => url(~p"/#{info["slug"]}"),
      "description" => copy.description,
      "applicationCategory" => "Game",
      "operatingSystem" => "Web",
      "numberOfPlayers" => 2,
      "playMode" => "MultiPlayer",
      "isAccessibleForFree" => true,
      "offers" => %{"@type" => "Offer", "price" => "0", "priceCurrency" => "USD"}
    })
  end

  defp json_ld(data), do: Jason.encode!(data, escape: :html_safe)

  # Both carry the seat token, and nothing else identifying: it is the
  # credential this browser comes back with.
  defp lobby_path(socket, game_id, token) do
    ~p"/#{socket.assigns.slug}?game=#{game_id}&t=#{token}"
  end

  defp play_path(socket, game_id, token) do
    ~p"/#{socket.assigns.slug}/#{game_id}?t=#{token}"
  end

  @max_name_length 24

  # A display name: trimmed, bounded, printable. It goes into every payload,
  # the invite URL and the page title.
  defp clean_name(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name == "" ->
        {:error, "Pick a display name first"}

      String.length(name) > @max_name_length ->
        {:error, "Names are #{@max_name_length} characters at most"}

      String.match?(name, ~r/[\p{C}]/u) ->
        {:error, "Invalid name"}

      true ->
        {:ok, name}
    end
  end

  defp clean_name(_), do: {:error, "Invalid name"}

  defp format_error(:game_full), do: "That game is full"
  defp format_error(:name_taken), do: "That name is already taken"
  defp format_error(:invalid_name), do: "Invalid name"
  defp format_error(:unknown_format), do: "Unknown game mode"
  defp format_error(:unknown_clock), do: "Unknown time control"
  defp format_error(:unknown_setting), do: "Unknown setting"
  defp format_error(:unknown_choice), do: "Unknown choice"
  defp format_error(:game_already_started), do: "That game already started"
  defp format_error(:seat_connected), do: "That player is back at the table"
  defp format_error(:invalid_token), do: "That link is no longer valid"
  defp format_error(:player_not_found), do: "That player is not at this table"
  defp format_error(reason) when is_atom(reason), do: "Error: #{reason}"
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  # ============================================================================
  # RENDER
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="paper min-h-screen-safe flex flex-col">
      <.topbar />
      <.join_modal :if={@join_open} code={@join_code} error={@join_error} />
      <main class="flex-1 w-full max-w-5xl mx-auto px-4 sm:px-6 pb-10 sm:pb-16">
        <%= if @page == :library do %>
          <.library games={@games} />
        <% else %>
          <.game_page
            slug={@slug}
            info={@info}
            copy={@copy}
            games={@games}
            step={@step}
            setup={@setup}
            error={@error}
            game_name={@game_name}
            inviter_name={@inviter_name}
            setup_summary={@setup_summary}
            server_state={@server_state}
            disconnected_players={@disconnected_players}
            player_id={@player_id}
            player_name={@player_name}
            clock_presets={@clock_presets}
          />
        <% end %>
      </main>
      <footer
        class="pixel text-[8px] sm:text-[10px] leading-loose text-center pb-6 px-4"
        style="color: var(--pencil)"
      >
        FREE · NO ACCOUNTS · BY THE BOOK — UNTIL YOU FLIP A TWIST
      </footer>
    </div>
    """
  end

  # ---------- Shell ----------

  defp topbar(assigns) do
    ~H"""
    <header class="w-full max-w-5xl mx-auto px-4 sm:px-6 pt-4 sm:pt-5 pb-2 flex items-center justify-between gap-3">
      <.link patch={~p"/"} class="pixel inline-block" aria-label="Oskol home">
        <span
          class="pixel text-xs sm:text-sm tracking-[0.35em] px-3.5 py-2.5 inline-block"
          style="background: #fff; color: var(--ink); border: 3px solid var(--ink); box-shadow: 4px 4px 0 0 var(--ink)"
        >
          OSKOL
        </span>
      </.link>
      <button
        type="button"
        id="open-join"
        phx-click="open_join"
        class="btn-arcade yellow pixel text-[9px] sm:text-[10px] whitespace-nowrap px-3.5 py-2.5"
      >
        JOIN GAME
      </button>
    </header>
    """
  end

  # The 6-digit code prompt behind JOIN GAME. `inputmode` and `pattern` get
  # phones the number pad; a sixth digit auto-submits via `join_change`.
  attr :code, :string, required: true
  attr :error, :string, default: nil

  defp join_modal(assigns) do
    ~H"""
    <div
      id="join-modal"
      class="fixed inset-0 z-50 flex items-start justify-center px-4 pt-[16vh]"
      phx-window-keydown="close_join"
      phx-key="escape"
    >
      <div
        class="absolute inset-0"
        style="background: rgba(26, 26, 46, 0.5)"
        phx-click="close_join"
        aria-hidden="true"
      >
      </div>
      <div
        class="pix relative w-full max-w-sm p-5 sm:p-6"
        style="background: var(--paper)"
        role="dialog"
        aria-modal="true"
        aria-label="Join a game by code"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="pixel text-[10px] sm:text-xs" style="color: var(--ink)">JOIN GAME</h2>
          <button
            type="button"
            id="close-join"
            phx-click="close_join"
            aria-label="Close"
            class="pixel text-[10px] px-2 py-1 hover:text-[color:var(--red)]"
            style="color: var(--pencil)"
          >
            ✕
          </button>
        </div>
        <p class="text-sm mb-3" style="color: var(--pencil)">
          Type the 6-digit code from your friend.
        </p>
        <form phx-change="join_change" phx-submit="join_submit" class="space-y-3">
          <input
            type="text"
            id="join-code-input"
            name="code"
            value={@code}
            inputmode="numeric"
            pattern="[0-9]*"
            maxlength="6"
            autocomplete="one-time-code"
            placeholder="000000"
            class="name-field w-full px-4 py-3 text-center text-2xl font-mono tracking-[0.4em]"
            style="color: var(--ink)"
            autocorrect="off"
            spellcheck="false"
            phx-mounted={JS.focus()}
          />
          <p
            :if={@error}
            id="join-error"
            class="pixel text-[9px] leading-relaxed"
            style="color: var(--red)"
          >
            {@error}
          </p>
          <.cta type="submit" id="join-submit" color="green">JOIN ▶</.cta>
        </form>
      </div>
    </div>
    """
  end

  # ---------- Library ----------

  # Games with no engine yet. They are plain HTML on the library and nothing
  # else: no route, no sitemap entry, and deliberately absent from the
  # JSON-LD, which may only claim games you can actually play. Empty today:
  # every catalog game has an engine.
  @coming_soon []

  @doc false
  def coming_soon, do: @coming_soon

  attr :games, :list, required: true
  attr :coming_soon, :list, default: @coming_soon

  defp library(assigns) do
    ~H"""
    <section class="pt-10 sm:pt-14 pb-10 sm:pb-12 text-center">
      <h1
        class="pixel text-lg sm:text-3xl leading-[1.7] sm:leading-[1.6]"
        style="color: var(--ink)"
      >
        PLAY THE CLASSICS.<br />
        <span class="hl px-1">WITH A TWIST.</span>
      </h1>
      <p class="mt-4 text-base sm:text-lg max-w-md sm:max-w-xl mx-auto" style="color: var(--pencil)">
        Free · No sign up · No ads
      </p>
    </section>

    <section class="mb-8 sm:mb-10 grid grid-cols-3 gap-3 sm:gap-4">
      <.step n="1" title="PICK GAME">Choose a mode, the settings and an optional clock.</.step>
      <.step n="2" title="SHARE LINK">Your opponent opens it and types a name.</.step>
      <.step n="3" title="GAME ON">The game starts the moment they join.</.step>
    </section>

    <section id="game-library" class="grid gap-5 sm:gap-8 sm:grid-cols-2">
      <.cabinet :for={game <- @games} game={game} />
      <.soon_cabinet :for={game <- @coming_soon} game={game} />
    </section>
    """
  end

  attr :game, :map, required: true

  defp cabinet(assigns) do
    assigns = assign(assigns, accent: GameArt.accent(assigns.game["slug"]))

    ~H"""
    <.link
      patch={~p"/#{@game["slug"]}"}
      id={"game-#{@game["slug"]}"}
      class="cabinet pix block"
      style={"--accent: #{@accent}"}
    >
      <div class="marquee pixel text-xs sm:text-sm px-4 py-3 flex items-center justify-between">
        <span class="uppercase">{@game["name"]}</span>
        <span class="cursor">▶</span>
      </div>
      <div class="screen px-3 py-3 sm:px-4 sm:py-4 flex items-center justify-center">
        <GameArt.art slug={@game["slug"]} class="h-40 sm:h-56" />
      </div>
    </.link>
    """
  end

  # The same anatomy as a playable cabinet, but it is not a link and its
  # button is disabled: nothing here navigates or dead-clicks.
  attr :game, :map, required: true

  defp soon_cabinet(assigns) do
    assigns = assign(assigns, accent: GameArt.accent(assigns.game["slug"]))

    ~H"""
    <article
      id={"game-#{@game["slug"]}"}
      class="cabinet cabinet-soon pix block"
      style={"--accent: #{@accent}"}
    >
      <div class="marquee pixel text-xs sm:text-sm px-4 py-3 flex items-center justify-between">
        <span class="uppercase">{@game["name"]}</span>
        <span class="text-[9px] opacity-80">SOON</span>
      </div>
      <div class="screen px-3 py-3 sm:px-4 sm:py-4 flex items-center justify-center">
        <GameArt.art slug={@game["slug"]} class="h-40 sm:h-56" />
      </div>
    </article>
    """
  end

  attr :n, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp step(assigns) do
    ~H"""
    <div class="pix-sm p-3 sm:p-4 flex gap-2.5 sm:gap-3 items-center sm:items-start">
      <span
        class="pixel text-xs sm:text-sm shrink-0 w-8 h-8 sm:w-9 sm:h-9 grid place-items-center"
        style="background: var(--highlighter); color: var(--ink)"
      >
        {@n}
      </span>
      <div class="min-w-0">
        <div class="pixel text-[8px] sm:text-[10px] leading-relaxed" style="color: var(--ink)">
          <span :for={word <- String.split(@title)} class="block">{word}</span>
        </div>
        <div class="hidden sm:block text-sm mt-1.5" style="color: var(--pencil)">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  # ---------- Game page ----------

  attr :slug, :string, required: true
  attr :info, :map, required: true
  attr :copy, :map, required: true
  attr :games, :list, default: []
  attr :step, :atom, required: true
  attr :setup, :map, default: nil
  attr :error, :string, default: nil
  attr :game_name, :string, default: ""
  attr :inviter_name, :string, default: nil
  attr :setup_summary, :string, default: nil
  attr :server_state, :any, default: nil
  attr :disconnected_players, :list, default: []
  attr :player_id, :string, default: nil
  attr :player_name, :string, default: ""
  attr :clock_presets, :list, default: []

  defp game_page(assigns) do
    assigns = assign(assigns, accent: GameArt.accent(assigns.slug))

    ~H"""
    <section
      class="cabinet pix mt-3 sm:mt-6"
      style={"--accent: #{@accent}; transform: none;"}
      id={"game-hero-#{@slug}"}
    >
      <div class="marquee pixel text-xs sm:text-base px-4 sm:px-5 py-3 uppercase" id="game-title">
        {@info["name"]}
      </div>
      <div class="flex items-center gap-3 sm:gap-6 px-4 sm:px-6 py-3.5 sm:py-5">
        <!-- Still here: this page's job is the form below it, not a loop to watch. -->
        <GameArt.art slug={@slug} animate={false} class="h-14 sm:h-24 shrink-0" />
        <div class="min-w-0">
          <h1 class="text-lg sm:text-2xl font-black leading-snug" style="color: var(--ink)">
            {@copy.title}
          </h1>
          <p class="mt-1.5 text-sm sm:text-base leading-relaxed" style="color: var(--pencil)">
            {@copy.intro}
          </p>
        </div>
      </div>
    </section>

    <section class="mt-4 sm:mt-6">
      <div class="pix p-4 sm:p-8">
        <p
          :if={@error}
          id="form-error"
          class="mb-4 text-sm font-semibold px-4 py-3"
          style="border: 2px solid var(--red); color: var(--red); background: #fff3f2"
        >
          {@error}
        </p>
        <%= case @step do %>
          <% :create -> %>
            <.create_form info={@info} setup={@setup} clock_presets={@clock_presets} />
          <% :player_name -> %>
            <.join_form inviter_name={@inviter_name} summary={@setup_summary} />
          <% :table_full -> %>
            <.table_full game_name={@game_name} />
          <% :reconnect -> %>
            <.reconnect
              disconnected_players={@disconnected_players}
              game_name={@game_name}
            />
          <% :waiting -> %>
            <.waiting
              slug={@slug}
              game_name={@game_name}
              player_id={@player_id}
              server_state={@server_state}
            />
        <% end %>
      </div>
    </section>

    <.about :if={@step == :create} info={@info} copy={@copy} games={@games} slug={@slug} />
    """
  end

  # The part of a game's page that is for reading: how it works, the rules
  # in brief, the modes and clocks on offer, a few questions, and the way to
  # the other games.
  attr :info, :map, required: true
  attr :copy, :map, required: true
  attr :games, :list, required: true
  attr :slug, :string, required: true

  defp about(assigns) do
    presets = GameKit.clock_presets()

    clocks =
      for id <- Map.get(assigns.info, "clocks", []),
          preset = Enum.find(presets, &(&1["id"] == id)),
          do: preset

    assigns =
      assign(assigns,
        clocks: clocks,
        others: Enum.reject(assigns.games, &(&1["slug"] == assigns.slug))
      )

    ~H"""
    <section class="mt-8 sm:mt-12 pix p-4 sm:p-8" id="rules">
      <h2 class="pixel text-[10px] sm:text-xs mb-3 sm:mb-4 leading-loose" style="color: var(--ink)">
        {String.upcase(@info["name"])} IN BRIEF
      </h2>
      <div class="space-y-3 text-sm sm:text-base leading-relaxed" style="color: var(--ink)">
        <p :for={paragraph <- @copy.rules}>{paragraph}</p>
      </div>
    </section>

    <section class="mt-5 sm:mt-8 grid gap-4 sm:grid-cols-2" id="modes">
      <div class="pix-sm p-4 sm:p-5">
        <h2 class="pixel text-[10px] mb-3 leading-loose" style="color: var(--ink)">MODES</h2>
        <ul class="space-y-2 text-sm sm:text-base">
          <li :for={format <- @info["formats"]}>
            <span class="font-bold" style="color: var(--ink)">{format["name"]}</span>
            <span class="text-sm" style="color: var(--pencil)">· {format["description"]}</span>
          </li>
        </ul>
      </div>
      <div class="pix-sm p-4 sm:p-5">
        <h2 class="pixel text-[10px] mb-3 leading-loose" style="color: var(--ink)">CLOCKS</h2>
        <ul class="space-y-2 text-sm sm:text-base">
          <li :for={preset <- @clocks}>
            <span class="font-bold" style="color: var(--ink)">{preset["name"]}</span>
            <span class="text-sm" style="color: var(--pencil)">· {preset["description"]}</span>
          </li>
        </ul>
      </div>
    </section>

    <section :if={@copy.faq != []} class="mt-5 sm:mt-8 pix p-4 sm:p-8" id="faq">
      <h2 class="pixel text-[10px] sm:text-xs mb-3 sm:mb-4 leading-loose" style="color: var(--ink)">
        QUESTIONS
      </h2>
      <dl class="space-y-4 text-sm sm:text-base">
        <div :for={{question, answer} <- @copy.faq}>
          <dt class="font-bold" style="color: var(--ink)">{question}</dt>
          <dd class="mt-1 leading-relaxed" style="color: var(--pencil)">{answer}</dd>
        </div>
      </dl>
    </section>

    <section :if={@others != []} class="mt-8 sm:mt-10 text-center" id="other-games">
      <div class="flex flex-wrap justify-center gap-3">
        <.link
          :for={game <- @others}
          patch={~p"/#{game["slug"]}"}
          class="pix-flat px-4 py-3 font-bold hover:bg-[color:var(--highlighter)]"
          style="color: var(--ink)"
        >
          Play {game["name"]} →
        </.link>
      </div>
    </section>
    """
  end

  attr :info, :map, required: true
  attr :setup, :map, required: true
  attr :clock_presets, :list, required: true

  defp create_form(assigns) do
    formats = Map.get(assigns.info, "formats", [])
    format = Enum.find(formats, &(&1["id"] == assigns.setup.format)) || List.first(formats)
    offered = Map.get(assigns.info, "clocks", [])

    settings = (format && format["settings"]) || []

    assigns =
      assign(assigns,
        formats: formats,
        # A setting called "twist" gets its own heading; the rest follow
        twist: Enum.find(settings, &(&1["id"] == "twist")),
        settings: Enum.reject(settings, &(&1["id"] == "twist")),
        clocks: Enum.filter(assigns.clock_presets, &(&1["id"] in offered))
      )

    ~H"""
    <form phx-submit="new_game" class="space-y-4 sm:space-y-6">
      <div>
        <h3 class="pixel text-[10px] mb-2" style="color: var(--pen)">YOUR NAME</h3>
        <.name_input placeholder="e.g. Alice" />
      </div>

      <div>
        <h3 class="pixel text-[10px] mb-2" style="color: var(--ink)">MODE</h3>
        <div class={["grid gap-2 sm:gap-3", format_grid_class(length(@formats))]}>
          <.format_tile
            :for={format <- @formats}
            format={format}
            selected={@setup.format == format["id"]}
          />
        </div>
      </div>

      <div :if={@twist} id="twist">
        <h3 class="pixel text-[10px] mb-2" style="color: var(--ink)">TWIST</h3>
        <div class="flex flex-wrap gap-2">
          <.choice_chip
            :for={choice <- @twist["choices"]}
            setting={@twist}
            choice={choice}
            selected={Map.get(@setup.selections, "twist", @twist["default"]) == choice["id"]}
          />
        </div>
      </div>

      <div :for={setting <- @settings} id={"setting-#{setting["id"]}"}>
        <h3 class="pixel text-[10px] mb-2" style="color: var(--ink)">
          {String.upcase(setting["name"])}
        </h3>
        <div class="flex flex-wrap gap-2">
          <.choice_chip
            :for={choice <- setting["choices"]}
            setting={setting}
            choice={choice}
            selected={Map.get(@setup.selections, setting["id"], setting["default"]) == choice["id"]}
          />
        </div>
      </div>

      <div>
        <h3 class="pixel text-[10px] mb-2" style="color: var(--ink)">CLOCK</h3>
        <div class="flex flex-wrap gap-2" id="clock-picker">
          <.clock_chip
            :for={preset <- @clocks}
            preset={preset}
            selected={@setup.clock == preset["id"]}
          />
        </div>
      </div>

      <div class="text-center space-y-2 pt-0.5">
        <.cta type="submit" id="create-game" color="green">START ▶</.cta>
        <p class="text-sm" style="color: var(--pencil)">
          You get a link to send. The game starts when your friend opens it.
        </p>
      </div>
    </form>
    """
  end

  attr :inviter_name, :string, default: nil
  attr :summary, :string, default: nil

  defp join_form(assigns) do
    ~H"""
    <p :if={@inviter_name} class="mb-1 text-lg">
      <span class="text-opponent font-bold">{@inviter_name}</span> challenged you.
    </p>
    <p :if={@summary} id="setup-summary" class="mb-3 text-sm font-semibold" style="color: var(--ink)">
      {@summary}
    </p>
    <p class="pixel text-[10px] mb-3" style="color: var(--red)">PLAYER 2 · ENTER YOUR NAME</p>
    <form phx-submit="submit_player_name" class="grid gap-3 sm:grid-cols-[1fr_auto] items-center">
      <.name_input placeholder="e.g. Bob" />
      <.cta type="submit" id="join-game">JOIN GAME</.cta>
      <p class="sm:col-span-2 text-sm" style="color: var(--pencil)">
        The game starts as soon as you join.
      </p>
    </form>
    """
  end

  # Both players are at the table and neither has gone anywhere. There is
  # nothing to offer a third visitor: no seat, and no view of the game.
  attr :game_name, :string, required: true

  defp table_full(assigns) do
    ~H"""
    <div class="space-y-4" id="table-full">
      <p class="pixel text-[10px]" style="color: var(--red)">TABLE FULL</p>
      <p class="text-base" style="color: var(--ink)">
        Both players are at this table and connected. If one of them is you,
        open the link you were given when you sat down.
      </p>
      <.link patch={~p"/"} class="inline-block font-semibold" style="color: var(--pen)">
        Start your own →
      </.link>
      <p class="pixel text-[9px]" style="color: var(--pencil)">
        GAME CODE {String.upcase(@game_name)}
      </p>
    </div>
    """
  end

  # A seat at a full table is free because its player is away. Offer it
  # back: one name to confirm, or both when the table emptied out and we
  # cannot tell which of them this is.
  attr :disconnected_players, :list, default: []
  attr :game_name, :string, required: true

  defp reconnect(assigns) do
    ~H"""
    <div class="space-y-4" id="reconnect">
      <p class="pixel text-[10px]" style="color: var(--pen)">
        {if length(@disconnected_players) == 1, do: "CONTINUE?", else: "WHO ARE YOU?"}
      </p>
      <p :if={length(@disconnected_players) == 1} class="text-base" style="color: var(--ink)">
        Rejoin as <span class="font-bold">{@disconnected_players |> List.first() |> elem(1)}</span>?
      </p>
      <div class="grid gap-3 sm:grid-cols-2">
        <button
          :for={{id, name} <- @disconnected_players}
          phx-click="reclaim_seat"
          phx-value-player_id={id}
          id={"reclaim-#{id}"}
          class="btn-arcade yellow pixel text-[10px] px-4 py-3"
        >
          {name}
        </button>
      </div>
      <p class="pixel text-[9px]" style="color: var(--pencil)">
        GAME CODE {String.upcase(@game_name)}
      </p>
    </div>
    """
  end

  attr :slug, :string, required: true
  attr :game_name, :string, required: true
  attr :player_id, :string, required: true
  attr :server_state, :any, required: true

  defp waiting(assigns) do
    state = assigns.server_state
    me = state.connections[assigns.player_id]

    opponent =
      state.connections
      |> Enum.find(fn {id, _} -> id != assigns.player_id end)
      |> case do
        {_id, conn} -> conn.name
        nil -> nil
      end

    assigns =
      assign(assigns,
        me: me,
        opponent: opponent,
        summary: GameServerState.summary(state),
        invite_url: url(~p"/#{assigns.slug}?game=#{assigns.game_name}")
      )

    ~H"""
    <div class="space-y-7">
      <div class="flex items-center justify-center gap-4 sm:gap-8">
        <div class="text-center min-w-[7rem]">
          <p class="pixel text-[9px] mb-1" style="color: var(--pen)">1P</p>
          <p class="text-player text-xl sm:text-2xl font-black truncate">
            {(@me && @me.name) || "You"}
          </p>
        </div>
        <span class="pixel text-[10px]" style="color: var(--pencil)">VS</span>
        <div class="text-center min-w-[7rem]">
          <p class="pixel text-[9px] mb-1" style="color: var(--red)">2P</p>
          <%= if @opponent do %>
            <p class="text-opponent text-xl sm:text-2xl font-black truncate">{@opponent}</p>
          <% else %>
            <p class="text-xl sm:text-2xl font-black blink" style="color: var(--pencil)">?</p>
          <% end %>
        </div>
      </div>

      <p id="setup-summary" class="text-center font-semibold" style="color: var(--ink)">
        {@summary}
      </p>

      <div class="pix-sm p-4 text-center" style="background: var(--paper-2)">
        <p class="pixel text-[10px] mb-2" style="color: var(--ink)">INVITE PLAYER 2</p>
        <.invite_box url={@invite_url} />
        <div class="mt-3 pt-3" style="border-top: 2px dashed var(--pencil)">
          <p class="pixel text-[9px] mb-1" style="color: var(--pencil)">OR THEY CAN JOIN WITH CODE</p>
          <p id="game-code" class="pixel text-xl sm:text-2xl tracking-[0.3em]" style="color: var(--ink)">
            {@game_name}
          </p>
        </div>
      </div>

      <p class="text-center text-sm" style="color: var(--pencil)">
        Waiting for your opponent to open the link or enter the code… the game starts the moment
        they join.
      </p>
    </div>
    """
  end

  attr :format, :map, required: true
  attr :selected, :boolean, default: false

  defp format_tile(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="pick_format"
      phx-value-format={@format["id"]}
      id={"format-#{@format["id"]}"}
      class={["tile text-left px-3 sm:px-4 py-3", @selected and "tile-mine"]}
    >
      <div class="font-bold leading-snug" style="color: var(--ink)">{@format["name"]}</div>
      <div class="text-[11px] sm:text-xs mt-0.5 leading-tight" style="color: var(--pencil)">
        {@format["description"]}
      </div>
    </button>
    """
  end

  attr :setting, :map, required: true
  attr :choice, :map, required: true
  attr :selected, :boolean, default: false

  defp choice_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="pick_setting"
      phx-value-setting={@setting["id"]}
      phx-value-choice={@choice["id"]}
      id={"choice-#{@setting["id"]}-#{@choice["id"]}"}
      class={["tile px-3.5 py-2.5 text-sm font-semibold", @selected and "tile-mine"]}
      style="color: var(--ink)"
    >
      {@choice["name"]}
    </button>
    """
  end

  attr :preset, :map, required: true
  attr :selected, :boolean, default: false

  defp clock_chip(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="pick_clock"
      phx-value-clock={@preset["id"]}
      id={"clock-#{@preset["id"]}"}
      title={@preset["description"]}
      class={["tile px-3.5 py-2.5 text-sm font-semibold", @selected and "tile-mine"]}
      style="color: var(--ink)"
    >
      {@preset["name"]}
    </button>
    """
  end

  attr :url, :string, required: true
  attr :compact, :boolean, default: false

  defp invite_box(assigns) do
    ~H"""
    <button
      type="button"
      id={if @compact, do: "invite-button-compact", else: "invite-button"}
      phx-hook="Share"
      data-url={@url}
      class={[
        "inline-flex items-center gap-2 max-w-full",
        @compact && "text-xs font-semibold hover:underline",
        !@compact && "pix-flat px-3 py-2 text-sm hover:bg-[color:var(--highlighter)]"
      ]}
      style="color: var(--ink)"
    >
      <span class="hero-link w-4 h-4 shrink-0"></span>
      <span :if={!@compact} id="share-link" class="truncate font-mono">{@url}</span>
      <span data-label class="pixel text-[9px] whitespace-nowrap">
        {if @compact, do: "COPY INVITE LINK", else: "COPY"}
      </span>
    </button>
    """
  end

  # ---------- Primitives ----------

  attr :placeholder, :string, default: ""

  defp name_input(assigns) do
    ~H"""
    <input
      type="text"
      name="player_name"
      placeholder={@placeholder}
      maxlength="24"
      class="name-field w-full px-4 py-3 text-lg"
      style="color: var(--ink)"
      autocomplete="off"
      autocorrect="off"
      autocapitalize="words"
      spellcheck="false"
      data-1p-ignore="true"
      data-lpignore="true"
      phx-mounted={JS.focus()}
    />
    """
  end

  attr :type, :string, default: "button"
  attr :disabled, :boolean, default: false
  attr :color, :string, default: "red"
  attr :rest, :global, include: ~w(phx-click id)
  slot :inner_block, required: true

  defp cta(assigns) do
    ~H"""
    <button
      type={@type}
      disabled={@disabled}
      class={[
        "btn-arcade pixel text-[11px] sm:text-xs w-full sm:w-auto sm:min-w-[12rem] px-6 py-4",
        @color
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # Static class names so Tailwind can find them.
  defp format_grid_class(1), do: "grid-cols-1"
  defp format_grid_class(2), do: "grid-cols-2"
  defp format_grid_class(3), do: "grid-cols-1 sm:grid-cols-3"
  defp format_grid_class(4), do: "grid-cols-2 sm:grid-cols-4"
  defp format_grid_class(_), do: "grid-cols-2 sm:grid-cols-3"
end
