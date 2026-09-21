defmodule Oskol.Auth.SourceKey do
  @moduledoc false

  @secret_key {__MODULE__, :secret}

  # Limiter keys live only as long as this VM. A fresh secret on each boot
  # makes an ETS entry useless for recovering a source IP after the fact.
  def boot! do
    :persistent_term.put(@secret_key, :crypto.strong_rand_bytes(32))
  end

  def key(source) when is_binary(source) do
    :crypto.mac(:hmac, :sha256, :persistent_term.get(@secret_key), source)
    |> Base.url_encode64(padding: false)
  end
end
