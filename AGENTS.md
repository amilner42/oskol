# Agent instructions

## Team knowledge lives in Aveline

Product docs, tickets, briefs and runbooks for Oskol live in the `oskol` Aveline workspace, not in this repo. Read and write them through the `aveline` CLI (`aveline --help` lists every operation).

Start every session by running:

```
aveline -w oskol get-orientation
```

That doc explains how the workspace organizes its knowledge and the work loop (ticket, branch, PR, review, CI, merge, deploy, worklog). Read it before touching any doc. Run `aveline contract` before your first doc write: it shows every block type and edit op with a valid example.

New docs are born private and new views land in your personal bucket. Publish deliberately: pass `--visibility workspace` on create-doc (or run `set-doc-visibility` after) for anything the team should see, and `--bucket team` on create-view for shared views.

To make `oskol` the default workspace so the `-w` flag is unnecessary, run `aveline use-workspace oskol` once.

## Phoenix project guidelines

This is a web application written using the Phoenix web framework.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any pending issues
- Use the already included and available `:req` (`Req`) library for HTTP requests, **avoid** `:httpoison`, `:tesla`, and `:httpc`. Req is included by default and is the preferred HTTP client for Phoenix apps

### Phoenix v1.8 guidelines

- Oskol is a controller-served Elm SPA. It currently has no LiveViews and no
  server-rendered application layout.
- `OskolWeb.Layouts` owns only the root document shell and its `head_title/1`
  helper. The generated `Layouts.app/1`, flash components and theme toggle
  were intentionally removed because nothing rendered them.
- There is no generated `CoreComponents` module. Do not call `<.input>`,
  `<.icon>` or another generated component that the repository does not have.
  If a server-rendered feature eventually needs a reusable component, add the
  smallest project-specific one with its call site and tests.

### JS and CSS guidelines

- **Use Tailwind CSS classes and custom CSS rules** to create polished, responsive, and visually stunning interfaces.
- Tailwindcss v4 **no longer needs a tailwind.config.js** and uses a new import syntax in `app.css`:

      @import "tailwindcss" source(none);
      @source "../css";
      @source "../js";
      @source "../../lib/my_app_web";

- **Always use and maintain this import syntax** in the app.css file for projects generated with `phx.new`
- **Never** use `@apply` when writing raw css
- **Always** manually write your own tailwind-based components instead of using daisyUI for a unique, world-class design
- Out of the box **only the app.js and app.css bundles are supported**
  - You cannot reference an external vendor'd script `src` or link `href` in the layouts
  - You must import the vendor deps into app.js and app.css to use them
  - **Never write inline <script>custom js</script> tags within templates**

### UI/UX & design guidelines

- **Produce world-class UI designs** with a focus on usability, aesthetics, and modern design principles
- Implement **subtle micro-interactions** (e.g., button hover effects, and smooth transitions)
- Ensure **clean typography, spacing, and layout balance** for a refined, premium look
- Focus on **delightful details** like hover effects, loading states, and smooth page transitions


<!-- usage-rules-start -->

<!-- phoenix:elixir-start -->
## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`
- `mix deps.clean --all` is **almost never needed**. **Avoid** using it unless you have good reason
<!-- phoenix:elixir-end -->

### The retain dependency

Spaced repetition for the puzzle deck is `retain` (amilner42/retain), our own
library: a Leitner ladder over an append-only review log, in Oskol's own
Postgres, with nothing to start. It is **pinned by commit, never a branch** --
a player's schedule must not move because someone pushed upstream. Its tables
arrive through `Retain.Migration`, one Oskol migration per schema version
(`priv/repo/migrations/*_add_retain_v<NN>.exs`, from `mix retain.gen.migration`
-- never edit one, add the next), and the ladder is
`config :retain, intervals: [1, 1, 3, 7, 21, 58, 145, 365]`: level 0 is a day
rather than retain's zero, so a puzzle just missed comes back tomorrow instead
of later in the same session. Nothing outside
`lib/oskol/gleam/caps/practice.ex` calls `Retain.*` -- above that it is the
`practice` cap, in Gleam. A change retain needs is a PR there and a new `ref:`
here, not a fork.

<!-- phoenix:phoenix-start -->
## Phoenix guidelines

- Remember Phoenix router `scope` blocks include an optional alias which is prefixed for all routes within the scope. **Always** be mindful of this when creating routes within a scope to avoid duplicate module prefixes.

- You **never** need to create your own `alias` for route definitions! The `scope` provides the alias, ie:

      scope "/admin", AppWeb.Admin do
        pipe_through :browser

        live "/users", UserLive, :index
      end

  the UserLive route would point to the `AppWeb.Admin.UserLive` module

- `Phoenix.View` no longer is needed or included with Phoenix, don't use it
<!-- phoenix:phoenix-end -->

<!-- phoenix:html-start -->
## Phoenix HTML guidelines

- Phoenix templates **always** use `~H` or .html.heex files (known as HEEx), **never** use `~E`
- **Always** use the imported `Phoenix.Component.form/1` and `Phoenix.Component.inputs_for/1` function to build forms. **Never** use `Phoenix.HTML.form_for` or `Phoenix.HTML.inputs_for` as they are outdated
- When building forms **always** use the already imported `Phoenix.Component.to_form/2` (`assign(socket, form: to_form(...))` and `<.form for={@form} id="msg-form">`), then access those forms in the template via `@form[:field]`
- **Always** add unique DOM IDs to key elements (like forms, buttons, etc) when writing templates, these IDs can later be used in tests (`<.form for={@form} id="product-form">`)
- For "app wide" template imports, you can import/alias into the `my_app_web.ex`'s `html_helpers` block, so they will be available to all LiveViews, LiveComponent's, and all modules that do `use MyAppWeb, :html` (replace "my_app" by the actual app name)

- Elixir supports `if/else` but **does NOT support `if/else if` or `if/elsif`. **Never use `else if` or `elseif` in Elixir**, **always** use `cond` or `case` for multiple conditionals.

  **Never do this (invalid)**:

      <%= if condition do %>
        ...
      <% else if other_condition %>
        ...
      <% end %>

  Instead **always** do this:

      <%= cond do %>
        <% condition -> %>
          ...
        <% condition2 -> %>
          ...
        <% true -> %>
          ...
      <% end %>

- HEEx require special tag annotation if you want to insert literal curly's like `{` or `}`. If you want to show a textual code snippet on the page in a `<pre>` or `<code>` block you *must* annotate the parent tag with `phx-no-curly-interpolation`:

      <code phx-no-curly-interpolation>
        let obj = {key: "val"}
      </code>

  Within `phx-no-curly-interpolation` annotated tags, you can use `{` and `}` without escaping them, and dynamic Elixir expressions can still be used with `<%= ... %>` syntax

- HEEx class attrs support lists, but you must **always** use list `[...]` syntax. You can use the class list syntax to conditionally add classes, **always do this for multiple class values**:

      <a class={[
        "px-2 text-white",
        @some_flag && "py-5",
        if(@other_condition, do: "border-red-500", else: "border-blue-100"),
        ...
      ]}>Text</a>

  and **always** wrap `if`'s inside `{...}` expressions with parens, like done above (`if(@other_condition, do: "...", else: "...")`)

  and **never** do this, since it's invalid (note the missing `[` and `]`):

      <a class={
        "px-2 text-white",
        @some_flag && "py-5"
      }> ...
      => Raises compile syntax error on invalid HEEx attr syntax

- **Never** use `<% Enum.each %>` or non-for comprehensions for generating template content, instead **always** use `<%= for item <- @collection do %>`
- HEEx HTML comments use `<%!-- comment --%>`. **Always** use the HEEx HTML comment syntax for template comments (`<%!-- comment --%>`)
- HEEx allows interpolation via `{...}` and `<%= ... %>`, but the `<%= %>` **only** works within tag bodies. **Always** use the `{...}` syntax for interpolation within tag attributes, and for interpolation of values within tag bodies. **Always** interpolate block constructs (if, cond, case, for) within tag bodies using `<%= ... %>`.

  **Always** do this:

      <div id={@id}>
        {@my_assign}
        <%= if @some_block_condition do %>
          {@another_assign}
        <% end %>
      </div>

  and **Never** do this – the program will terminate with a syntax error:

      <%!-- THIS IS INVALID NEVER EVER DO THIS --%>
      <div id="<%= @invalid_interpolation %>">
        {if @invalid_block_construct do}
        {end}
      </div>
<!-- phoenix:html-end -->

<!-- phoenix:liveview-start -->
## Phoenix LiveView guidelines

- **Never** use the deprecated `live_redirect` and `live_patch` functions, instead **always** use the `<.link navigate={href}>` and  `<.link patch={href}>` in templates, and `push_navigate` and `push_patch` functions LiveViews
- **Avoid LiveComponent's** unless you have a strong, specific need for them
- LiveViews should be named like `AppWeb.WeatherLive`, with a `Live` suffix. When you go to add LiveView routes to the router, the default `:browser` scope is **already aliased** with the `AppWeb` module, so you can just do `live "/weather", WeatherLive`
- Remember anytime you use `phx-hook="MyHook"` and that js hook manages its own DOM, you **must** also set the `phx-update="ignore"` attribute
- **Never** write embedded `<script>` tags in HEEx. Instead always write your scripts and hooks in the `assets/js` directory and integrate them with the `assets/js/app.js` file

### LiveView streams

- **Always** use LiveView streams for collections for assigning regular lists to avoid memory ballooning and runtime termination with the following operations:
  - basic append of N items - `stream(socket, :messages, [new_msg])`
  - resetting stream with new items - `stream(socket, :messages, [new_msg], reset: true)` (e.g. for filtering items)
  - prepend to stream - `stream(socket, :messages, [new_msg], at: -1)`
  - deleting items - `stream_delete(socket, :messages, msg)`

- When using the `stream/3` interfaces in the LiveView, the LiveView template must 1) always set `phx-update="stream"` on the parent element, with a DOM id on the parent element like `id="messages"` and 2) consume the `@streams.stream_name` collection and use the id as the DOM id for each child. For a call like `stream(socket, :messages, [new_msg])` in the LiveView, the template would be:

      <div id="messages" phx-update="stream">
        <div :for={{id, msg} <- @streams.messages} id={id}>
          {msg.text}
        </div>
      </div>

- LiveView streams are *not* enumerable, so you cannot use `Enum.filter/2` or `Enum.reject/2` on them. Instead, if you want to filter, prune, or refresh a list of items on the UI, you **must refetch the data and re-stream the entire stream collection, passing reset: true**:

      def handle_event("filter", %{"filter" => filter}, socket) do
        # re-fetch the messages based on the filter
        messages = list_messages(filter)

        {:noreply,
        socket
        |> assign(:messages_empty?, messages == [])
        # reset the stream with the new messages
        |> stream(:messages, messages, reset: true)}
      end

- LiveView streams *do not support counting or empty states*. If you need to display a count, you must track it using a separate assign. For empty states, you can use Tailwind classes:

      <div id="tasks" phx-update="stream">
        <div class="hidden only:block">No tasks yet</div>
        <div :for={{id, task} <- @stream.tasks} id={id}>
          {task.name}
        </div>
      </div>

  The above only works if the empty state is the only HTML block alongside the stream for-comprehension.

- **Never** use the deprecated `phx-update="append"` or `phx-update="prepend"` for collections

### LiveView tests

- `Phoenix.LiveViewTest` module and `LazyHTML` (included) for making your assertions
- Form tests are driven by `Phoenix.LiveViewTest`'s `render_submit/2` and `render_change/2` functions
- Come up with a step-by-step test plan that splits major test cases into small, isolated files. You may start with simpler tests that verify content exists, gradually add interaction tests
- **Always reference the key element IDs you added in the LiveView templates in your tests** for `Phoenix.LiveViewTest` functions like `element/2`, `has_element/2`, selectors, etc
- **Never** tests again raw HTML, **always** use `element/2`, `has_element/2`, and similar: `assert has_element?(view, "#my-form")`
- Instead of relying on testing text content, which can change, favor testing for the presence of key elements
- Focus on testing outcomes rather than implementation details
- Be aware that `Phoenix.Component` functions like `<.form>` might produce different HTML than expected. Test against the output HTML structure, not your mental model of what you expect it to be
- When facing test failures with element selectors, add debug statements to print the actual HTML, but use `LazyHTML` selectors to limit the output, ie:

      html = render(view)
      document = LazyHTML.from_fragment(html)
      matches = LazyHTML.filter(document, "your-complex-selector")
      IO.inspect(matches, label: "Matches")

### Form handling

#### Creating a form from params

If you want to create a form based on `handle_event` params:

    def handle_event("submitted", params, socket) do
      {:noreply, assign(socket, form: to_form(params))}
    end

When you pass a map to `to_form/1`, it assumes said map contains the form params, which are expected to have string keys.

You can also specify a name to nest the params:

    def handle_event("submitted", %{"user" => user_params}, socket) do
      {:noreply, assign(socket, form: to_form(user_params, as: :user))}
    end

#### Creating a form from changesets

When using changesets, the underlying data, form params, and errors are retrieved from it. The `:as` option is automatically computed too. E.g. if you have a user schema:

    defmodule MyApp.Users.User do
      use Ecto.Schema
      ...
    end

And then you create a changeset that you pass to `to_form`:

    %MyApp.Users.User{}
    |> Ecto.Changeset.change()
    |> to_form()

