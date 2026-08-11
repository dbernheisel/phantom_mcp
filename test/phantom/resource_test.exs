defmodule Phantom.ResourceTest do
  use ExUnit.Case, async: true

  alias Phantom.Resource

  describe "list/2" do
    test "omits nextCursor when there is no next page" do
      result = Resource.list([%{uri: "test:///foo"}], nil)

      refute Map.has_key?(result, :nextCursor)
      assert result.resources == [%{uri: "test:///foo"}]
    end

    test "includes nextCursor when a cursor is given" do
      result = Resource.list([], "abc")

      assert result.nextCursor == "abc"
    end

    test "wraps a single resource link" do
      assert Resource.list(%{uri: "test:///foo"}, nil) == %{resources: [%{uri: "test:///foo"}]}
    end
  end
end
