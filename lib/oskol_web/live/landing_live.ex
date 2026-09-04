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
        player_id: nil,
        server_state: nil,
        disconnected_players: [],
        page_title: nil
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
                  player_id: nil,
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

  # Decide which step of the game page to show from `?game=` and `?name=`.
  defp route_game(socket, params) do
    game_name = params["game"] || ""
    name_from_url = params["name"]

    socket =
      if game_name != "" && !name_from_url do
        set_invite_meta_tags(socket, game_name)
      else
        socket
      end

    cond do
      game_name == "" ->
        assign(socket, step: :create, game_name: "")

      socket.assigns.step in [:joining, :waiting] and socket.assigns.game_name == game_name ->
        socket

      connected?(socket) && name_from_url && name_from_url != "" ->
        auto_rejoin(socket, game_name, name_from_url)

      connected?(socket) ->
        check_game_for_reconnect(socket, game_name)

      true ->
        assign(socket, step: :player_name, game_name: game_name)
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

  # A player came back with their name in the URL: reconnect them, or seat
  # them if the game has not started and there is room.
  defp auto_rejoin(socket, game_name, player_name) do
    case Game.lookup_game(game_name) do
      {:ok, _pid} ->
        Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_name}")

        case Game.rejoin_game(game_name, player_name, self()) do
          {:ok, player_id, new_state} ->
            if new_state.instance != nil do
              push_navigate(socket, to: play_path(socket, game_name, player_name))
            else
              enter_waiting(socket, game_name, player_name, player_id, new_state)
            end

          {:error, _reason} ->
            server_state = Game.get_server_state(game_name)

            if server_state.instance == nil do
              case Game.join_game(game_name, player_name, self()) do
                {:ok, player_id, new_state} ->
                  after_join(socket, game_name, player_name, player_id, new_state)

                {:error, _} ->
                  assign(socket, step: :player_name, game_name: game_name)
              end
            else
              assign(socket,
                step: :player_name,
                game_name: game_name,
                error: "That game already started"
              )
            end
        end

      :not_found ->
        assign(socket, step: :player_name, game_name: game_name)
    end
  end

  defp check_game_for_reconnect(socket, game_name) do
    case Game.lookup_game(game_name) do
      {:ok, _pid} ->
        server_state = Game.get_server_state(game_name)

        disconnected =
          server_state.connections
          |> Enum.filter(fn {_id, conn} -> not conn.connected end)
          |> Enum.map(fn {id, conn} -> {id, conn.name} end)

        inviter =
          server_state.connections
          |> Enum.find(fn {_id, c} -> c.connected end)
          |> case do
            {_id, c} -> c.name
            nil -> nil
          end

        if disconnected != [] and server_state.instance != nil do
          assign(socket,
            step: :joining,
            game_name: game_name,
            server_state: server_state,
            disconnected_players: disconnected
          )
        else
          assign(socket,
            step: :player_name,
            game_name: game_name,
            inviter_name: inviter,
            server_state: server_state,
            disconnected_players: disconnected
          )
        end

      :not_found ->
        assign(socket, step: :player_name, game_name: game_name)
    end
  end

  defp enter_waiting(socket, game_name, player_name, player_id, server_state) do
    assign(socket,
      step: :waiting,
      game_name: game_name,
      player_name: player_name,
      player_id: player_id,
      server_state: server_state,
      error: nil
    )
  end

  # After seating a player: straight into the game if it started, else wait.
  defp after_join(socket, game_name, player_name, player_id, server_state) do
    if server_state.instance != nil do
      push_navigate(socket, to: play_path(socket, game_name, player_name))
    else
      socket
      |> enter_waiting(game_name, player_name, player_id, server_state)
      |> push_patch(to: lobby_path(socket, game_name, player_name))
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
        game_id = generate_game_id()
        {:ok, _pid} = Game.find_or_start_game(game_id, socket.assigns.slug)
        Phoenix.PubSub.subscribe(Oskol.PubSub, "game:#{game_id}")

        with {:ok, _} <- Game.configure(game_id, socket.assigns.setup),
             {:ok, player_id, new_state} <- Game.join_game(game_id, player_name, self()) do
          {:noreply, after_join(socket, game_id, player_name, player_id, new_state)}
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

      disconnected =
        server_state.connections
        |> Enum.filter(fn {_id, conn} -> not conn.connected end)
        |> Enum.map(fn {id, conn} -> {id, conn.name} end)

      socket =
        assign(socket,
          player_name: player_name,
          server_state: server_state,
          disconnected_players: disconnected
        )

      case Game.join_game(game_id, player_name, self()) do
        {:ok, player_id, new_state} ->
          {:noreply, after_join(socket, game_id, player_name, player_id, new_state)}

        {:error, :name_taken} ->
          case Game.rejoin_game(game_id, player_name, self()) do
            {:ok, player_id, new_state} ->
              {:noreply, after_join(socket, game_id, player_name, player_id, new_state)}

            {:error, _reason} ->
              {:noreply, assign(socket, step: :joining, error: "That name is already taken")}
          end

        {:error, :game_full} ->
          {:noreply, assign(socket, step: :joining, error: nil)}

        {:error, :game_already_started} ->
          {:noreply, assign(socket, step: :joining, error: "That game already started")}

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

  def handle_event("rejoin_as_player", %{"player_name" => name}, socket) do
    game_id = socket.assigns.game_name

    case Game.rejoin_game(game_id, name, self()) do
      {:ok, player_id, new_state} ->
        {:noreply, after_join(socket, game_id, name, player_id, new_state)}

      {:error, reason} ->
        {:noreply, assign(socket, error: format_error(reason))}
    end
  end

  @impl true
  def handle_info({:game_state_updated, new_state, _events}, socket) do
    if new_state.instance != nil and socket.assigns.player_name != "" do
      {:noreply,
       push_navigate(socket,
         to: play_path(socket, socket.assigns.game_name, socket.assigns.player_name)
       )}
    else
      disconnected =
        new_state.connections
        |> Enum.filter(fn {_id, conn} -> not conn.connected end)
        |> Enum.map(fn {id, conn} -> {id, conn.name} end)

      {:noreply, assign(socket, server_state: new_state, disconnected_players: disconnected)}
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

  defp lobby_path(socket, game_id, player_name) do
    ~p"/#{socket.assigns.slug}?game=#{game_id}&name=#{player_name}"
  end

  defp play_path(socket, game_id, player_name) do
    ~p"/#{socket.assigns.slug}/#{game_id}?name=#{player_name}"
  end

  defp generate_game_id do
    :crypto.strong_rand_bytes(6)
    |> Base.url_encode64(padding: false)
    |> String.replace(~r/[^a-zA-Z0-9]/, "")
    |> String.slice(0, 6)
    |> String.downcase()
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
  defp format_error(reason) when is_atom(reason), do: "Error: #{reason}"
  defp format_error(reason), do: "Error: #{inspect(reason)}"

  # ============================================================================
  # RENDER
  # ============================================================================

  @impl true
  def render(assigns) do
    ~H"""
    <div class="paper min-h-screen-safe flex flex-col">
      <.topbar page={@page} />
      <main class="flex-1 w-full max-w-5xl mx-auto px-4 sm:px-6 pb-16">
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
            server_state={@server_state}
            disconnected_players={@disconnected_players}
            player_id={@player_id}
            player_name={@player_name}
            clock_presets={@clock_presets}
          />
        <% end %>
      </main>
      <footer
        class="pixel text-[9px] sm:text-[10px] text-center pb-6 px-4"
        style="color: var(--pencil)"
      >
        NO ACCOUNTS · A GAME STAYS OPEN FOR AN HOUR AFTER THE LAST MOVE
      </footer>
    </div>
    """
  end

  # ---------- Shell ----------

  attr :page, :atom, required: true

  defp topbar(assigns) do
    ~H"""
    <header class="w-full max-w-5xl mx-auto px-4 sm:px-6 pt-5 pb-2 flex items-center justify-between">
      <.link patch={~p"/"} class="flex items-center gap-1.5 pixel" aria-label="Oskol home">
        <span class="mark-letter">O</span>
        <span class="mark-letter red">S</span>
        <span class="mark-letter">K</span>
        <span class="mark-letter red">O</span>
        <span class="mark-letter">L</span>
      </.link>
      <span class="pixel text-[9px] sm:text-[10px]" style="color: var(--pencil)">
        <%= if @page == :library do %>
          2 PLAYERS · NO SIGNUP
        <% else %>
          <.link patch={~p"/"} class="hover:text-[color:var(--pen)]">◀ ALL GAMES</.link>
        <% end %>
      </span>
    </header>
    """
  end

  # ---------- Library ----------

  attr :games, :list, required: true

  defp library(assigns) do
    ~H"""
    <section class="pt-8 sm:pt-14 pb-8 text-center">
      <p class="pixel text-[10px] sm:text-xs blink" style="color: var(--red)">▶ INSERT COIN ◀</p>
      <h1 class="pixel mt-4 text-2xl sm:text-4xl leading-relaxed" style="color: var(--ink)">
        SEND A LINK.<br />
        <span class="hl px-1">PLAY IN SECONDS.</span>
      </h1>
      <p class="mt-5 text-base sm:text-lg max-w-xl mx-auto" style="color: var(--pencil)">
        The classics, two players, nothing to install and no signup. Pick a cabinet, share the invite, and your opponent is in.
      </p>
    </section>

    <p class="pixel text-[10px] sm:text-xs mb-3 text-center" style="color: var(--ink)">
      SELECT YOUR GAME
    </p>
    <section id="game-library" class="grid gap-6 sm:gap-8 sm:grid-cols-2">
      <.cabinet :for={game <- @games} game={game} />
    </section>

    <section class="mt-14 grid gap-4 sm:grid-cols-3">
      <.step n="1" title="PICK A GAME">Choose a mode, the settings and an optional clock.</.step>
      <.step n="2" title="SHARE THE INVITE">Your opponent opens it and types a name.</.step>
      <.step n="3" title="PLAY">The game starts the moment they join.</.step>
    </section>
    """
  end

  attr :game, :map, required: true

  defp cabinet(assigns) do
    assigns =
      assign(assigns,
        accent: GameArt.accent(assigns.game["slug"]),
        format_names: assigns.game["formats"] |> Enum.map(& &1["name"])
      )

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
      <div class="screen px-6 py-5 sm:py-6 flex items-center justify-center">
        <GameArt.art slug={@game["slug"]} class="h-32 sm:h-40 w-auto" />
      </div>
      <div class="px-4 sm:px-5 py-4">
        <p class="font-semibold text-base sm:text-lg" style="color: var(--ink)">{@game["tagline"]}</p>
        <p class="mt-1 text-sm leading-relaxed" style="color: var(--pencil)">
          {@game["description"]}
        </p>
        <div class="mt-3 flex flex-wrap gap-1.5">
          <.chip :for={name <- @format_names}>{name}</.chip>
          <.chip>Optional clock</.chip>
        </div>
        <div class="mt-4 flex items-center justify-between">
          <span class="pixel text-[9px]" style="color: var(--pencil)">1P VS 2P</span>
          <span class="btn-arcade pixel text-[10px] px-4 py-2.5 rounded-full">PLAY</span>
        </div>
      </div>
    </.link>
    """
  end

  attr :n, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp step(assigns) do
    ~H"""
    <div class="pix-sm p-4 flex gap-3 items-start">
      <span
        class="pixel text-[10px] shrink-0 w-8 h-8 grid place-items-center"
        style="background: var(--highlighter); border: 2px solid var(--ink)"
      >
        {@n}
      </span>
      <div>
        <div class="pixel text-[10px]" style="color: var(--ink)">{@title}</div>
        <div class="text-sm mt-1.5" style="color: var(--pencil)">{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  slot :inner_block, required: true

  defp chip(assigns) do
    ~H"""
    <span
      class="text-[11px] font-semibold uppercase tracking-wide px-2 py-0.5"
      style="border: 2px solid var(--ink); background: var(--paper-2); color: var(--ink)"
    >
      {render_slot(@inner_block)}
    </span>
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
  attr :server_state, :any, default: nil
  attr :disconnected_players, :list, default: []
  attr :player_id, :string, default: nil
  attr :player_name, :string, default: ""
  attr :clock_presets, :list, default: []

  defp game_page(assigns) do
    assigns = assign(assigns, accent: GameArt.accent(assigns.slug))

    ~H"""
    <section
      class="cabinet pix mt-4 sm:mt-8"
      style={"--accent: #{@accent}; transform: none;"}
      id={"game-hero-#{@slug}"}
    >
      <div class="marquee pixel text-sm sm:text-base px-5 py-3 uppercase" id="game-title">
        {@info["name"]}
      </div>
      <div class="screen grid sm:grid-cols-[auto_1fr] gap-4 sm:gap-8 items-center px-5 sm:px-8 py-5 sm:py-6">
        <GameArt.art slug={@slug} class="h-28 sm:h-36 w-auto mx-auto" />
        <div class="text-center sm:text-left">
          <p class="pixel text-[10px]" style="color: var(--accent)">
            {String.upcase(@info["tagline"])}
          </p>
          <h1 class="mt-2 text-xl sm:text-2xl font-black leading-snug" style="color: var(--ink)">
            {@copy.title}
          </h1>
          <p class="mt-2 leading-relaxed" style="color: var(--pencil)">{@copy.intro}</p>
        </div>
      </div>
    </section>

    <section class="mt-8 sm:mt-10">
      <div class="pix p-5 sm:p-8">
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
            <.join_form inviter_name={@inviter_name} server_state={@server_state} />
          <% :joining -> %>
            <.joining
              server_state={@server_state}
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
    <section class="mt-12 grid gap-4 sm:grid-cols-3" id="how-it-works">
      <.step
        :for={{line, i} <- Enum.with_index(@copy.how, 1)}
        n={Integer.to_string(i)}
        title={step_title(i)}
      >
        {line}
      </.step>
    </section>

    <section class="mt-12 pix p-5 sm:p-8" id="rules">
      <h2 class="pixel text-[10px] sm:text-xs mb-4" style="color: var(--ink)">
        {String.upcase(@info["name"])} IN BRIEF
      </h2>
      <div class="space-y-3 leading-relaxed" style="color: var(--ink)">
        <p :for={paragraph <- @copy.rules}>{paragraph}</p>
      </div>
    </section>

    <section class="mt-8 grid gap-4 sm:grid-cols-2" id="modes">
      <div class="pix-sm p-5">
        <h2 class="pixel text-[10px] mb-3" style="color: var(--ink)">MODES</h2>
        <ul class="space-y-2">
          <li :for={format <- @info["formats"]}>
            <span class="font-bold" style="color: var(--ink)">{format["name"]}</span>
            <span class="text-sm" style="color: var(--pencil)">· {format["description"]}</span>
          </li>
        </ul>
      </div>
      <div class="pix-sm p-5">
        <h2 class="pixel text-[10px] mb-3" style="color: var(--ink)">CLOCKS</h2>
        <ul class="space-y-2">
          <li :for={preset <- @clocks}>
            <span class="font-bold" style="color: var(--ink)">{preset["name"]}</span>
            <span class="text-sm" style="color: var(--pencil)">· {preset["description"]}</span>
          </li>
        </ul>
      </div>
    </section>

    <section :if={@copy.faq != []} class="mt-8 pix p-5 sm:p-8" id="faq">
      <h2 class="pixel text-[10px] sm:text-xs mb-4" style="color: var(--ink)">QUESTIONS</h2>
      <dl class="space-y-4">
        <div :for={{question, answer} <- @copy.faq}>
          <dt class="font-bold" style="color: var(--ink)">{question}</dt>
          <dd class="mt-1 leading-relaxed" style="color: var(--pencil)">{answer}</dd>
        </div>
      </dl>
    </section>

    <section :if={@others != []} class="mt-10 text-center" id="other-games">
      <p class="pixel text-[10px] mb-3" style="color: var(--pencil)">ALSO ON OSKOL</p>
      <div class="flex flex-wrap justify-center gap-3">
        <.link
          :for={game <- @others}
          patch={~p"/#{game["slug"]}"}
          class="pix-flat px-4 py-2 font-bold hover:bg-[color:var(--highlighter)]"
          style="color: var(--ink)"
        >
          {game["name"]} →
        </.link>
      </div>
    </section>
    """
  end

  defp step_title(1), do: "PICK A MODE"
  defp step_title(2), do: "SET A CLOCK"
  defp step_title(_), do: "SHARE THE LINK"

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
    <form phx-submit="new_game" class="space-y-7">
      <div>
        <p class="pixel text-[10px] mb-3" style="color: var(--pen)">PLAYER 1 · YOUR NAME</p>
        <.name_input placeholder="e.g. Alice" />
      </div>

      <div>
        <h3 class="pixel text-[10px] mb-2" style="color: var(--ink)">GAME MODE</h3>
        <div class={["grid gap-3", format_grid_class(length(@formats))]}>
          <.format_tile
            :for={format <- @formats}
            format={format}
            selected={@setup.format == format["id"]}
          />
        </div>
      </div>

      <div id="twist">
        <div class="flex items-baseline justify-between mb-2">
          <h3 class="pixel text-[10px]" style="color: var(--ink)">TWIST</h3>
          <span class="text-xs" style="color: var(--pencil)">rules that throw the book out</span>
        </div>
        <div class="flex flex-wrap gap-2">
          <%= if @twist do %>
            <.choice_chip
              :for={choice <- @twist["choices"]}
              setting={@twist}
              choice={choice}
              selected={Map.get(@setup.selections, "twist", @twist["default"]) == choice["id"]}
            />
          <% else %>
            <span class="tile tile-mine px-3.5 py-1.5 text-sm font-semibold" style="color: var(--ink)">
              Original rules
            </span>
            <span class="text-xs self-center" style="color: var(--pencil)">
              more twists on the way
            </span>
          <% end %>
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
        <div class="flex items-baseline justify-between mb-2">
          <h3 class="pixel text-[10px]" style="color: var(--ink)">TIME CONTROL</h3>
          <span class="text-xs" style="color: var(--pencil)">optional</span>
        </div>
        <div class="flex flex-wrap gap-2" id="clock-picker">
          <.clock_chip
            :for={preset <- @clocks}
            preset={preset}
            selected={@setup.clock == preset["id"]}
          />
        </div>
      </div>

      <div class="text-center space-y-3">
        <.cta type="submit" id="create-game" color="green">START ▶</.cta>
        <p class="text-sm" style="color: var(--pencil)">
          You'll get an invite link. Your opponent types a name and the game starts.
        </p>
      </div>
    </form>
    """
  end

  attr :inviter_name, :string, default: nil
  attr :server_state, :any, default: nil

  defp join_form(assigns) do
    summary =
      if assigns.server_state, do: GameServerState.summary(assigns.server_state), else: nil

    assigns = assign(assigns, summary: summary)

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

  attr :server_state, :any, default: nil
  attr :disconnected_players, :list, default: []
  attr :game_name, :string, required: true

  defp joining(assigns) do
    in_progress = assigns.server_state && assigns.server_state.instance != nil

    max_players =
      if assigns.server_state,
        do: GameServerState.max_players(assigns.server_state),
        else: 2

    count = if assigns.server_state, do: map_size(assigns.server_state.connections), else: 0
    assigns = assign(assigns, can_join: not in_progress and count < max_players)

    ~H"""
    <div class="space-y-4">
      <%= if @disconnected_players != [] do %>
        <p class="pixel text-[10px]" style="color: var(--pen)">CONTINUE? RECONNECT AS</p>
        <div class="grid gap-3 sm:grid-cols-2">
          <button
            :for={{_id, name} <- @disconnected_players}
            phx-click="rejoin_as_player"
            phx-value-player_name={name}
            class="btn-arcade yellow pixel text-[10px] px-4 py-3"
          >
            {name}
          </button>
        </div>
        <%= if @can_join do %>
          <p class="text-sm pt-2" style="color: var(--pencil)">Or join as a new player:</p>
          <form
            phx-submit="submit_player_name"
            class="grid gap-3 sm:grid-cols-[1fr_auto] items-center"
          >
            <.name_input placeholder="Your name" />
            <.cta type="submit">JOIN GAME</.cta>
          </form>
        <% end %>
      <% else %>
        <p class="pixel text-[10px]" style="color: var(--red)">GAME FULL</p>
        <.link patch={~p"/"} class="inline-block font-semibold" style="color: var(--pen)">
          Start your own →
        </.link>
      <% end %>
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
      </div>

      <p class="text-center text-sm" style="color: var(--pencil)">
        Waiting for your opponent to open the link… the game starts the moment they join.
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
      class={["tile text-left px-4 py-3", @selected and "tile-mine"]}
    >
      <div class="flex items-center justify-between gap-2">
        <span class="font-bold" style="color: var(--ink)">{@format["name"]}</span>
        <span :if={@selected} class="pixel text-[8px] text-player">1P</span>
      </div>
      <div class="text-xs mt-0.5" style="color: var(--pencil)">{@format["description"]}</div>
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
      class={["tile px-3.5 py-1.5 text-sm font-semibold", @selected and "tile-mine"]}
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
      class={["tile px-3.5 py-1.5 text-sm font-semibold", @selected and "tile-mine"]}
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