Once the form is submitted, the params will be available under `%{"user" => user_params}`.

In a template, pass the form assign to `<.form>` and drive fields from
`@form`. Oskol intentionally has no generated `<.input>` component, so a
future server-rendered form must use a native input or add a small
project-specific component with the feature:

    <.form for={@form} id="todo-form" phx-change="validate" phx-submit="save">
      <input id={@form[:field].id} name={@form[:field].name} value={@form[:field].value} type="text" />
    </.form>

Always give the form an explicit, unique DOM ID, like `id="todo-form"`.

#### Avoiding form errors

**Always** use a form assigned via `to_form/2` in the LiveView. In the
template, access fields through the form assign rather than through the
changeset:

    <%!-- ALWAYS do this (valid) --%>
    <.form for={@form} id="my-form">
      <input id={@form[:field].id} name={@form[:field].name} value={@form[:field].value} type="text" />
    </.form>

And **never** do this:

    <%!-- NEVER do this (invalid) --%>
    <.form for={@changeset} id="my-form">
      <input name={@changeset[:field].name} type="text" />
    </.form>

- You are FORBIDDEN from accessing the changeset in the template as it will cause errors
- **Never** use `<.form let={f} ...>` in the template, instead **always use `<.form for={@form} ...>`**, then drive all form references from the form assign as in `@form[:field]`. The UI should **always** be driven by a `to_form/2` assigned in the LiveView module that is derived from a changeset
<!-- phoenix:liveview-end -->

<!-- usage-rules-end -->
# Oskol - backgammon, from a link

## Project Overview
Oskol (oskol.io) is a backgammon site. The mission: become the best place on
the internet to play backgammon. You play a friend from a link: no account
needed, phone-friendly, free. The game is the real thing, by the book, and every
game is graded by the analysis engine once it is over: play a friend from
a link, then learn from the game.
**Backgammon** is the classic race game with the doubling cube: single games,
matches to 3, 5 or 7 with the Crawford rule, or unlimited play with the
Jacoby rule. A roll that can play nothing is a state, not a skipped turn:
the dice stand for both players under "no legal moves" until the mover
passes, and every time control gives each turn its first 12 seconds free.
Between the games of a match (or of unlimited play) the finished game's
position stays up, nobody is on the clock, and the next game starts when
both players have pressed READY. Every game can be played with an optional
time control.

Oskol used to host poker, go and chess too; they were removed in the pivot
(the repository history keeps them). Their old links (`/poker`, `/go`,
`/chess`, with or without a room id or `?game=`) redirect to `/`
(`OskolWeb.RemovedGameController`), and `/papi/games/<slug>` for them is a
404 like any slug that names no game.

The first player picks everything (mode, clock), shares a link, and
the game starts the moment the second player types a name. **A seat is held
by the guest cookie that took it** (`OskolWeb.Plugs.GuestId`: opaque,
HttpOnly, year-long), and no URL anywhere carries a secret: a player's link
is the plain room URL. A seat whose holder is away can be claimed from the
invite link by anyone with the room code -- friends playing, not security --
and it is that browser's from then on. One browser holds one seat at a
table, whichever door it came in by: a guest already seated there is
refused a second, on joining and on claiming alike (claiming back the seat
it already holds is how a closed tab comes back). The room code is
therefore the only thing between a stranger and a live game, so a code is
six characters of a 32-letter alphabet (about 1.07 billion), not six digits.
A display name is display only and grants nothing. A socket also names its
**client** (a per-tab id the browser mints; it authenticates nothing): the
room compares it with itself to tell one tab reconnecting -- a reload, a
route change, a phone waking its websocket up -- from another tab taking the
seat over, which is the only case the connection that had it is told about
(`src/oskol/rooms/seat.gleam`). **Accounts** are a guest grown up: sign in
by email (a mailed link, and the same sign-in as a six-digit code) and
`guests.user_id` names the account on that browser, which is why identity
has no second mechanism beside the guest. **A seat an account holds is
that account's**: `seat.holder` is the one rule every door asks — an owned
seat (`games.players[i].user_id`) answers to its account, from any browser
signed into it and from no other, the guest on it ignored; an unowned seat
answers to the guest that took it, exactly as before. An owned seat is
therefore not claimable: the invite link says `owned` and offers nothing.
Signing in **stamps** every unowned seat this browser holds onto the
account and **rotates** its guest id in the same write, so the id it
arrived with opens nothing afterwards. A browser that never signs in is
never bound: its seats stay unowned and it plays exactly as a guest always
has.

The game is built on **gamekit**, a small framework that keeps the rules,
the room and the client apart: a game is one Gleam module that implements
the contract below, and the server and the protocol are generic. Backgammon
is the only game registered, and it is the product; the framework stays
because the separation is what keeps the rules pure, seeded and testable.

**Tech stack:** Gleam (the game + framework), Elixir/Phoenix (platform host),
Elm (client), Tailwind CSS.

## Architecture in one picture

```
Gleam games ──(contract)──> gamekit host ──(opaque instance + JSON)──> Elixir room
                                                                          │
Elm client <──(protocol: scene, legal, outcome, events, clock)── Phoenix channel <──┘
```

Three layers, two fixed boundaries:

1. **Gleam owns the game** (`src/gamekit/`, `src/backgammon/`).
   Pure, seeded, tested.
2. **Elixir owns the platform** (`lib/`). Rooms, setup, reconnect, rematch,
   routes. It never sees a checker or a die: it calls `Oskol.GameKit`, which
   wraps `gamekit/host` and speaks only opaque instances and JSON.
3. **Elm owns the client** (`assets/src/`). One `Browser.application` owns
   every URL: the library, a game's start page, and the table. It decodes the
   fixed protocol and renders the backgammon board from it, and reads the
   landing pages' data from a JSON API (`/papi`). Elixir serves the SPA shell
   with the head a crawler needs, and nothing else.

## The game contract (`src/gamekit/game.gleam`)

```gleam
Game(
  info:          Info,                                      // slug, name, formats, clocks, default clock
  init:          fn(Config, List(Seat), Rng) -> Result(state, String),
  decode_action: fn(action.Incoming) -> Result(action, String),
  apply:         fn(state, PlayerId, action) -> Result(#(state, List(Event)), String),
  legal:         fn(state, PlayerId) -> List(Schema),       // what this player may do now
  scene:         fn(state, Viewer) -> Scene,                // per-viewer projection
  outcome:       fn(state) -> Outcome,
  clocks:        fn(state) -> List(PlayerId),               // who is on the clock right now
  timeout:       fn(state, PlayerId) -> Timeout(action),    // Forfeit, or Act(action) taken for them
  record:        fn(state) -> Option(Json),                 // the whole public record, or game.no_record
)
```

`record` is what `GET /papi/games/:slug/rooms/:id/record` serves to anyone
with the room: everything a replay or an analysis needs, too big to ride in every update.
Backgammon's is every game of the match with every turn (notation, the
position and cube it left, where the moved checkers `landed`); its scene
carries only the game on the board plus one result line per finished game.

A format is a name and a config the game reads (`game.config_get`): all
the creator tunes is the format and the clock. `Info.clocks` lists the
time-control presets a game offers and `default_clock` the one
preselected.

Rules that keep this honest:
- **All randomness goes through `gamekit/rng`** stored in the state. Never
  `int.random` or `list.shuffle`. A game is its seed plus its action log.
- **`apply` validates and never mutates on error.** It returns events for
  every state change; the client animates from events, not from diffing.
- **No presentation in the engine.** No animation flags, no wizard state.
  Multi-step interactions are action schemas with candidates.
- **Ids are deterministic and opaque.** Checkers are `"w1".."b15"`. An id
  never reveals a face. Faces travel as token props.
- **Hidden information is the projection's job, and the host's.** `scene`
  decides per viewer: `scene.hidden_zone` sends a count only,
  `scene.hidden(token)` keeps an id but drops face and props. Events are
  emitted once for everyone; the host runs them through
  `event.for_viewer(events, viewer_scene)`, which blanks the id of any
  `token_moved` whose token the viewer's scene does not show and drops
  reveals they cannot see. `custom` payloads are not filtered: never put
  one viewer's secret in one.
- **Sort before you serialise a dict keyed by a custom type.** Erlang orders
  atom keys by atom-table index, which differs between VMs, so unsorted
  `dict.to_list` output makes scene JSON (and golden fingerprints)
  irreproducible.
- **Games never read the time.** `clocks(state)` names the players who should
  be charged right now. `gamekit/clock` owns the arithmetic, `gamekit/instance`
  applies it with the host's `now`, and when a clock runs out the instance
  asks `timeout`: backgammon forfeits (a game may instead `Act` for the
  player and play on). An action that arrives after a clock ran
  out is applied after the timeout if it is still legal, never instead of
  it. Clock-driven turns do not count as room activity: a table nobody is
  at still goes idle after an hour.

## The protocol (`src/gamekit/scene.gleam`, `event.gleam`, `action.gleam`)

The client only ever decodes these:
- **Scene**: `players` (counters, flags, data) and `zones` of `tokens` with
  stable ids, a `face`, and `props`; plus a narrow `data` escape hatch.
- **Events**: `token_moved`, `counter_changed`, `revealed`, `phase_changed`,
  `message`, or `custom(kind, payload)` for bespoke views.
- **Schemas**: legal actions as `{name, label, params}` where a `select` param
  carries its zone and candidate ids, a `choice` its options, a `number` its
  bounds.
- **Outcome**: `ongoing` or `finished(winners)`.
- **Clock**: `enabled`, `label`, per-player `remaining_ms`, `move_ms` (free
  time left on this move) and `running`, `timed_out`.

Actions in: `{"name": "<action>", "params": {...}}`. Legal actions may
be enumerated (backgammon sends one `move` schema per legal move) or
described with bounds. Hidden information is resolved by the `scene`
projection per viewer: in backgammon the mover stages moves (`move`, `undo`)
that only their own scene shows, and commits them with `play`.

### Time controls
Presets live in `gamekit/clock.presets()`: Fischer, Bronstein and per-move.
A game lists which presets it offers. A game may also declare a **turn delay** (`Info.turn_delay_ms`,
applied by `instance.start` through `clock.with_turn_delay`): the first N
milliseconds of every turn are free under every control, and unused delay is
never banked. It overlaps rather than stacks with a control's own free time
(the longer of the two wins). Backgammon takes 12 seconds, which is what
live play does and what the dice animation runs inside; the default is
zero. The Elixir room schedules a tick for the next possible expiry and
calls `GameKit.expire/2`, which applies the game's `timeout`.

## File map

