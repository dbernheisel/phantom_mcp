defmodule Phantom.ACTS.Router do
  @moduledoc false

  use Phantom.Router,
    name: "Phantom ACTS",
    vsn: "1.0",
    a2a: [well_known: "acts"]

  agent("acts", Phantom.ACTS.Agent)
end
