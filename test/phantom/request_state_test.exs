defmodule Phantom.RequestStateTest do
  use ExUnit.Case, async: true

  alias Phantom.RequestState

  @secret :crypto.strong_rand_bytes(64) |> Base.encode64()

  describe "encode/2 + decode/3" do
    test "round-trips a term unchanged" do
      term = %{step: :resolve_airport, candidates: ["JFK", "LGA"], count: 2}
      token = RequestState.encode(term, @secret)
      assert is_binary(token)
      assert {:ok, ^term} = RequestState.decode(token, @secret)
    end

    test "round-trips deeply-nested data" do
      term = %{
        a: [1, 2, %{b: "c"}],
        d: {:tagged, "tuple", nil},
        e: %{f: %{g: %{h: "deep"}}}
      }

      token = RequestState.encode(term, @secret)
      assert {:ok, ^term} = RequestState.decode(token, @secret)
    end
  end

  describe "decode/3 rejects tampered tokens" do
    test "flipping a byte in the ciphertext yields :invalid" do
      token = RequestState.encode(%{a: 1}, @secret)

      # Flip a byte somewhere in the middle of the encoded token.
      <<head::binary-size(20), byte, tail::binary>> = token
      tampered = <<head::binary, Bitwise.bxor(byte, 0x01), tail::binary>>

      assert {:error, :invalid} = RequestState.decode(tampered, @secret)
    end

    test "a token signed with a different secret yields :invalid" do
      token = RequestState.encode(%{a: 1}, @secret)
      other_secret = :crypto.strong_rand_bytes(64) |> Base.encode64()
      assert {:error, :invalid} = RequestState.decode(token, other_secret)
    end

    test "garbage input yields :invalid" do
      assert {:error, :invalid} = RequestState.decode("not-a-real-token", @secret)
    end
  end

  describe "max_age" do
    test "a freshly-encoded token decodes under the default ttl" do
      token = RequestState.encode(%{a: 1}, @secret)
      assert {:ok, %{a: 1}} = RequestState.decode(token, @secret)
    end

    test "max_age: 0 makes the token immediately expired" do
      token = RequestState.encode(%{a: 1}, @secret)
      # Sleep 1s so the encoded timestamp is strictly in the past.
      Process.sleep(1_100)
      assert {:error, :expired} = RequestState.decode(token, @secret, max_age: 1)
    end

    test "explicit max_age overrides the default" do
      token = RequestState.encode(%{a: 1}, @secret)
      assert {:ok, %{a: 1}} = RequestState.decode(token, @secret, max_age: 3600)
    end
  end
end
