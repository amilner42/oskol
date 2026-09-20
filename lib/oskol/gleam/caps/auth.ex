defmodule Oskol.Gleam.Caps.Auth do
  @moduledoc """
  Real IO for src/oskol/caps/auth.gleam. Keep field order in lockstep: a
  Gleam record is a tagged tuple, so a field out of place is a silent
  mix-up, not a compile error.

  Rows are `Oskol.Auth`, the mail is `Oskol.Mail`, the counters are
  `Oskol.Auth.Limiter`, and dropping a browser's sockets is the endpoint.
  Nothing in here decides anything.
  """

  import Oskol.Gleam.Interop

  alias Oskol.Auth
  alias Oskol.Auth.Limiter
  alias Oskol.Mail

  def build do
    {:auth_caps, &Limiter.allow_mail/1, &mail_budget/0, &issue_token/4, &send_mail/3,
     &verify_token/1, &consume_token/1, &check_code/4, &find_or_create_user/1, &user/1,
     &stamp_seats/3, &Auth.bind_guest/2, &Auth.unbind_guest/1, &disconnect/1, &renamed/2,
     &claim_name/2}
  end

  # Keep this data-only. Gleam's handler decides which buckets must pass and
  # keeps the indistinguishable successful response when one does not.
  defp mail_budget do
    config = Application.get_env(:oskol, :auth_mail_budget, [])

    {:mail_budget, limit(config, :guest, 10), window_s(config, :guest, 3_600),
     limit(config, :address, 30), window_s(config, :address, 3_600), limit(config, :source, 20),
     window_s(config, :source, 3_600), limit(config, :global, 200),
     window_s(config, :global, 86_400)}
  end

  defp limit(config, bucket, default), do: positive(config, bucket, :limit, default)
  defp window_s(config, bucket, default), do: positive(config, bucket, :window_s, default)

  defp positive(config, bucket, key, default) do
    case config |> Keyword.get(bucket, []) |> Keyword.get(key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  @doc """
  Sign-in's one write: the seats this browser was holding become the
  account's, and browser and seats alike move to a fresh guest id.

  The write goes through `Oskol.Game.Persister`, so it lands behind
  everything the live rooms have queued; live rooms are told after it, and
  a room that is not live reads the stamped row when it next rehydrates. A
  room that rewrites its seats in between cannot undo it: a seat list on
  disk never loses an owner.

  Answers how many seats the account gained, which is the number the page
  shows.
  """
  def stamp_seats(old_guest_id, new_guest_id, user_id) do
    case Oskol.Game.Persister.stamp_seats(old_guest_id, new_guest_id, user_id) do
      {:ok, {count, game_ids}} ->
        # Rooms that are live hear of it now, so memory says what the row
        # says. A room that rewrites its seats before it hears cannot undo
        # the stamp: a seat list written to disk never loses an owner
        # (`seat.keep_owners`, in `Oskol.Persistence`).
        username = Oskol.Auth.username(user_id)
        Enum.each(game_ids, &tell(&1, old_guest_id, new_guest_id, user_id, username))
        {:ok, count}

      # Queued, not yet landed: the browser moves with it; the rooms pick
      # it up from the row when they next read it.
      :pending ->
        {:ok, 0}

      :error ->
        {:error, nil}
    end
  end

  defp tell(game_id, old_guest_id, new_guest_id, user_id, username) do
    case Oskol.Game.find_game(game_id) do
      {:ok, _pid} ->
        Oskol.Game.GameServer.stamp(game_id, old_guest_id, new_guest_id, user_id, username)

      _ ->
        0
    end
  end

  defp issue_token(email, guest_id, next, ttl_s) do
    {token, code} = Auth.issue(email, unopt(guest_id), unopt(next), ttl_s)
    {:issued, token, code}
  end

  defp send_mail(email, token, code) do
    Mail.send_login(email, OskolWeb.Endpoint.url() <> "/login/" <> token, code)
    nil
  end

  defp verify_token(token), do: opt(Auth.verify(token), &pending/1)

  defp consume_token(token), do: opt(Auth.consume(token), &pending/1)

  defp check_code(email, code, guest_id, max_attempts) do
    case Auth.check_code(email, code, unopt(guest_id) || "", max_attempts) do
      {:ok, row} -> {:code_ok, pending(row)}
      :wrong -> :code_wrong
      :dead -> :code_dead
    end
  end

  defp find_or_create_user(email), do: Auth.find_or_create_user(email) |> user_record()

  defp user(id), do: opt(Auth.user(id), &user_record/1)

  # A browser's own sockets, by the id OskolWeb.UserSocket gives them
  # ("guest:<guest id>"): logging out must not leave a tab playing a seat.
  # Every live room holding a seat of this account shows the new name. The
  # rows keep pointing at the account, so nothing is written.
  defp renamed(user_id, username) do
    # Every live room is asked, not the rooms the rows say: a room whose
    # match has finished is still on screen, and a seat claimed a moment
    # ago may not have reached its row yet. A room with no seat of this
    # account's does nothing with it.
    Registry.select(Oskol.GameRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.each(&Oskol.Game.GameServer.rename(&1, user_id, username))

    nil
  end

  defp claim_name(user_id, name) do
    case Auth.claim_name(user_id, name) do
      :ok -> {:ok, nil}
      :taken -> {:error, nil}
    end
  end

  defp disconnect(guest_id) do
    OskolWeb.Endpoint.broadcast("guest:" <> guest_id, "disconnect", %{})
    nil
  end

  defp pending(%Auth.LoginToken{} = row) do
    {:pending, row.email, opt(row.guest_id), opt(row.next)}
  end

  defp user_record(%Auth.User{} = user), do: {:user, user.id, user.email, opt(user.name)}
end
