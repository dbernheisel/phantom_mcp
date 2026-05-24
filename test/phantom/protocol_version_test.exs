defmodule Phantom.ProtocolVersionTest do
  use ExUnit.Case, async: true

  alias Phantom.ProtocolVersion

  describe "supported?/1" do
    test "is true for every protocol version Phantom advertises" do
      for version <- ProtocolVersion.supported() do
        assert ProtocolVersion.supported?(version)
      end
    end

    test "is false for unknown values" do
      refute ProtocolVersion.supported?("9999-12-31")
      refute ProtocolVersion.supported?(nil)
      refute ProtocolVersion.supported?("")
    end
  end

  describe "mode/1" do
    test "returns :legacy for stateful protocol versions" do
      for version <- ~w[2024-11-05 2025-03-26 2025-06-18 2025-11-25] do
        assert ProtocolVersion.mode(version) == :legacy,
               "expected :legacy for #{version}"
      end
    end

    test "returns :stateless_core for 2026-07-28" do
      assert ProtocolVersion.mode("2026-07-28") == :stateless_core
    end

    test "returns :unsupported for unknown values" do
      assert ProtocolVersion.mode("9999-12-31") == :unsupported
      assert ProtocolVersion.mode(nil) == :unsupported
    end
  end

  describe "latest/0" do
    test "is the most recent supported version" do
      assert ProtocolVersion.latest() == "2026-07-28"
      assert ProtocolVersion.latest() == List.last(ProtocolVersion.supported())
    end
  end

  describe "supported/0" do
    test "is ordered oldest to newest" do
      assert ["2024-11-05" | _] = ProtocolVersion.supported()
      assert List.last(ProtocolVersion.supported()) == ProtocolVersion.latest()
    end

    test "includes the new stateless-core version" do
      assert "2026-07-28" in ProtocolVersion.supported()
    end
  end
end