```
src/gamekit/        framework: rng, scene, event, action, game, clock, instance
                    (typed `Running`, and the `Instance` that erases it),
                    replay (a log folded through the typed steps),
                    registry (add games here), host (Elixir surface),
                    text (agent/test rendering), conformance, fixture
src/backgammon/     Backgammon: board (rules + move generation), state (turns,
                    dice, cube, match play), engine, projection, game,
                    analysis (the analysis engine's board, a game's turns)
src/oskol/          the platform's own decisions, in Gleam (see "Platform
                    decisions live in Gleam" below): core (ctx, session,
                    error, envelope), caps (the IO a handler may do),
                    rooms (codes, names, errors, invite), guests/identity,
                    landing/copy, reviews/report, puzzles (+ puzzles/extract,
                    puzzles/picture), practice/deck (the puzzle deck),
                    handlers (rooms, landing,
                    reviews, record, ratings, auth)
test/gamekit/       protocol, rng, clock, action, event, golden replays
test/oskol/         handler and rule tests on stub capabilities (fakes.gleam)
test/backgammon/    board rules, engine, cube, oracle, properties, turns
lib/oskol/game_kit.ex           the only Elixir -> Gleam bridge
lib/oskol/game/game_server.ex   generic room: setup, auto-start, actions, clocks, rematch
lib/oskol/persistence.ex        games + game_actions tables (seed + action log per room)
lib/oskol/guests.ex             silent guest identity: guests table (name + prefs)
lib/oskol/auth.ex               accounts: users + login_tokens, the rows a sign-in spends
lib/oskol/auth/limiter.ex       the sign-in rate counters (ETS, per node)
lib/oskol/mail.ex               the one mail Oskol sends: the sign-in link and code
lib/oskol/mailer.ex             Swoosh: Postmark in prod, /dev/mailbox in dev
lib/oskol_web/plugs/guest_id.ex mints/renews the year-long guest cookie on every visit
lib/oskol/game/persister.ex     write-behind: rooms cast, one process writes in order
lib/oskol/game/rehydrator.ex    rebuild a room from the log on lookup (deploys, idle stops)
lib/oskol/reviews.ex            game_reviews + game_records tables, the log a review
                                reads, the engine's HTTP
src/oskol/core/raw.gleam        stored JSON back onto the wire without rebuilding it
lib/oskol/reviews/queue.ex      runs post-game reviews one room at a time, off the room,
                                deck syncs the same way ({:deck, user_id}), and one
                                batch of owed puzzle pictures a sweep (:pictures)
src/oskol/practice/sync.gleam   filling an account's mistakes deck: whose, in what
                                order, what is stamped, and when to give up
src/oskol/handlers/practice.gleam  a practice session: an account's deck, a guest's
                                own mistakes, the browser's timezone, burying one
src/oskol/handlers/puzzles_hub.gleam  TRY ONE: a random puzzle whose answer stands
                                clear, for a stranger on the practice home
lib/oskol/practice.ex           those decisions run with the real rows behind them
lib/oskol/puzzles.ex            puzzles + puzzle_sources/attempts/shares/images tables;
                                the one write, in one transaction with its marker
src/oskol/puzzles.gleam         a puzzle's stored shape: the question, its canonical
                                key and id, the answer, the JSON of each column
src/oskol/puzzles/extract.gleam which turns of a graded game are puzzles
src/oskol/handlers/puzzles.gleam the puzzle pages: the question, the grade, the
                                 reveal, what an answer does to a deck, the
                                 memory line, a game's own mistakes
src/oskol/puzzles/tree.gleam     every legal way to play a roll, as a DAG of
                                 boards the page walks (no move generator in Elm)
src/oskol/puzzles/grade.gleam    right, close or wrong: the checker bands and the
                                 cube answered by its side against the
                                 engine's five bands
src/oskol/puzzles/fixture.gleam  real payloads for the Elm suite (mix oskol.fixtures)
lib/oskol/puzzles/tree_cache.ex  a puzzle's tree, worked out once (ETS, bounded)
src/oskol/puzzles/picture.gleam a puzzle's link picture as SVG: the board in the
                                default theme, 1200 x 630, pure
lib/oskol/puzzles/pictures.ex   rasterises it (rsvg-convert) into puzzle_images in
                                the review job and the sweep, bounded; never on a request
lib/oskol_web/plugs/puzzle_picture.ex  GET /puzzles/:id.png from the row, or the
                                 site's board (priv/static/images/puzzle-board.png)
lib/oskol/game/ready_up_patch.ex  one-off: old match logs get the READYs the engine now waits for
lib/oskol_web/channels/game_channel.ex   generic channel ("action", "rematch" in; "update" out)
src/oskol/rooms/seat.gleam       who holds a seat (the guest, or the account that
                                 owns it), whether it may be claimed, and what an
                                 attach means: the same client back, or a takeover
src/oskol/rooms/code.gleam       the shape of a room code, and how a typed one is read
lib/oskol_web/controllers/spa_controller.ex    "/" and "/:slug": the SPA shell
                                 plus the title, description, canonical, og
                                 and JSON-LD a crawler reads
lib/oskol_web/controllers/page_controller.ex   "/:slug/:id" serves the same client
lib/oskol_web/controllers/removed_game_controller.ex   old /poker, /go, /chess links -> "/"
lib/oskol/gleam/ctx_builder.ex   builds the Gleam Ctx and Session for a caller
lib/oskol/gleam/caps/*.ex        the real IO behind src/oskol/caps/*.gleam
src/oskol/caps/practice.gleam    the puzzle deck: what a player is drilling, what is
                                 due now, how an attempt went, and the correction
                                 after the reveal. The retain library is behind it and
                                 nothing above this file knows that
lib/oskol/gleam/caps/practice.ex its real IO, over retain: times cross as Unix ms, a
                                 card's content as JSON text, tags sorted
src/oskol/practice/deck.gleam    the deck's own rules: due before new, ten new a day,
                                 KEEP GOING uncapped, and the sentence each refusal
                                 gives the player (a puzzle not in the deck is the
                                 only 404; a snooze needs a card in rotation)
lib/oskol_web/controllers/api/landing_controller.ex   /papi JSON for the Elm client
assets/src/Main.elm              SPA shell: routes, page dispatch, JOIN GAME
assets/src/Route.elm             the three client routes, mirroring the server's
assets/src/Api.elm               the /papi envelope + CSRF header
assets/src/Api/Catalog.elm       the landing pages' data and its decoders
assets/src/Page/GameLanding.elm  "/" the home page (CREATE GAME's dialog, the theme
                                 picker) and "/:slug?game=" what an invite offers
assets/src/Page/HomeBoard.elm    the home page's board: the table edge to edge, the
                                 2x2 menu in its right band
assets/src/Page/Play.elm         "/:slug/:id" the table, and the lobby before it;
                                 asks /puzzles?game=n for each game /ratings reports
                                 graded (a seat only) and feeds both result cards'
                                 PRACTICE THIS GAME'S N MISTAKES and save offer
assets/src/Page/Replay.elm       "/:slug/:id/replay" a room's games played again, with the
                                 engine's analysis (polls /reviews while any is pending):
                                 the mistakes list jumps to a step, the band offers the
                                 best move, the dice take the move back; a turn's note has
                                 MOVE and CUBE tabs, each a sentence in words (built from
                                 the chances) over the numbers in columns; a seated
                                 reader's ANALYSIS tab offers PRACTICE THIS GAME'S N
                                 MISTAKES per game (`Out = StartRun`); on a phone
                                 (`onePanel`: under 640 wide, or under 480 tall
                                 sideways) the note and the game panel are one
                                 panel with four tabs, the page scrolling, not it
assets/src/Page/Puzzles.elm      "/puzzles" the practice home: an account's counts and
                                 PRACTICE (or "Done for today" and KEEP GOING), a guest's
                                 "23 mistakes from your 4 games", a stranger's TRY ONE
assets/src/Api/Practice.elm      /papi/practice, /more, /tz and /papi/puzzles/random
assets/src/Page/Puzzle.elm       "/puzzles/:id" one puzzle: the question over the board
                                 (Games/Backgammon/Puzzle.elm's `Table`, the page owning
                                 the path and the lazy fetches), PLAY or the two cube
                                 scale, the reveal in the replay's words, the level line
                                 and its four buttons, the memory line, SHARE, NEXT, and
                                 the end of a run: the score, then KEEP GOING or the sign-in
assets/src/Games/Backgammon/Puzzle.elm  the puzzle wire: the question and tree decoders,
                                 the board on a tree node, and the reveal's decoders
                                 (verdict, candidates, cube band, schedule, memory)
assets/src/Games/Backgammon/Replay.elm  the record and reviews as the replay reads them:
                                 decoders, the board at each step, verdicts per record line;
                                 the engine's cube call is read once here, into `Optimal`
                                 (no double, double/take, double/pass, or a word a later
                                 engine wrote), and its answer into `Response`
assets/src/Games/Backgammon/Words.elm   the engine's verdict in words and numbers, pure:
                                 the move's two sentences, the cube's from either side,
                                 the three equities with the call in ink, the chance cells
                                 and grade tags. The replay reads it and the puzzle
                                 reveal will; `tooGood` is the twin of Gleam's
                                 `oskol/puzzles.too_good` and moves with it
assets/src/Ui/Shell.elm          the OSKOL wordmark, the code prompt, the footer
assets/src/Ui/Scrub.elm          one row of plates (arrows outside, buttons between) under
                                 the table's board and the replay's, the same on both
assets/src/Protocol.elm          protocol decoders (game-agnostic)
assets/src/Games/Backgammon/View.elm  the backgammon board (and the two
                                 player bars: name, presence dot, match PR);
                                 `viewStill` draws one position, `viewPlay` the
                                 same slab with its taps switched on
assets/src/Games/Backgammon/Puzzle.elm  a puzzle as the wire sends it (the
                                 question and the DAG of legal moves) and the
                                 board it is played on: a tap walks to a child,
                                 undo walks back, PLAY on a terminal node
assets/src/View/Clock.elm        clock display
assets/css/app.css               the multicade/notebook design system (paper, pixel,
                                 pix, btn-arcade, tile, bg-board...)
                                 plus the landing's quiet notebook (quiet, q-card,
                                 q-title, q-eyebrow, q-opt, q-btn, q-field)
                                 and the sixteen backgammon boards (.bg-theme-*)
src/oskol/guests/prefs.gleam     the display preferences a guest may keep, and
                                 the values each one allows
src/oskol/handlers/auth.gleam    signing in: the mail, the link, the code, the
                                 refusals, the rate verdict, where `next` may point
lib/oskol_web/controllers/login_controller.ex  GET /login/:token: reads the token,
                                 spends nothing, serves the shell with its flags
assets/src/Page/Login.elm        that page: confirm, the win, expired (a fresh mail)
assets/src/Ui/Username.elm       a new account's username on the win, and changing it
assets/src/Ui/Identity.elm       the guest / account badge beside every name
src/oskol/guests/username.gleam  which usernames a new account tries, in order
assets/src/Ui/SignIn.elm         signing in, the one component every entry embeds:
                                 email -> "Check your email" + six digits -> the win
assets/src/Api/Auth.elm          /papi/auth/* and /papi/me for the client
playwright/test-accounts/test.js the whole sign-in flow in three browsers
```

## Platform decisions live in Gleam (`src/oskol/`)

Games were always Gleam. So is the platform's decision-making: what a name
has to be, when a game code is free, what an invite link offers, what a
refusal says, what a JSON page carries. The rule is the same one the games
follow — Gleam is pure, Elixir does the IO:

```
Phoenix (router, plugs, controllers, GenServers)       [Elixir, thin]
  -> handler(ctx, session, request)                    [GLEAM, all decisions]
       ctx.<domain>.<cap>(...) performs injected IO
  -> JSON on the wire                                  [Elixir, thin]
```

- `Ctx` (src/oskol/core/ctx.gleam) is a record of capability closures, one
  group per domain, built by `Oskol.Gleam.CtxBuilder.build/1`. Each
  `src/oskol/caps/<d>.gleam` has an Elixir twin at
  `lib/oskol/gleam/caps/<d>.ex`; they must agree on constructor tag and
  field order (a Gleam record is a tagged tuple).
- `Session` is the caller: a guest id (or nothing), and the account signed
  in on that browser (or nothing). The guest id is the cookie; the account
  is read off the guest row once per request.
- Caps are fine-grained and speak the domain types in `src/oskol/*` — never
  Ecto structs or raw maps. A room process crosses as the opaque
  `rooms/room.Room`.
- Caps whose failure is product behaviour return `Result` and the handler
  turns it into the sentence a player reads (`rooms/errors.message`).
  Everything else raises Elixir-side and surfaces as a 500, as before.
- Tests build a `Ctx` of stubs that panic (`test/oskol/fakes.gleam`), so a
  handler test that reaches IO it did not arrange for fails loudly.
- `Oskol.Game` (minting a code, finding a room) and the `/papi` controller
  are two doors onto the same handlers, so nothing that decides anything
  exists twice.

## URLs

All three are Elm routes, and all three are server routes: a visitor may
arrive at any of them cold, and moving between them afterwards is a
`pushUrl`, not a page load.

- `/` the home page (the library, listing backgammon)
- `/papi/library`, `/papi/games/:slug` (GET and POST) the landing pages as
  JSON for the Elm client. Public like the pages, session-based guest
  identity, CSRF token in `x-csrf-token`. Envelope: `{"ok": true, ...}` or
  `{"ok": false, "error": {"code", "message"}}` (404 not_found,
  422 validation_failed, 500 server_error).
- `/backgammon` create a game; `/backgammon?game=<id>` is the invite link
- `/backgammon/<id>` a running game — and, until the second player arrives,
  the waiting room: a room with no instance yet answers the game channel
  with a lobby payload. The URL says which room and nothing else; what it
  opens is the room's answer on the game channel, against the browser's
  guest cookie. A browser holding no seat there is refused ("unauthorized",
  never saying why) and the client sends it to the invite link, which is the
  one page that says whether there is a seat to take. A `?t=` from a link
  minted before seat tokens were dropped is ignored by every route and every
  handler.
- `/backgammon/<id>/replay?game=<n>&step=<s>` a room's games played again,
  a line of the record at a time, with the analysis engine's verdicts. It
  opens for anyone with the link -- a replay is what both players and any
  spectator already saw -- and is served the SPA shell, `noindex`. The board
  faces the reader's own seat when their guest holds one here, else the seat
  that played first, and the page turns the board around anyway. The table
  offers it from the match history and at game over. Board, steps and
  verdicts all come from `/record` and `/reviews`. The page keeps `step`
  current in the address bar (replaced, not pushed, so back still leaves
  the page), which is what makes a reload land on the same line and a
  link carry a move to a friend; `step` is omitted at the start of a game.
