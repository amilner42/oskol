# Oskol

> **Heads up:** Oskol is a purely vibe-coded side project. It has plenty of rough edges and bugs, but it works.
>
> I'm **not looking for contributors**, but folks are welcome to fork the repo and deploy their own versions. Licensed under AGPLv3 — see [LICENSE](LICENSE).

**Live at:** [oskol.io](https://oskol.io)

Oskol is a small library of two-player games: the classics, easy to play with a friend from a link, each with optional twists that throw the book out. Today: heads-up no-limit hold'em (cash game or sit-and-go) and backgammon with the doubling cube.

Games are written in Gleam on top of **gamekit**, a tiny framework where a game is one module implementing a five-function contract (init, decode action, apply, legal actions, scene, outcome). The Elixir/Phoenix host and the Elm client are generic: they speak a fixed protocol of scenes, events and action schemas, so adding a game never touches them. See [CLAUDE.md](CLAUDE.md) for the architecture and how to add a game.

- `/` the game library
- `/poker` set up a poker game and share the invite link it gives you
- `/backgammon` the same for backgammon

## Running locally

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
