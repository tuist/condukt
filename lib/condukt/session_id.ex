defmodule Condukt.SessionID do
  @moduledoc """
  Generates UUIDv7 identifiers for `Condukt.Session` instances.

  UUIDv7 (RFC 9562) embeds a millisecond Unix timestamp in the high bits, so
  identifiers are roughly time-ordered: useful for index locality in
  downstream stores that persist session telemetry, and for human inspection.

  Callers that mint their own session ids (for example, to correlate a Condukt
  session with an external run record) can pass an `:id` option to
  `Condukt.start_link/2` and `Condukt.run/2` instead of generating one here.
  """

  @doc """
  Generates a new UUIDv7 string in canonical 8-4-4-4-12 lowercase hex form.
  """
  def generate do
    unix_ms = System.system_time(:millisecond)
    <<_::48, _::4, rand_a::12, _::2, rand_b::62>> = :crypto.strong_rand_bytes(16)

    <<a::32, b::16, c::16, d::16, e::48>> =
      <<unix_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>

    IO.iodata_to_binary([
      pad(a, 8),
      ?-,
      pad(b, 4),
      ?-,
      pad(c, 4),
      ?-,
      pad(d, 4),
      ?-,
      pad(e, 12)
    ])
  end

  defp pad(int, width) do
    int
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