- `/puzzles` the practice home, PUZZLES on the home menu: what this
  visitor has to practice and PRACTICE, which starts a run (see "The home
  and a run" under Puzzles). Open to anyone, indexable, in the sitemap; the
  head (`SpaController.puzzles`) is "Puzzles" and the brief's one-liner,
  the same to everyone.
- `/puzzles/<id>` one puzzle: the position, "White to play 6-4. What's your
  play?", the board to play it on, then the reveal. Open to anyone with
  the link and indexable; `puzzles` is a reserved slug (before `/:slug` on
  both sides). The
  head (`SpaController.puzzle`, words from `handlers/puzzles.head`) is the
  question as the title and og:title, the score and cube as the
  description ("Match play, 3 away against 5. Cube centred."; no score is
  "Unlimited play", one point each way "Single game" unless Crawford, the
  picture's own words), the board's picture as og:image, nothing else; an
  id nobody stored is a 404. Not in the sitemap: too many. There is one
  prompt, `oskol/puzzles.prompt` ("White to play 6-4. What's your play?",
  "White to play. Double?", "White is doubled. Take?"): the wire, the head,
  the page and the picture all read it. `/puzzles/<id>?s=<token>` is a
  **story link** (`handlers/shares`): the same page, whose head says
  "Arie got this wrong. What's your play?" (the sharer's name, then the
  prompt's question: "Double?", "Take?") and whose reveal, after the
  reader's own attempt, adds "Arie played 24/23 13/11 (a bad move) and
  lost 2 points." The canonical stays the clean URL; the picture ignores
  `?s=`; a token nobody minted, or minted for another puzzle, is ignored
  and the page is the plain one. Only the seat that made the mistake can
  mint one (`POST /papi/puzzles/:id/shares`), and it names the sharer
  only, never the opponent.
- `/login/<token>` the page a mailed sign-in link opens. It **reads** the
  token and writes nothing: the page says "Sign in as you@example.com" with
  one button, and that button POSTs `/papi/auth/link`, which is the only
  thing that spends it. So a mail scanner prefetching the link cannot burn
  it and no other site can sign a visitor in. Under the button: "Opened
  this on another device? Enter the code from the mail there instead."
  Pressed, the page is the win every sign-in ends on ("You're in.", how
  many games came along, CONTINUE to where it was asked from), plus a line
  for a link that brought nothing, pointing at the other device. A dead
  token renders "That link has expired. We'll send a fresh one." over the
  sign-in (`Ui.SignIn`). Served the SPA shell, `noindex`; the flags
  (`state`, `email`, `next`) ride in a `login` meta tag. A bare `/login` names no game: 404. `login` and `dev` are
  reserved slugs (declared before the game routes).
- `/poker`, `/go`, `/chess` and anything under them: 302 to `/` (the games
  that were removed).

## The landing API (`/papi`)

The landing pages read and write over JSON. Every response is the same
envelope: `{"ok": true, ...payload}`, or `{"ok": false, "error": {"code",
"message"}}` — including on a non-2xx status, so the client parses bodies
rather than leaning on the status. Requests go same-origin, so the guest
cookie rides along and identity needs nothing from the client; writes carry
the page's CSRF token in `x-csrf-token`.

```
GET  /papi/library                     {ok, games, coming_soon, guest_name}
GET  /papi/games/:slug                 {ok, game, formats, clock_presets, copy, guest_name}
POST /papi/games/:slug                 {format, name, clock}
                                         -> {ok, id, path, player_id}
GET  /papi/games/:slug/rooms/:id       {ok, state, inviter_name, summary, disconnected}
POST /papi/games/:slug/rooms/:id       {name} | {player_id} -> {ok, id, path, player_id}
GET  /papi/games/:slug/rooms/:id/reviews  (open) the index, and only the index
                                       {ok, players, games: [{game_number,
                                           status, turns}]}  -- a few hundred
                                       bytes for a whole match
GET  /papi/games/:slug/rooms/:id/reviews/:game_number  (open) one game
                                       {ok, game_number, status, turns, review}
                                         review is null unless status is done;
                                         when it is, {levels, timing_ms, players,
                                         turns}; a turn names its record lines
                                         (entry, double_entry, answer_entry) and
                                         each candidate move its position and
                                         landings. A number the room has no game
                                         for is a 404.
POST /papi/games/:slug/rooms/:id/reviews/retry  {game_number} -> the index, a
                                         failed game queued again (a seat only)
GET  /papi/games/:slug/rooms/:id/record  (open)
                                       {ok, slug, id, you, seated, accounts, record}  (the game's
                                       `record`; `you` is the seat the board faces --
                                       the reader's own, else the first -- and `seated`
                                       says whether that seat is theirs)
GET  /papi/games/:slug/rooms/:id/ratings  (open) {ok, players: [{player_id,
                                       games, pr}], games: [{game_number,
                                       players: [{player_id, pr}]}]} -- each
                                       seat's PR over the games of THIS match
                                       the engine has graded (null while it has
                                       graded none), and each graded game's
                                       PRs by seat, for the table's match panel
GET  /papi/puzzles/:id                 (open) {ok, id, kind, question, tree,
                                         prompt} -- the position, the sentence it
                                         asks in, and for a checker play every
                                         legal way to play the roll as a DAG of
                                         boards. Never the answer, never a name,
                                         never the game it came from
GET  /papi/puzzles/:id/tree?node=      (open) one level of a tree too big to send
                                         whole: {ok, node, tree: Node}
POST /papi/puzzles/:id/attempts        {moves | band, key, s?} -> {ok, verdict, yours,
                                         best, top, cube, schedule, story}. Open; a
                                         guest and a puzzle outside the caller's deck
                                         get schedule: null and nothing is written.
                                         `s` is the story token the page was opened
                                         with: `story` is {name, kind, played, grade,
                                         equity_lost, date, result, headline, line}
                                         where it opens one for this puzzle, else
                                         null -- on the reveal and nowhere earlier
POST /papi/puzzles/:id/attempts/:key/outcome  {outcome: sooner|got_it|knew_it|never}
                                         -> {ok, schedule}. The attempt's own
                                         account only (403); 409 with nothing to
                                         amend
POST /papi/puzzles/:id/shares          {} -> {ok, token, url}  (the seat that
                                       made the mistake, by the holder rule --
                                       guest or account -- mints its story link,
                                       `/puzzles/:id?s=<token>`, the same one on
                                       every press; the opponent and a stranger
                                       are a 403 in one sentence; a GET never
                                       mints)
GET  /papi/puzzles/:id/mine            (a seat in the source game, either side)
                                         {ok, who, opponent, played, equity_lost,
                                         grade, date, result, replay}; 404 otherwise.
                                         `who` is "you" or the other seat's display
                                         name; `opponent` the other seat's, always;
                                         `date` the day the game ended (its review
                                         row's), never the day the source was written
GET  /papi/games/:slug/rooms/:id/puzzles?game=n  (a seat) {ok, puzzles: [{id, kind,
                                         prompt, due}], cursor, counts, game}
                                         -- 404 without a seat; 409 `puzzles_pending`
                                         while the game's review is done but its
                                         puzzles are not yet written (the page
                                         asks again in a moment)
GET  /papi/codes/:code                 {ok, slug, code}  (the code as typed, else
                                       normalised: the one that answered comes back)
POST /papi/auth/start                  {email, next?} -> {ok}  (always ok: no
                                       enumeration; over a rate limit it sends
                                       nothing and says the same. Mails a link and
                                       a six-digit code)
POST /papi/auth/link                   {token} -> {ok, saved, next, user, new}
POST /papi/auth/code                   {email, code} -> {ok, saved, next, user, new}
                                       (the code redeems only from the browser that
                                       asked; 5 tries, then dead)
POST /papi/auth/logout                 {ok}  (nilifies guests.user_id and drops
                                       this browser's sockets)
GET  /papi/me                          {ok, guest_name, user: {email, name} | null}
POST /papi/me/name                     {name} -> {ok, user}  (a signed-in browser
                                       renames its account; 422 "That name is
                                       taken." when another account has it)
GET  /papi/practice                    {ok, puzzles: [{id, kind, prompt, due}],
                                         cursor: null, counts: {due,
                                         new_today, new_tomorrow, deck} | null,
                                         mistakes: {puzzles, games} | null,
                                         game: null}
                                       -- an account's deck (due, then new;
                                       new_tomorrow is the day's budget or
                                       the cards never seen, whichever is
                                       fewer), a guest's own mistakes
                                       (unscheduled, counts null, no writes;
                                       `mistakes` counts all of them, from
                                       how many games), or nothing. Never
                                       paged: every fetch is the front of
                                       the queue, and "Done for today" is a
                                       fetch that comes back empty
GET  /papi/puzzles/random              {ok, id, kind, prompt}  TRY ONE: a
                                       random complete puzzle whose answer
                                       stands clear (a checker play whose
                                       runner-up gives up 0.02 or more, a
                                       cube in an outer band, |margin| >=
                                       0.08); 404 with a sentence while the
                                       pool has none. Reads nothing about
                                       the caller and writes nothing
POST /papi/practice/more               KEEP GOING: ten more new ones into
                                       rotation, then the same session
POST /papi/practice/tz                 {tz} -> {ok, tz}  (an IANA name, on the
                                       account's deck; Etc/UTC until set)
POST /papi/practice/bury               {id} -> {ok, id, level, due}  (back at
                                       the player's own midnight, level kept;
                                       409 when it is not in rotation)
GET  /papi/me/prefs                    {ok, prefs}
POST /papi/me/prefs                    {key, value} -> {ok, prefs}
GET  /papi/me/games                    {ok, games: [{slug, id, path, status,
                                         opponent, format, clock, your_move,
                                         time: {mine_ms, theirs_ms, running,
                                         free_ms, age_s} | null, idle_s}]}
                                       -- the unfinished rooms the caller's
                                       guest holds a seat in, newest activity
                                       first, from the rows alone
```

`path` is the URL of the seat that was just taken (`/:slug/:id`, carrying
nothing): the client goes there, and the seat waits in the lobby until its
opponent arrives. The seat is held by the guest cookie the write came with,
so the same URL is what anyone would be given for that room. `state` is
`open` (a free seat), `away` (a seat whose player is gone and that anyone
with the code may take back), `owned` (the only seats free belong to
accounts: nothing on offer), `seated` (with `path`: the caller already
holds a seat there, by its guest or its account, and the client goes
straight to the table), `full` (both players are there) or `missing`
(the room is over). `disconnected` names only the seats a visitor may
actually take, so an owned seat is never listed and nothing on the page can
be typed at it.

A game's own `clocks` are preset ids; `clock_presets` carries every preset,
so the picker can name the ones the game offers. Statuses: 404 `not_found`
(no such game, no such code, a room that is over), 422 `validation_failed`
(a name, a mode, a clock or a seat the room refused), 409 `not_in_rotation`
(a puzzle the session has moved past), 500 `server_error`.
Every decision behind these lives in `src/oskol/handlers/landing.gleam`,
except the record's, in `src/oskol/handlers/record.gleam`, and the reviews',
in `src/oskol/handlers/reviews.gleam`. A lobby, a slug that is not the
room's game and a room that is gone all answer the same 404, as the game
channel refuses without saying which. The caller's guest (the cap
`seated_game`, which answers which seat a guest holds) picks the seat the
record's board faces, and is what a retry takes. Nothing a reader does
spends engine time.

`/papi/me/games` is what the home page opens with: every room in `waiting`
or `playing` where the caller holds a seat by the holder rule — the guest
that took an unowned seat, or the account that owns one, so an account's
games follow it to any browser it signs in on and a browser that logged
out is offered none of them — read from `games` with no room woken
(`Persistence.seated_rooms`, the cap `persistence.seated_rooms`, the
handler `landing.my_games_json`, which asks `seat.held_by` of each room
and drops the rooms where the answer is nobody). Each
entry names the opponent (null in a lobby), the format and clock by name,
whether it is the caller's turn (`your_move`, from the row's `state`), the
two clocks as the snapshot last read them with how long ago that was
(`time`, so the client can charge the running one and count it down), and
seconds since the room was touched. The client (`Page/GameLanding.elm`)
shows them in a dialog over the home board when the list arrives with
anything in it, and keeps a "REJOIN N GAMES" button at the right end of the
player's own bar for as long as there are any. Nothing prunes games (they
are kept, finished or not), so nothing bounds the list yet.

