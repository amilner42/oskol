defmodule Oskol.Auth do
  @moduledoc """
  Accounts, and the rows behind signing into one: `users` (an account is an
  email address and nothing else) and `login_tokens` (a sign-in in flight).

  Nothing here decides anything. How long a token lives, how many tries a
  code gets, what a refusal says, whether an address looks like one: all of
  that is `src/oskol/handlers/auth.gleam`, and this is the IO behind
  `src/oskol/caps/auth.gleam` (built in `Oskol.Gleam.Caps.Auth`).

  What it does guarantee:

    * a token and a code are stored as sha256 and never logged — the
      plaintext exists only between minting it and handing it to the mailer;
    * spending one is a single statement, so two opens cannot both win;
    * a code is only ever checked against the browser that asked for it.
  """

  import Ecto.Query

  alias Oskol.Repo

  defmodule User do
    @moduledoc "One account: an email address, and a name it may pick later."
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "users" do
      field(:email, :string)
      field(:name, :string)
      field(:last_login_at, :utc_datetime_usec)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end

  defmodule LoginToken do
    @moduledoc """
    One sign-in in flight: a link's token and a six-digit code, both as
    sha256, good for as long as the handler said, single use, and tied to the
    browser that asked.
    """
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "login_tokens" do
      field(:email, :string)
      field(:token_hash, :binary)
      field(:code_hash, :binary)
      field(:guest_id, :string)
      field(:next, :string)
      field(:expires_at, :utc_datetime_usec)
      field(:consumed_at, :utc_datetime_usec)
      field(:attempts, :integer, default: 0)

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end
  end

  @doc """
  Mint a sign-in for this address: 32 random bytes as the link's token, a
  separate six-digit code, both stored as sha256. Returns the plaintext pair,
  which is only ever used to write the mail.

  Several may be live for one address at once — two people on one address,
  or one person asking twice because the first mail was slow. Each dies on
  its own expiry or its first use.
  """
  def issue(email, guest_id, next, ttl_s) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    code = six_digits()
    now = DateTime.utc_now()

    Repo.insert!(%LoginToken{
      email: email,
      token_hash: hash(token),
      code_hash: hash(code),
      guest_id: guest_id,
      next: next,
      expires_at: DateTime.add(now, ttl_s, :second),
      inserted_at: now
    })

    {token, code}
  end

  @doc """
  What a token names, spending nothing: the page behind a mailed link reads
  it this way, so a mail scanner that fetches the link cannot burn it.
  """
  def verify(token) when is_binary(token) do
    Repo.one(from(t in live(), where: t.token_hash == ^hash(token)))
  end

  def verify(_), do: nil

  @doc """
  Spend a token. One statement, so of two opens exactly one wins; the loser
  sees an expired link, which is the truth.
  """
  def consume(token) when is_binary(token) do
    now = DateTime.utc_now()

    {_, rows} =
      from(t in live(), where: t.token_hash == ^hash(token))
      |> select([t], t)
      |> Repo.update_all(set: [consumed_at: now])

    List.first(rows)
  end

  def consume(_), do: nil

  @doc """
  Check a six-digit code against the live token for this address *and this
  browser*, with at most `max_attempts` tries on it.

    * `{:ok, token}` — it matched, and the token is now spent.
    * `:wrong` — there is a live token and that was not its code; the try
      is on the row.
    * `:dead` — nothing live to check against: no token for this address and
      this browser, expired, already used, or out of tries.

  The guest is part of the lookup on purpose: the code signs in the browser
  that asked for it, which is exactly the cross-device case (the mail opens
  on the phone, the laptop types the code).
  """
  def check_code(email, code, guest_id, max_attempts)
      when is_binary(email) and is_binary(code) and is_binary(guest_id) and max_attempts > 0 do
    Repo.transaction(fn ->
      candidate =
        from(t in live(),
          where: t.email == ^email,
          where: t.guest_id == ^guest_id,
          where: t.attempts < ^max_attempts,
          order_by: [desc: t.inserted_at],
          limit: 1,
          lock: "FOR UPDATE"
        )
        |> Repo.one()

      case candidate do
        nil ->
          :dead

        %LoginToken{} = row ->
          # Constant time, so the wrong code cannot be found a digit at a time.
          if :crypto.hash_equals(row.code_hash, hash(code)) do
            {:ok, Repo.update!(Ecto.Changeset.change(row, consumed_at: DateTime.utc_now()))}
          else
            attempts = row.attempts + 1
            Repo.update!(Ecto.Changeset.change(row, attempts: attempts))
            if attempts >= max_attempts, do: :dead, else: :wrong
          end
      end
    end)
    |> case do
      {:ok, verdict} -> verdict
      {:error, _} -> :dead
    end
  end

  def check_code(_, _, _, _), do: :dead

  @doc """
  The account for this address, made if it is new; either way its
  `last_login_at` moves forward. One statement, so two links opened at once
  for one new address make one account.
  """
  def find_or_create_user(email) when is_binary(email) do
    now = DateTime.utc_now()

    {:ok, user} =
      Repo.insert(%User{email: email, last_login_at: now, inserted_at: now},
        on_conflict: [set: [last_login_at: now]],
        conflict_target: :email,
        returning: true
      )

    user
  end

  @doc "One account, by id. `nil` for an id nothing answers to."
  def user(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(User, uuid)
      :error -> nil
    end
  end

  def user(_), do: nil

  @doc "This browser is signed in as that account."
  def bind_guest(guest_id, user_id) when is_binary(guest_id) and is_binary(user_id) do
    now = DateTime.utc_now()

    Repo.insert!(
      %Oskol.Guests.Guest{id: guest_id, user_id: user_id, last_seen_at: now},
      on_conflict: [set: [user_id: user_id, last_seen_at: now]],
      conflict_target: :id
    )

    :ok
  end

  @doc "This browser is a guest again. The seats it stamped stay the account's."
  def unbind_guest(guest_id) when is_binary(guest_id) do
    from(g in Oskol.Guests.Guest, where: g.id == ^guest_id)
    |> Repo.update_all(set: [user_id: nil])

    :ok
  end

  @doc """
  The account this browser is signed into, as an id, or nil. Read once per
  request (`Oskol.Gleam.CtxBuilder`) and once per socket connect, off the
  index the accounts migration adds.
  """
  def user_id_of_guest(guest_id) when is_binary(guest_id) and guest_id != "" do
    Repo.one(from(g in Oskol.Guests.Guest, where: g.id == ^guest_id, select: g.user_id))
  rescue
    # Guest bookkeeping never breaks a page; neither does reading it.
    _ -> nil
  end

  def user_id_of_guest(_), do: nil

  # ---------- Plumbing ----------

  # Tokens that are still worth anything: not spent, not expired.
  defp live do
    now = DateTime.utc_now()
    from(t in LoginToken, where: is_nil(t.consumed_at), where: t.expires_at > ^now)
  end

  # Six digits, uniformly, from the same source as everything else secret
  # here. Leading zeros are kept: "004821" is a code like any other.
  defp six_digits do
    :crypto.strong_rand_bytes(8)
    |> :binary.decode_unsigned()
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  @doc false
  # Only the hash is ever stored, compared or logged.
  def hash(secret), do: :crypto.hash(:sha256, secret)
end
