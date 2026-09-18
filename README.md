# Oskol

> **Heads up:** Oskol is a purely vibe-coded side project. It has plenty of rough edges and bugs, but it works.
>
> I'm **not looking for contributors**, but folks are welcome to fork the repo and deploy their own versions. Licensed under AGPLv3 — see [LICENSE](LICENSE).

**Live at:** [oskol.io](https://oskol.io)

Oskol is a backgammon site, and means to be the best place on the internet to play backgammon: with a friend from a link, no accounts, on a phone or a desktop. The real game with the doubling cube -- single games, matches with the Crawford rule, unlimited play with the Jacoby rule -- and the analysis engine's verdicts on every game once it is over: play a friend from a link, then learn from the game.

The game is written in Gleam on top of **gamekit**, a tiny framework where a game is one module implementing a small contract (init, decode action, apply, legal actions, scene, outcome, clocks, timeout). The Elixir/Phoenix host and the Elm client speak a fixed protocol of scenes, events and action schemas and never see a checker. See [CLAUDE.md](CLAUDE.md) for the architecture.

- `/` the home page
- `/backgammon` set up a game and share the invite link it gives you

## Running locally

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4400`](http://localhost:4400) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