`/papi/auth/*` is signing in, and every one of them is a POST on purpose: a
GET never signs anyone in. A token and its code are sha256 at rest, never
logged, single use, good for 15 minutes; a failed sign-in of any kind
answers one generic sentence. `saved` is how many of this browser's games
came with the account: signing in stamps every unowned seat its guest holds
and rotates that guest id, both in one ordered write, and the response
carries the fresh guest cookie. `next` is validated in Gleam — a local
path, or `/`. Rate limits are in-memory, per-node atomic reservations behind
the auth cap: configurable guest, address, source-IP (per-boot HMAC key only,
and omitted without Fly's trusted header) and global mail budgets. Defaults allow 200 real messages/day per running node
(under Postmark's 10,000-message monthly plan); spent rows and those expired for more than a
day are retired in a supervised bounded sweep at boot and then daily. A failed
pass only logs and retries on the next schedule. There is no switch:
signing in is always on, and prod sends real mail through Postmark. Decisions:
`src/oskol/handlers/auth.gleam`.

`/papi/me/prefs` is the visitor's own display taste — today the backgammon
board's colours, under `backgammon_theme`. Gleam owns the whitelist
(`src/oskol/guests/prefs.gleam`): an unknown key or a value that names no
theme is a 422 and nothing is written. It is display only: a theme never
reaches a scene, an event or the game channel, and each player's board is
their own. The client also keeps the pick in `localStorage` (the `storePref`
port), which is what paints the board before the round trip and all a
visitor whose guest cookie is gone has.

## Post-game reviews (backgammon)

Every backgammon game is graded by the analysis engine once it is over,
each game of a match on its own: moves, cube decisions, luck, a PR per
player. The engine is a separate private Fly app (`oskol-analysis`, repo
`amilner42/oskol-analysis`, Aveline doc `bg-analysis-service`); nothing in a
game or a room talks to it.

- `backgammon/analysis` encodes Oskol's board to the engine's 26-int
  on-roll board and builds one entry per turn (cube relative to the mover,
  away scores, Crawford, dice, the played board). The turns come from
  replaying seed + log through `gamekit/replay`, which folds the typed
  twins of the calls the rehydrator makes, so a review sees exactly what
  the room saw. A double the engine thinks illegal (a dead cube) is folded
  away; a turn cut off by a resignation or a clock keeps only an answered
  double.
- When a step ends a game (`oskol/handlers/reviews.game_ended`), the room
  casts `Oskol.Reviews.Queue`; the queue runs `reviews.run` in a task, one
  room at a time, after the persister has flushed. A game already done or
  queued is not run again; a failure is stored and retried at most twice
  (30 s, then 2 min). **Reading never queues anything**: a game ending and
  an explicit retry from a seat are the only things that spend engine time,
  because a replay page open on a shared link must not be able to put the
  engine to work. The queue scans persisted `analysis_owed` markers at
  boot and every minute; a lost enqueue or crashed worker recovers without
  a reader or a restart. Recovery does not duplicate a running job or skip
  its retry delay. Attempts are charged before engine IO: a crash during
  that IO counts toward the same three-attempt budget. When recovery runs,
  an interrupted final attempt becomes a visible failure. A failed database
  scan logs and tries again. Task crashes, including those before charging
  an attempt, have their own in-memory per-room budget: wait one minute,
  then two, then suspend automatic recovery after
  the third consecutive crash, logging once. The durable owed marker stays;
  a fresh enqueue (game ending or explicit player retry) or queue restart
  reopens the room. While suspended its page may still say pending: the
  operator alert, not a reader, requests intervention. Other rooms continue,
  and a normal task result resets its crash streak.
- **A finished game's answer is written, not rebuilt.** Reading one used to
  replay the room's whole action log and render every graded turn again --
  five seconds and most of a megabyte per call -- and that took production
  down twice on 2026-09-16. The two moments that already do the replay now
  write what they produced: `game_records` (one row per finished game, its
  record entries) when a game ends, and `game_reviews.report` (the rendered
  analysis, exactly what the page reads) when the engine's answer lands.
  Nothing rewrites a row for a game that is over. A room from before this
  builds once on its first read and writes its rows: self-healing, no data
  to migrate. When the report's shape has to change for rows already
  written (once so far: the cube chances, `RerenderCubeReports`), a
  migration nulls `report` on the done rows and the same first-read path
  renders each afresh from the stored `response`, with no engine time.
- Record freshness follows completed-game work, not ordinary actions:
  `games.records_generation` remembers the `analysis_owed_at` marker the
  replay read before its log. Record rows and their exact checkpoint are
  stored atomically, and an older backfill cannot mark a newer completion
  settled or rewind its checkpoint. Legacy rows establish this marker once.
  Index/detail reads fetch record numbers only; moving checkers or playing
  turns in the next game does not cause a new backfill.
- `game_reviews` holds one row per (game_id, game_number): status
  (`pending`, `done`, `failed`), attempts, the engine's response verbatim,
  the rendered `report`, and that game's `turns`. `report` is what
  `oskol/reviews/report.to_json` makes of the response: per turn the grade,
  the move played, the best and the top five with equity lost and each
  candidate's chances (win, gammon and backgammon, both ways), the cube
  verdict with its three equities and the chances it was judged on, and
  luck; per player PR, error, grade and mistake counts and luck. The
  engine grades the cube only where the mover could have doubled (not
  the Crawford game, not the other side's cube), but it grades "no
  double" on the opening roll too; the report drops that one, and guards
  the rest the same way, so a page never shows a verdict on a double
  that could not have been offered. The read path never builds it -- `GET .../reviews` is the index
  alone (game number, status, turn count: a few hundred bytes, from a query
  that touches neither body), and `GET .../reviews/<n>` sends that one
  game's stored `report` verbatim. Statuses: `done`, `pending`, `failed`,
  `empty` (no complete turn).
- `GET .../record` is assembled the same way: the head (players, match
  length, opening position) from starting the room's game and asking nobody
  to play it, plus one `game_records` row per game. It reads the live room
  instead whenever there is one -- that is free, and it carries the game on
  the board, which nothing writes down until it ends. So a replay page on a
  settled cold room wakes no room and replays no log. A missing or stale
  record still uses the existing recovery path until it is settled.
- A **match PR** is the same rows read the other way round:
  `GET /papi/games/:slug/rooms/:id/ratings` answers one entry per seat —
  the plain mean, to one decimal, of that seat's PR in the games of *this
  room* the engine has graded (`src/oskol/handlers/ratings.gleam`, on the
  `analysis.ratings` cap, which selects only the stored response's player
  totals; `report.player_prs` reads their ratings). Seats come from the
  stored setup, so ratings never wake a room or read its action log.
  A game still pending, failed or
  unfinished counts for nothing, and a match with none graded shows no
  number. It is display only, and open like the record; the table prints
  it beside each name and asks again when a game ends. It is deliberately
  *this match* and not a career average: a career one needs a join from a
  seat to a person (`games.players[i].guest_id`), which waits for accounts
  — `bg-career-pr` in Aveline.
- Config `:oskol, :analysis`: prod reads `ANALYSIS_URL` (default
  `http://oskol-analysis.flycast`) and connects over IPv6 (Fly's private
  network; `ANALYSIS_IPV6=false` turns it off). Dev defaults to
  `http://localhost:18082`, IPv4. To point dev at the real engine:
  `fly proxy 18082:80 oskol-analysis.flycast -a oskol-analysis` (stop it
  after), or run it locally in the oskol-analysis checkout:
  `.venv/bin/uvicorn app.main:app --port 18082`. Tests never hit the
  network: the queue is off (`config :oskol, Oskol.Reviews.Queue`) unless
  a test turns it on, and requests go to a `Req.Test` stub.

## Puzzles (backgammon)

Every mistake the engine finds becomes a puzzle: the position, the
question in the game's own words, and the answer. Written once, at the
one moment the board a decision was made *on* exists -- the review job,
with the engine's answer and the game's own turns both in memory. No read
path builds one and nothing re-asks the engine to recover one.

- **Gleam decides.** `src/oskol/puzzles/extract.gleam` says what counts: any
  decision that gave up 0.02 or more (doubtful and worse), checker or cube,
  never a forced play, a dance, or a "no double" where no double could have
  been offered (the replay's own cube rule -- the opening roll, a cube the
  mover does not hold, the Crawford game). The checker play of a turn whose
  double was taken is skipped when its answer predates the engine's fix
  (`bg-analysis-post-take-context`): that engine graded it on the pre-offer
  cube. The fix shipped with `all_results`, so "old" is read off the answer
  itself -- a move without `results` (`extract.before_results`) -- and an
  answer from the fixed engine has every such play asked. Skipped turns are
  still written, as a source with a reason and no puzzle, so the backfill
  can count and re-ask them.
- **A puzzle is public and deduplicated.** `src/oskol/puzzles.gleam` is the
  stored shape: the question is mover-relative (the engine's 26-int board
  from the player on roll's side, the roll high die first, the cube value
  and owner, the away scores, Crawford, Jacoby; a cube question carries no
  dice), the `key` is the sha256 of its canonical one-line form, and the id
  is eight characters of the room-code alphabet read off that same digest.
  A `double` and a `take` are two questions on one position, and both store
  the same three equities -- always the *doubler's* payoff. Whose mistake it
  was is a `puzzle_sources` row, and the seat of a take is the responder's.
  **A stored answer is never rewritten**: a shared link must not change its
  mind, so a change of shape is a migration. The one audited exception: an
  answer that is not `complete` (a column, Gleam's word on it:
  `puzzle.complete` -- every legal result for a checker play, the chances
  for a cube verdict) is replaced by a complete answer to the identical
  question, in `Oskol.Puzzles.store/4`, with `answer_upgraded_at` set. The
  question is the key so it is the same puzzle, the complete answer is a
  superset, and nothing anyone was shown changes: an attempt that was
  "unknown" becomes gradable. A complete answer is never touched.
- **The answer is complete for new puzzles.** The review request asks
  `all_results`, which costs the engine nothing (it evaluates every legal
  play anyway; `top_moves` only truncates what it writes down), so the
  answer holds every legal play's board and cost plus full details for the
  top five and the move played. `complete` is `results` numbering exactly
  `n_legal`, never merely "not empty": a truncated list stored as the whole
  of it would grade a good answer wrong. A review taken before the flag says
  `complete: false`, and an attempt outside its five is honestly unknown.
- **Only the queue writes puzzles.** `settle` takes `Extracting` from the
  queue's job and `ReadOnly` from a read, so a GET anyone with the link can
  make never writes a puzzle, never spends an extraction attempt and cannot
  race the job on the same game. A read still renders an answer it finds
  unrendered, exactly as before, and leaves the puzzles owed.
- **One transaction, one marker.** `puzzles`, `puzzle_sources` and
  `game_reviews.puzzles_extracted_at` land together (`Oskol.Puzzles.store/4`,
  behind the `puzzles` cap). Idempotent: a puzzle is written only where its
  key is new, a source only where its (game, game number, turn, kind) is,
  and a game is extracted only while it is actually owed -- so a migration
  that re-renders reports (`RerenderCubeReports`-style) cannot re-extract
  every done row.
- **Every giving-up path is charged and logged.** A failure **never fails
  the review**, but it always spends one of three `puzzles_attempts` and
  logs why -- including the case Gleam cannot even reach a decision in
  (`puzzles.failed`, for a stored answer that no longer lines up with the
  game's turns). The try that spends the last attempt sets the marker with
  `puzzles_error` beside it, so the minute sweep stops replaying that room.
  Without that, one bad row would have the sweep replaying its whole log
  every minute for ever, silently. A puzzle whose every candidate id is
  taken is skipped with `skipped_reason: "id_exhausted"`, never fatal to
  the rest of the game.
- **Nothing old is owed.** The migration marks every review that already
  existed, because the boot sweep would otherwise backfill all of
  production at deploy, ahead of live games and out of answers written
  before `all_results`. Backfilling old rooms is the operator's
  **`mix oskol.puzzles.backfill`** (`Oskol.Release.puzzles_backfill/1` from
  a release; dry run unless `--write`; `--room`, `--limit`, `--reset`;
  the queue off for the run), the one sanctioned re-ask: every decision in
  `src/oskol/handlers/backfill.gleam`, the walk and the counts in
  `Oskol.Puzzles.Backfill`. It finds an old row by its stored response (a
  turn whose `move` carries no `results`, `backfill.old_contract`), never
  by the marker; asks the engine again at the row's own levels with
  `all_results`, through the same request builder, replay and render a
  fresh review uses; checks the fresh answer before trusting it
  (`backfill.trusted`: a result per legal play, a board on every
  candidate, chances on every cube verdict -- an answer that falls short
  is quarantined: not stored, the row charged to the limit with the reason
  in `error`, named in the counts); then writes the fresh answer and page
  over the old with the game's puzzles reopened in the same transaction
  (`analysis.replace` -> `Reviews.replace/8` + `Puzzles.reopen/2`: marker
  cleared, `post_take_cube` sources dropped -- one write, so the live
  sweep never finds an old answer owed puzzles), and extracts through
  `reviews.extracted`, which writes the new puzzles and upgrades the old
  incomplete ones. An engine failure charges one attempt
  on the `done` row (`analysis.charge`: attempts and `error` only, the page
  untouched) and the run goes on; three spent and the game waits for
  `--reset`. Decks are synced at the end. A second run finds nothing and
  writes nothing. For the same reason, a future path that re-analyses a
  game that is already `done` must clear `puzzles_extracted_at` itself:
  `Reviews.save/8`'s upsert deliberately leaves it alone, which is right
  for the other rewriter (a retry of a `failed` row, which never had
  puzzles).
- **The page never knows a rule.** `GET /papi/puzzles/:id` carries the whole
  turn as a DAG (`src/oskol/puzzles/tree.gleam`): nodes are positions, so
  every order of the same checkers on a double is one node, and a node's
  children are exactly the taps the rulebook allows next (must use both, the
  larger die at the roll). `terminal` is where PLAY is offered and nowhere
  else. Built by memoising "how many dice can still be played" on (board,
  dice left) -- asking `board.sequences` per node would redo the exponential
  walk once per node. A take is turned around before it is shown
  (`handlers/puzzles.shown`): it is stored from the doubler's side and asked
  of the responder, and whoever is being asked is White at the bottom.
- **The tree has a gate.** 100 KB on the wire, 100 ms to build; the build
  gives up at 260 examined positions (61-75 ms; 400 costs 120 ms) and the
  byte budget has the last word. Measured over 4,200 position/roll pairs
  from real random play: median 28 nodes / 9.5 KB / 6.7 ms, p99 350 / 142 KB
  / 173 ms, worst 539 / 220 KB / 728 ms. About one position in forty is over
  the byte budget, all of them small doubles in contact-rich middlegames.
- **A turn too big to send whole is built once and walked.** It answers
  `tree: {root, nodes: {root only}, lazy: true}` (985 bytes on the worst
  position there is) and the page asks for each level from
  `GET /papi/puzzles/:id/tree?node=`. **A node is named by the id that
  build gave it**, never by a description of itself: an id this puzzle does
  not hold is a 404, so nothing a caller sends can put the server to work
  on a position of their choosing, and there is nothing to sign. The tree
  is kept whole (`Oskol.Puzzles.TreeCache`, twenty entries), so a level is
  a lookup -- 14 ms on the contrived worst case, against 548 ms to build it
  the once. The encoded payloads are kept too, per puzzle id, in the same
  bounded table: both are pure functions of a question that is never
  rewritten, so a hit is always right and forgetting costs a rebuild.
- **One grading rule, one place** (`src/oskol/puzzles/grade.gleam`), shared by
  the guest on a shared link and the account whose ladder is watching. A
  checker play is graded by the board it leaves, never its notation: under
  0.02 passes, under 0.08 holds, worse misses, and a board the stored answer
  has no result for is `unknown` -- old five-candidate rows -- so nobody is
  told they were wrong on evidence we do not have. A cube question is answered
  with a side, as at the table (double or not, take or pass); the engine's
  verdict is finer: the doubler's margin is `min(DT, DP) - ND`, the
  responder's is `DP - DT` (positive means take, because the responder picks
  whatever pays the doubler less), bands at 0.08 and 0.02 either side of
  zero. The right side passes, the wrong side misses, and when the engine's
  band is zero (too close to call) either side holds: nobody fails a coin
  flip. The reveal shows the engine's pick among the three equities and the
  chances, nothing more.
- **Every finished game is the moment.** Both result cards at the table --
  the game-over card and the between-games card of a match or of
  unlimited play -- and the replay's ANALYSIS tab offer PRACTICE THIS
  GAME'S N MISTAKES (`practice-game`; "1 MISTAKE"; on the cards a quiet
  "No mistakes in this game" for none) once the game's review is done:
  `Page/Play.elm` asks `/puzzles?game=n` for each game `/ratings` lists
  as graded, for a seat only (a spectator would be told 404), and the
  replay asks for the game being read as it switches; both keep the ids
  and hand them to Main as `StartRun`. The puzzles are written a moment
  after the grade, so the endpoint answers 409 `puzzles_pending` until
  they are, and the page asks again (3 s apart, twenty times at most).
  The run ends on the puzzle page's own screen, a guest's sign-in going
  back to the table (or the replay) it was pressed at. The between-games
  card also makes the save offer, so unlimited play -- most games here --
  asks a guest to sign in after every game, not only at a match's end.
- **One scheduled answer per opportunity.** A signed-in caller whose deck
  holds the puzzle writes a `puzzle_attempts` row first, keyed by the id the
  client minted; the ladder moves only when that row is new *and* the card is
  due. A review always pushes the due date out, so a second tab or a retry
  reveals and changes nothing. A miss is `Again` (back to level 0, tomorrow);
  an `unknown` schedules nothing and defers the card to tomorrow with
  `self_grade: true`.
  **Whether an answer counts is read-then-act**, so the whole decision --
  writing the attempt row, reading the card, moving it -- runs under a
  transaction-scoped advisory lock on (account, puzzle)
  (`Oskol.Puzzles.serialize/3`). Without it four tabs at one due card wrote
  four reviews and took a level-0 card to level 4.
  **An idempotency key means something only inside one account**: the unique
  index is (puzzle_id, user_id, idempotency_key) and every read is scoped
  the same way, or somebody else's key would reach their row.
  The override (`.../attempts/:key/outcome`) **replaces** the review it named
  rather than stacking on it, so a pass then SOONER lands at level 0 once.
  Where there was no review it writes the first one, but only where the
  answer actually offered that (`self_grade`) -- never merely because none
  was written, or an answer that never had an opportunity would invent one.
  GOT IT on an answer nothing checked holds the level rather than raising
  it. NEVER suspends the card without touching the attempt's own schedule,
  so a retry of that answer is still the same reply, and nothing can be
  overridden after it (409).
- **Share with my mistake** (`src/oskol/handlers/shares.gleam`). After the
  reveal, the seat that made the mistake -- and only it: the source's own
  `player_id`, held by the holder rule, so a guest by its cookie and an
  account from any browser it is signed in on, never the opponent, never a
  stranger (403, one sentence) -- may `POST /papi/puzzles/:id/shares` and
  get a story link, `/puzzles/:id?s=<token>`. The row is `puzzle_shares`:
  a twelve-character token of the room-code alphabet (`ids.share_token`,
  two game codes), the puzzle, the source, `shared_by` (the account id for
  an owned seat, the guest id for an unowned one) and `shared_name`, the
  sharer's display name **frozen at the mint** (a rename or a seat taken
  over must not change who the story names). One row per (source,
  sharer): `Oskol.Puzzles.mint_share/5` inserts against that unique index
  `on_conflict: :nothing` and reads back the token that stands, so two
  tabs pressing together get one link. The token is nothing but a token:
  `?s=` changes the head's title (`shares.headline`: "Arie got this wrong.
  What's your play?" / "Double?" / "Take?") and puts `story` on the
  reader's own attempt's answer (`shares.story_json`, with `line`: "Arie
  played 24/23 13/11 (a bad move) and lost 2 points." -- a cube source
  reads "didn't double" / "doubled" / "took" / "passed", "a bad
  decision"); the GET, the picture and the canonical ignore it, and a
  token nobody minted or minted for another puzzle is silently the plain
  page. The page (`Page/Puzzle.elm`) shows the second button only when
  `/mine` answered `who: "you"`, sends `s` on the attempt, and renders
  `story.line` under the memory line. The result comes from the game's
  record (`puzzles/game_over`, the same reading the memory line uses).
  `puzzle_images` is the board picture, below.
- **A puzzle has a picture, drawn once, never on a request.**
  `src/oskol/puzzles/picture.gleam` draws the position as SVG, 1200 x 630,
  in the default theme's colours (`.bg-theme-midnight`, as constants), from
  the solver's side exactly as `prompt` speaks (a take is `flip`ped, cube
  owner and scores with it): the board with the mover as White at the
  bottom, stacks with a count over five, bar and trays, the dice for a
  move, the cube at its owner's side, the score line, the prompt. Text is
  SVG text in a system font stack; nothing loads. `Oskol.Puzzles.Pictures`
  rasterises it with `rsvg-convert` (`config :oskol, :rsvg`; the release
  image installs `librsvg2-bin` and `fonts-dejavu-core`; the SVG rides in
  as an environment string through `sh` because a port cannot close stdin
  alone) and stores the PNG in `puzzle_images` (about 90 KB: cairo's PNG
  writer, no compression flag). Drawn in the review job right after
  `store` succeeds (`puzzles.pictures` cap, `render_game/2`) and by the
  queue's minute sweep for whatever that missed (`render_owed/1`, a
  `:pictures` job, twenty a batch). Every try is charged to
  `puzzle_images.attempts` first; the third failure writes `error` and the
  sweep lets the row go until `Pictures.reset_attempts/0`. A missing
  binary is logged and charged to nobody, so a deploy without it cannot
  burn every puzzle's budget. `GET /puzzles/:id.png`
  (`OskolWeb.Plugs.PuzzlePicture`, an endpoint plug beside `Plug.Static`:
  no session, no guest cookie, no router -- and the router's grammar has
  no `:id.png`) serves the row `public, max-age=31536000, immutable` with
  an ETag, or the site's board (`priv/static/images/puzzle-board.png`,
  committed, regenerated by `Pictures.write_default!/0`) at `max-age=300`
  while a puzzle has none; an id that names no puzzle is a 404; `?s=` is
  ignored. The root layout's `<.share_card image={assigns[:puzzle_image]}>`
  emits `og:image`, its width and height, `twitter:card`
  `summary_large_image` and `twitter:image` when a page sets
  `:puzzle_image` to the picture's absolute URL, and byte for byte the old
  `summary` tag when it does not. Tests stub the binary
  (`test_support/fake_rsvg_convert`) and run the real one only when the
  machine has it.
