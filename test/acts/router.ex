defmodule Phantom.ACTS.Router do
  @moduledoc false

  use Phantom.Router,
    name: "Phantom ACTS",
    vsn: "1.0",
    a2a: [well_known: "acts", allow_private_push_urls: true]

  agent "acts", Phantom.ACTS.Agent
end