- Measured on the seeded match 821900 (12 games): 125 puzzles, 127 sources
  (103 move, 19 double, 3 take; 2 skipped post-take), mean stored row 1.7 KB.
  With every legal result the answer column goes from a mean of 2.4 KB to
  4.2 KB (max 17 KB, a 177-play double).

**The deck fills itself.** An account's mistakes become cards in its deck
with nobody pressing anything: `src/oskol/practice/sync.gleam` (`sync_deck`)
reads the sources on the seats that account owns and no deck holds yet,
enrols them (`deck.enroll` -> retain, tags `{deck: "mistakes", kind}`,
content the stored question, position newest game first) and stamps
`puzzle_sources.deck_synced_at`. The holder rule decides whose a mistake is,
as everywhere: the query narrows by an id, `rooms/seat.holder` answers.
Three callers, all off every hot path: the review job, where a game's
`store` has just succeeded (`sync_game`, in `handlers/reviews`); the sign-in
stamp, cast to the review queue from the **persister's own handler** once
its transaction has committed, so a caller that already timed out
(`stamp_seats/3` answers `:pending`) still leaves a full deck; and the
queue's minute sweep, for anything the first two missed.
`mix oskol.puzzles.sync` is that sweep by hand (dry run unless `--write`,
which writes nothing and charges nothing; `--reset` reopens the rows that
gave up; `Oskol.Release.puzzles_sync/1` is the release twin, and both turn
the queue off first so the boot sweep does not charge the same rows beside
them). A deck job is `{:deck, user_id}` in the same queue as a room's
review, collapsible because it syncs everything that account is owed, and
the minute scan runs in a task rather than in the queue process.

**Bounded, and never silent.** Idempotent at both levels; reading an
account's sources charges one of three `deck_attempts`; and a try that
fails — *including* retain raising, which is the failure that actually
happens — writes `deck_error` on the rows and leaves them out of the sweep
until an operator reopens them. A `DeckUnavailable` refusal is how an
exception crosses the cap boundary instead of being logged and lost.

**What the queries are keyed on.** `puzzle_sources.owner_user_id` is the
account whose seat made the mistake, written from `games.players[seat]` in
the same transaction as the sources and again when a sign-in stamps that
game's seats (`Oskol.Puzzles.refresh_owners/1`). It is an index key, never
an authority: `seat.holder` still decides, in Gleam, of every row handed
back. Without it the sweep's question is a lateral join over every unsynced
row every minute, and since a guest's mistakes are never synced that set
grows for ever. `ended_ms` is the game's **review row**, not the source's:
newest game played first, so a backfill or a retried review cannot put an
old game at the front; within one game, turn order. A card's position is
seconds *back* from 2020, not negated Unix time: retain's `position` is a
32-bit column.

**A mistake you make again comes back.** When a sync finds a puzzle the
deck already holds, that is the player making it again in a real game, so
the card takes an `:again` (back to level 0) with a note saying which game
— but only a card **in rotation**: one never shown is already at the front
of the queue, and a suspended one the player said NEVER to, which a game
they happened to play must not undo.

**`GET /papi/practice`** is one page for three callers
(`src/oskol/handlers/practice.gleam`). Signed in: the deck, everything due
before anything new (`new: :after_reviews`), twenty at a time, and
`counts: {due, new_today, deck}`. A guest: the mistakes on the seats their
cookie holds and no account owns, newest game first, unscheduled,
`counts: null`, and **nothing written** -- only an account has a deck.
Nobody: an empty list, not an error. Reading never starts a card or spends a
day's budget. `POST /papi/practice/more` is KEEP GOING: ten more into
rotation over the day's budget, then the same session.

**A session is never paged.** Every fetch is the front of the queue and
`cursor` is always null. The due set is live -- answering a card takes it
out -- so a second page at an offset would skip exactly as many cards as the
player had just answered: 21 due would end after 20 with one unseen and the
day's new cards never offered at all. "Done for today" is a fetch that comes
back empty, and nothing else.
**The page** (`/puzzles/:id`, `assets/src/Page/Puzzle.elm`) fetches the
question and nothing else until PLAY: the answer is not in that response,
and `/mine` is asked only after the attempt, so a page open on a shared
link can put nothing within reach. The board is the table's own
(`Games/Backgammon/Puzzle.elm` on `View.viewPlay`; a lazy tree's levels
are fetched as the path reaches them), UNDO and PLAY are its own band; a
cube question is two buttons, as at the table (DOUBLE / NO DOUBLE, TAKE /
PASS). The reveal is
the replay's words and table
(`Words`, with `doubleWhy`/`noDoubleWhy`/`answerWhy` for a position nobody
has acted on yet) with "you" marked and a candidate tappable onto the
board; the cube's scale marks the engine's band over `cubeLine`. The
attempt's key is minted once per page load (`elm/random`) and a PLAY that
lands before it waits for it, so a retry is the same answer. Signed in
with a `schedule`, the level line ("Level 2 → 3 · back in 7 days"; "back
tomorrow") and SOONER / GOT IT / KNEW IT / NEVER, the graded one
preselected when `amendable` (SOONER after a miss, GOT IT otherwise),
none when `self_grade`, absent when neither; NEVER says the card is out
of the deck. SHARE is the table's `shareInvite` port on the clean URL.
NEXT is the shell's: `Main.run` (`{ids, at, verdicts}`) is the practice
run, kept across `pushUrl`s because every page is rebuilt on one; the
page is told `hasNext` (true anywhere in a run: the next puzzle, or the
run's end) and answers `WantsNext`, and Main pushes the next id.

**The home and a run** (`/puzzles`, `assets/src/Page/Puzzles.elm`; PUZZLES
on the home menu where TACTICS / SOON was, ANALYSIS / SOON stays). One
page on `GET /papi/practice`'s one answer: an account with a deck reads
"12 due · 4 new today · 231 in your deck" and PRACTICE, or, with nothing
due and nothing new, "Done for today", "4 new tomorrow · 231 in your
deck" and KEEP GOING (`POST /papi/practice/more`, then the session it
answers is the run); a guest with games reads "23 mistakes from your 4
games", that progress is not saved, and the same PRACTICE; a stranger
(and an account whose deck is empty) two lines on what this is and TRY
ONE (`GET /papi/puzzles/random`, a 404's sentence shown under the button
while the pool has none). A quiet "Sign in" line opens `Ui.SignIn`
(next `/puzzles`) for whoever wants it before the run asks. Signed in,
the page POSTs the browser's zone
(`Intl.DateTimeFormat().resolvedOptions().timeZone`, a boot flag `tz`) to
`/papi/practice/tz` once per visit, and never for a guest.

A page that starts a run answers `Out = StartRun (List String)`: Main
sets `run = {ids, at = 0, verdicts = [], next}` and pushes the first id.
`next` is the page the run was started from (the practice home, the
table, the replay), and is where a guest who signs in at the run's end
goes on to. The puzzle page
reports every reveal (`Out = Answered Verdict`); Main keeps it on the run
by puzzle id (an answer given again replaces, never counts twice). At the
last id `WantsNext` is answered with the score (`Page.Puzzle.endRun
{right, close, total}`: a pass is right, a hold close, a miss or an
unknown neither; the total is the run's length) and the page ends the run
on its own card, the board gone: "7 of 10 right" (and "2 close"), then
for an account a refetch of `/papi/practice` -- empty is "Done for today.
4 new tomorrow." (just "Done for today." when tomorrow brings none) and
KEEP GOING, which runs what it brought or says the deck has nothing more
to start; more due is "N more to go." and CONTINUE -- and for a guest
"Sign in and we'll keep this: these come back until you stop making
them." over `Ui.SignIn` (next `/puzzles`; the stamp and the deck sync are
the server's, and CONTINUE lands on the home with a deck). The page's
other `Out`s for this: `StartRun`, `SignedIn (Maybe User)`, `Go path`.
Decisions on the server: `handlers/practice` (counts, a guest's
`mistakes`) and `handlers/puzzles_hub` (TRY ONE's clear-answer rule, on
the `puzzles.sample` cap: up to 40 complete puzzles in the database's
random order, the first that qualifies).

`POST /papi/practice/tz {tz}` writes the browser's zone onto the deck itself
(no new column: retain already keeps a learner's timezone, and it is the
only thing that reads one). Gleam checks the shape, the zone database checks
the name; `Etc/UTC` until it is set, and filling a deck passes no zone so it
can never undo one. `POST /papi/practice/bury {id}` puts a puzzle the
session left ungraded back to the start of the player's tomorrow, level kept
-- 409 when it is not in rotation, which is what `error.Conflict` is for.

## Mail

One mailer (`Oskol.Mailer`, Swoosh over Req) and one mail
(`Oskol.Mail.send_login/3`: the sign-in link, the same sign-in as a
six-digit code, "Both work for 15 minutes"). Prod: `Swoosh.Adapters.Postmark`
on `POSTMARK_TOKEN`, From `POSTMARK_FROM` (default `hello@oskol.io`, sender
name Oskol) on the `POSTMARK_STREAM` message stream (default `outbound`).
Dev: `Swoosh.Adapters.Local` — **read what would have been sent at
`/dev/mailbox`** and click the link out of it; the link and code are logged
too, and `GET /dev/last-login` answers `{link, code, email}` for a browser
test. Both dev routes exist only under `:dev_routes`. Tests:
`Swoosh.Adapters.Test`, read with `assert_receive {:email, mail}`; nothing
ever leaves the process.

## Adding a game
Backgammon is the product and the only game registered, but the framework
still takes another one:
1. Create `src/<slug>/game.gleam` implementing `gamekit/game.Game`. Give
   `Info` its formats, the clock presets it offers, and a `timeout` policy.
2. Register it in `src/gamekit/registry.gleam` (`all()`).
3. Add `test/<slug>/conformance_test.gleam` using `gamekit/conformance`
   (random playouts to termination, replay determinism, your invariants),
   then `mix oskol.fixtures` so the golden and Elm suites cover it.
4. Its formats show up on the create page. It needs an Elm view in
   `assets/src/Games/<Name>/View.elm`, dispatched by slug in
   `Page/Play.elm`; the view reads the protocol Scene, never new wire types
   (see `assets/src/Games/Backgammon/View.elm`). There is no generic
   renderer any more (it went with go); the repository history has one to
   start from.
5. Pick a slug that is not one of the removed games' (`poker`, `go`,
   `chess`): the router sends those home before any game route sees them.

## Development commands

```bash
bin/check             # what you run while you work (~2 min): compile, Gleam,
                      # Elm, Elixir, without the handful tagged `slow`
bin/check --all       # the same with the slow tests (~3.5 min). What CI runs.
bin/check --browser   # --all, then the Playwright smokes
                      # (PORT picks the port it serves them on; 4400 by default)
mix deps.get          # Elixir + Gleam deps
mix compile           # compiles Gleam (via mix_gleam) and Elixir
bin/test-gleam        # Gleam unit, rules, oracle, property, hidden-info and golden
                      # tests, run one worker per core (test/oskol_runner.erl)
mix oskol.fixtures    # regenerate fixtures: `replays` (committed) and/or `payloads` (derived)
mix test              # Elixir room, bots, channel, controller tests, minus the
                      # `slow` ones; mix test --include slow runs everything
cd assets && ../node_modules/.bin/elm make src/Main.elm --output=/dev/null   # Elm typecheck
cd assets && ../node_modules/.bin/elm-test --compiler ../node_modules/.bin/elm  # Elm tests (needs `mix oskol.fixtures payloads`)
mix assets.build      # Elm (via esbuild plugin) + Tailwind
mix phx.server        # http://localhost:4400 (4000 belongs to other apps on this machine)
                      # OSKOL_DEV_DATABASE names another dev database (a branch trying an
                      # operator task on seeded rooms, beside the main checkout's oskol_dev)
mix oskol.seed        # local backgammon rooms at codes 000001.. parked in positions worth
                      # testing (bar, bearing off, a dance, cube decisions), P1 and P2 seated
                      # but held by nobody, P1 to act; prints each room's invite link, and
                      # the browser that takes a seat from it holds it (lib/oskol/dev/seeds.ex);
                      # two players means two browsers (a private window will do);
                      # 000010 is a single game played to the end, with a review
                      # (start the fly proxy first, or the review fails and waits);
                      # 000011 a match to 3 played to the end: its replay is
                      # /backgammon/000011/replay; 000013 is the accounts
                      # walkthrough: P1 belongs to ari@oskol.test (sign in as
                      # it from /dev/mailbox to play P1), P2 is free
node playwright/test-accounts/test.js           # signing in: the code from LIVE GAMES, the
                                               # link (asks first), an owned seat nobody
                                               # can claim, log out; mail read from
                                               # /dev/last-login; phone screenshots
node playwright/test-backgammon-smoke/test.js   # backgammon: stage, undo, play, with a clock
node playwright/test-backgammon-dance/test.js   # backgammon: a danced turn (it arranges the
                                               # room itself), the roll animation, the delay
node playwright/test-backgammon-landscape/test.js  # backgammon on a sideways phone: the board
                                               # fits the screen height exactly, nothing scrolls
node playwright/test-backgammon-replay/test.js  # the replay of a finished match (it arranges
                                               # the room): steps, keys, swipes, analysis
                                               # pending -> done, retry, phones; the analysis
                                               # is stubbed unless REPLAY_REAL=1
node playwright/test-puzzle/test.js             # a puzzle from a link: setup.exs arranges a game,
                                               # grades it against a Req.Test engine in its own VM
                                               # (real legal plays, the played one a mistake) and
                                               # extracts; a stranger, the opponent (memory line)
                                               # and the mistake's own player signed in (level
                                               # line, SOONER) play it; phones; the board is the
                                               # table's size
node playwright/review-puzzle/test.js           # screenshots of the puzzle page: question, staged,
                                               # reveal, a candidate, the cube scale (phone, small,
                                               # landscape, desktop)
node playwright/test-puzzles-hub/test.js        # the practice home and a run: setup.exs's game, the
                                               # first seat trimmed to 12 mistakes; a stranger's TRY
                                               # ONE, a guest's run of 12 to the score and the sign-in
                                               # ask, sign in there, the account's counts and its
                                               # timezone sent once, a run of 10 to "Done for today.
                                               # 2 new tomorrow.", KEEP GOING's 2; phones
node playwright/review-puzzles-hub/test.js      # screenshots of the practice home (stranger, guest,
                                               # account, done for today) and both end screens
node playwright/test-spa-landing/test.js        # the home board and CREATE GAME's dialog, old
                                               # links redirect, a full create -> play click-through
node playwright/review-pages/test.js            # screenshots of the home board, CREATE GAME,
                                               # the lobby and the theme picker (desktop + phone)
node playwright/review-games/test.js            # screenshots of games in play (desktop + phone)
node playwright/review-replay-mobile/test.js    # screenshots of the replay's MOVE, ANALYSIS and
                                               # MOVES tabs on two phones, sideways, and a desktop
```

CI (`.github/workflows/ci.yml`) runs the same steps as `bin/check --browser`:
two jobs side by side, the suites (compile, Gleam, Elm, Elixir, formatting)
and the Playwright smokes (one server, in `bin/check`'s order), green when
both are. It runs on pull requests and on pushes to main, once per commit;
a newer push to a branch cancels the run it supersedes, a push to main is
never cancelled.

**Speed is a feature of the suite.** A check nobody runs is worse than a slow
one, so keep it under about two minutes: the Gleam tests run one worker per
core (`test/oskol_runner.erl`, replacing gleeunit's one-at-a-time list),
tooling that walks a game asks the host for `legal` rather than rendering a
whole update per step, and the few tests whose cost is waiting -- whole
matches played at random, clocks that must run out, retry backoffs -- are
tagged `@tag :slow` and left to CI. When a new test takes seconds, ask
whether it is waiting or working: waiting is tagged, working is parallel.

Notes:
- mix and the gleam CLI share `build/`. `mix compile` removes the
  `gleam@@compile.erl` escript gleam leaves behind (see
  `Mix.Tasks.Compile.GleamClean` in mix.exs), and `bin/test-gleam` clears our
  package's gleam build output so the gleam CLI recompiles it with beams after
  mix has touched it. Use `bin/test-gleam`, not bare `gleam test`.
- Elixir test support lives in `test_support/`, not `test/support/`, because
  gleam compiles any `.ex` it finds under `test/`. `test/oskol_test_files.erl`
  is the one Erlang file under `test/`: file access for the golden tests.
  `src/oskol_json_ffi.erl` is the one under `src/`: gleam_json's Json is
  iodata on Erlang, so stored JSON text is already a Json value.
- The gleam compile step forwards positional args to deps tasks. `mix test`
  is aliased to compile first and then run with `--no-compile` so
  `mix test path/to/file.exs` works; for scripts use
  `mix run -e 'Code.eval_file("path")'`.
- In this environment the Elm package cache is populated by git clone
  (GitHub zipballs are blocked); see `.claude/skills`.
- The pixel font (Press Start 2P) and the landing sans (IBM Plex Sans) are
  self-hosted under `priv/static/fonts`; nothing loads a font from a CDN.
- Playwright scripts take the browser from `PW_CHROMIUM` when set (`bin/check`
  falls back to a preinstalled Chromium under `/opt/pw-browsers`); CI runs
  `npx playwright install chromium` instead.

## Development workflow for Claude
- Work is tracked in Aveline, not here: `aveline -w oskol get-orientation`
  is the loop (ticket, branch, PR, adversarial review, CI, merge, deploy,
  worklog). This file is the code truth that loop points back to.
- Do not leave servers running. For a browser check, run the server and the
  Playwright script in one bounded foreground command, then stop it.
- Verify with `bin/check` before reporting.
- Keep game logic in Gleam. Keep UI state in Elm. Keep Elixir game-agnostic.
- Text rendering: `Oskol.GameKit.text(instance, player_id)` (or
  `gamekit/host.text`) shows a game as text with the legal actions, so you can
  play a game from a script without a browser.
- Rooms can be set up with a `seed:` (`Game.configure/2`) for reproducible
  games in tests and screenshots.

## Testing: one layer at a time, and the seams between them

Every game is its seed plus its action log, and the suite leans on that.

**Gleam (`bin/test-gleam`)**
- Rules in controlled positions: `test/backgammon/rules_test.gleam` and `cube_test.gleam`
  build boards to assert dice order, bar entry, bearing off, hits, gammons,
  doubling, Crawford, Jacoby, resigning.
- `test/backgammon/oracle_test.gleam`: an independent move generator,
  written from the rulebook on raw checker data, checked against
  `board.sequences` on hundreds of random boards (`positions.gleam` builds
  them) plus named positions with the expected sequences spelled out.
- `test/backgammon/properties_test.gleam`: staged-turn invariants over random
  positions (undo is an exact inverse, a legal first move never strands a
  die, pip accounting, commit) and a no-leak property over random games.
- Conformance (`test/backgammon/engine_test.gleam`): seeded playouts to
  game over with the game's invariants, replay determinism, malformed
  actions rejected. Random play excludes `resign` (`conformance.Options`).
- Golden replays (`test/gamekit/golden_test.gleam`): every file in
  `test/fixtures/replays` replays to its recorded fingerprint, and every
  registered format has one. A rules change fails here; when intended, run
  `mix oskol.fixtures replays` and read the diff.
- Framework units: rng, clocks (including the turn delay), action decoding
  and validation, `event.for_viewer`, host/protocol shapes.
- `test/backgammon/analysis_test.gleam`: the engine board in controlled
  positions, the cube and match state per turn, scripted logs (doubles,
  drops, resigns, timeouts), and the property that every
  played board is legal for its dice under an independent generator on the
  engine's own format; `test/oskol/reviews_handler_test.gleam`: when a
  review is owed, retries, and the page's shape, on stub caps.

**Fixtures (`mix oskol.fixtures`)** come from `gamekit/fixture`: replays are
small and committed; payload captures (every update every viewer received
for the first steps of a playout) are derived, gitignored, and embedded in
`assets/tests/Fixtures.elm` for elm-test. `oskol/puzzles/fixture` does the
same for the puzzle wire: `PuzzleApiFixtures.elm` (the question, per kind)
and `PuzzleRevealFixtures.elm` (an attempt's answer per verdict, from
`handlers/puzzles.attempt_body`, and the three schedule shapes).

**Elm (`elm-test`)**
- `ProtocolTest`: every fixture payload decodes; cross-checks that hold for
  any game (viewer matches seat, spectators have no legal actions, select
  candidates exist in their zone, ids unique per zone, events only name
  tokens the viewer can see).
- `BackgammonViewTest`: the view on real scenes, pure update logic, and
  rendered DOM facts (30 checkers, sources marked only for legal moves,
  buttons follow the legal actions).
- `PlayUpdateTest`: fixture payloads replayed through `Page.Play.applyPayload`.
- `RouteTest`, `SessionTest`, `CatalogTest`: the client's routes round-trip,
  the boot flags, and the `/papi` envelope and decoders (which are lax about
  keys they do not need and strict about the ones they do).
- `GameLandingTest`: the home page on decoded responses — the board and its
  four menu entries, CREATE GAME's dialog (the mode and clock dropdowns,
  their defaults, the summary, inline validation), the theme picker, and
  the invite's three answers.
- `PuzzlePageTest`: the page on the generated fixtures: the reveal decodes
  (a fifth verdict word fails it), a tap walks and UNDO walks back, a lazy
  node is fetched and merged, PLAY posts exactly the path with the key (and
  waits for the key), the verdict and "you" in the table, the cube scale
  with the engine's band, the level line in its three states and after an
  override, NEXT only from the shell, the memory line on 200 and not on 404;
  the end of a run: every verdict reported, the score card for a guest (the
  sign-in, going on to `/puzzles`) and for an account (done for today, KEEP
  GOING and CONTINUE start what the deck answers).
- `PuzzlesHubTest`: the practice home on the wire's three answers (the
  counts line, a guest's mistakes line, a stranger's TRY ONE and the empty
  pool's sentence), PRACTICE and KEEP GOING as `StartRun`, and a decoder
  that refuses a malformed count rather than defaulting it.
- `ReplayTest`: the replay on the real record and analysis of seed 000011
  (`ReplayFixtures`): decoders, the board at every step, stepping, keys,
  swipes, game switching, and the analysis filling in without moving the
  viewer; polling only while something is pending.
- `WordsTest`: the verdict sentences where they are written, on made-up
  verdicts -- every move grade with its gains and costs, every cube call
  from both sides of the cube, the too-good rule the Gleam twin shares,
  and the engine's three words read into `Optimal` (a fourth falls back
  rather than being guessed at).

**Elixir (`mix test`)**
- `test/oskol/room_test.exs`: `Oskol.Bots` (test_support) plays random
  legal actions through the room for every registered game and format,
  many rooms concurrently; disconnect, rejoin, rematch keeps the setup.
  Channel tests cover join replies, spectators, per-player payloads, and
  reconnects; `spa_controller_test.exs` covers what is still the server's on
  the two landing routes — the shell, the head a crawler reads, the 404 for a
  slug that names no game, the removed games' redirects, and the guest
  cookie and the name it remembers.

**Browser (`bin/check --browser`)**: Playwright smokes create real games and
play them; review scripts take screenshots for eyeballing. The ways into a
game live once, in `playwright/lib/flows.js`: `createGame` (`/` -> CREATE
GAME -> the dialog, by element id), `joinByLink`, `joinByCode` and
`openSeat`, and `seatedContext` for a browser that already holds a seat. A
smoke uses those rather than clicking through the home page itself, so a
change to the home page or the invite touches that one file. Two players
are two browser contexts: a seat is held by the browser's guest cookie, so
two pages of one context are one player.

When you add a rule, add a controlled-position test before the playouts:
the playouts prove nothing crashes, the position tests prove the rule is
right. A registered game's conformance test plus `mix oskol.fixtures` give
it golden replays and Elm contract coverage for free.

## Known patterns to avoid
- Don't add per-game code to Elixir or to `Protocol.elm`.
- Don't put animation or wizard state in a Gleam engine.
- Don't call system randomness in a game.
- Don't add emojis or files unless asked.

## Persistence

Games survive deploys and machine sleep. Every room writes behind (never
blocking play) to Postgres via `Oskol.Game.Persister`: a `games` row (code,
setup, seed, seats with the guest holding each, status, winners, and
`state`: where the game stands as of its last step) and one `game_actions`
row per state-mutating step — player actions and clock expiries alike, each
with its millisecond offset from the instance's start. A lookup that finds no
live process replays seed + log through the same gamekit calls at those
offsets (timeline shifted to "now", so downtime charges nobody) and the room
carries on; the guest holding each seat round-trips, so every player's
browser still holds its seat. The
hour-idle shutdown is therefore graceful.

**`games.state` mirrors the game.** With every step the room also writes
`gamekit/host.summary_json`: `to_act` (whose turn it is by the game's own
account, `Game.clocks` with or without a clock set: the mover, never
"anyone with a legal action", since a waiting backgammon player may always
resign), `on_clock` (whose clock is actually running), `outcome`, `phase`
the spectator scene's per-player counters and flags (score, pips,
to_move...), each seat's `clocks` as of that step, and `at`, the wall-clock
moment the clocks were read (added Elixir-side), which is what a reader
charges a running clock from: the row's `updated_at` moves for a seat
claim and not for a wake. It is game-agnostic and carries nothing hidden. It is what
lets active games be listed and watched from the database without waking
a room; a row from before it existed is null until its room next
rehydrates, which writes it. It is a snapshot, not a source: the log is
still what a room is rebuilt from.

Dev/test use local databases
(`oskol_dev`/`oskol_test`, created by `mix ecto.setup` / the `mix test`
alias); prod reads `DATABASE_URL` (Fly Managed Postgres via pgbouncer, so
postgrex runs with `prepare: :unnamed`) and migrates on boot. A room's raw
`control:` (tests only) does not persist; real rooms use clock preset ids,
which do.

Seats once carried a secret token in `games.players`; they carry the guest
id instead, and the data migration `DropSeatTokens` strips the dead key. A
row that still has one (a room live in another node at the time) rebuilds
fine: nothing reads it.

A rules change that makes old logs stop replaying needs those logs patched,
because a room is rebuilt from its log under today's rules. The one so far:
the between-games READY. `Oskol.Game.ReadyUpPatch` inserts the `ready`
steps old backgammon match logs lack (at the time of the game's end); the
data migration `PatchReadyUpLogs` ran it
once at boot, before any room could rehydrate, and `mix
oskol.patch_ready_up` / `Oskol.Release.patch_ready_up/1` show what it does
(dry run unless told to write).

Every visitor silently becomes a guest: `OskolWeb.Plugs.GuestId` mints an
opaque crypto-random id into a year-long HttpOnly cookie (renewed on every
visit) and mirrors it into the session, so LiveView mounts see it on the
static render. `Oskol.Guests` touches the guest's row on mount and remembers
the last display name they played under (last writer wins); that name
prefills the create and join forms, and each seat in `games.players` records
the guest id. The same row carries `prefs` (jsonb): display preferences that
follow the guest between browsers, written through `/papi/me/prefs` and
whitelisted in `src/oskol/guests/prefs.gleam`. A guest who signs in gets
`guests.user_id` (indexed, read once per request by `CtxBuilder` into
`Session(guest_id, user_id)`, and once per socket connect, where the
channel hands it to the room with the guest); logging out
nilifies it and drops that browser's sockets (`UserSocket.id/1` is
`"guest:<guest id>"`), so a tab at a table the account owns is disconnected
and refused when it tries to come back. The id is also the credential:
a seat is held by the guest that took it (or by the account that owns it),
the game channel attaches on it
(the socket reads it off the session that the websocket's own upgrade request
carried, which Phoenix hands over only against the page's `_csrf_token`), and
losing the cookie loses the seats it was holding — they can be claimed back
from the invite link, like anyone else's.

**Signing in is the win after the value, never a gate.** It is offered
where a player already has something to keep — under LIVE GAMES on the
home board ("Save these 3 games"), on the table's result cards, the
game-over card and the between-games card of a match or of unlimited play
alike ("Save this game and your PR"; between games the open sign-in is a
sheet over the board, so READY stays in the band), at the end of a
practice run, under an invite whose seat belongs to an account
— always the one component, `Ui.SignIn`, in the same words, and never
more than a line until pressed; a guest who ignores it loses nothing and
plays exactly as before. Signed in, the home bar shows the account with
LOG OUT behind it.

**An account shows up by its username, never its email.** `users.name`
is citext and unique (`UniqueUsernames`). A new account is named at its
first sign-in (`handlers/auth.named`, on the rule `guests/username.candidates`):
the name the browser last played under as a guest, else that with a number
(`arie1`, `arie2`...), else `player1`, `player2`...; the win says "You'll
show up as arie1 · Change" (`Ui.Username`, `POST /papi/me/name`). A
signed-in browser is never asked for a name: CREATE GAME and the invite's
join form show "Playing as arie1", and the server seats it under the
username whatever it is sent (`landing.seat_name`). Wherever a name is shown
(the home bar, both player bars at the table, the replay) a badge says
guest or account (`Ui.Identity`): the channel's seat list carries
`account: true|false` per seat and the record carries `accounts` (player
ids), a yes or no only, never which account. **A seat points at the
account, it does not copy its name.** `games.players[i].name` stays the
name typed at the door; where the seat has a `user_id`, what everyone
sees is `users.name` — resolved as rows are read
(`Persistence.display_names/1`, behind the rooms and records caps, and
`names` in the record) and held in the live room's memory
(`connection.username`, filled on join, claim, rematch, rehydrate and the
sign-in stamp; `GameServerState.display_name/1`). So a rename is one row:
`POST /papi/me/name` writes `users.name`, tells the live rooms holding
that account's seats (`GameServer.rename/3`, nothing persisted), and every
game past and present shows the new name at once. A guest's home bar has the
same caret as an account's, with SIGN IN behind it.

**Accounts** are `users` (uuid id, `email` citext unique, `name` citext
unique, `last_login_at`) and `login_tokens` (a sign-in in flight: `email`,
`token_hash`, `code_hash`, the `guest_id` that asked, `next`, `expires_at`,
`consumed_at`, `attempts`), both `Oskol.Auth`. An account is an email
address and nothing else — no password, so nothing to reset or leak.

**A seat can be owned.** Each entry in `games.players` is `{id, name,
guest_id, user_id}`, and `user_id` is the account it belongs to (absent on
a row written before accounts: that seat is simply unowned). Who may open
it is one rule, in Gleam — `src/oskol/rooms/seat.gleam`'s `holder`: an
owned seat answers to its account and ignores the guest on it, an unowned
one answers to its guest. Every door asks it (`GameServerState.find_player_id_for/2`,
which the channel's attach, a claim, the record's viewer and `/papi/me/games`
all go through), and `claimable` is false for an owned seat, so no room code
opens one. The owner rides through the room's memory, `players_json`,
`restore_seats` and `seed_seat`, so a rehydrate and a rematch both keep it.

**The stamp.** Signing in hands the account every seat its browser's guest
holds that nobody owns (`Oskol.Auth.adopt_seats/3`, run through
`Oskol.Game.Persister.stamp_seats/3` so it lands *behind* everything the
rooms have queued and cannot race a room rewriting its seats). In the same
transaction the browser's guest row and those seats move to a **fresh guest
id**, which the sign-in response sets as the cookie: the id the browser
arrived with opens nothing afterwards. Rooms that are live are then told
(`GameServer.stamp/4`) so memory agrees with the rows, and a rehydrate
re-reads `players` once after replay in case a stamp landed mid-replay. The
rule itself is one Gleam function (`seat.stamp`) that the row and a room's
memory both call. **An owner never comes off a seat**: every seat-list
write a room makes (a join, a claim, a start) goes through `seat.keep_owners`
against the row, so a room writing from memory that has not heard of a
sign-in yet cannot undo it. The sign-in also drops every socket the browser
opened under its old id (`guest:<old>`), so each tab reconnects on the new
cookie as the account; and if the stamp's transaction rolls back, nothing
moved, so the browser keeps its id and is signed in on that. The guest
cookie is re-set on every page load (the rolling year) but a `/papi`
response writes it only when minting one, so a JSON request that was in
flight during a sign-in cannot answer afterwards and put the old id back. A
seat another account owns is never taken, a seat with no guest (tooling, a
pre-guest row) can never be stamped, and at a table where the account
already owns a seat the browser's other seat is not stamped (one person,
one seat per table, however many devices) but still moves to the fresh
guest id, so that browser keeps playing it as a guest seat. There is
nothing to backfill: every seat starts unowned.

## Future
- Bots derived from `legal` for solo play and balance reports.
