# Serves the ACTS agents for running the suite by hand. See test/acts/README.md.
#
#     MIX_ENV=test mix run test/acts/server.exs

{:ok, _} = Supervisor.start_link(Phantom.Test.ACTS.children(), strategy: :one_for_one)

for name <- [:default, :reduced, :auth] do
  IO.puts("ACTS agent (#{name}): #{Phantom.Test.ACTS.url(name)}")
end

Process.sleep(:infinity)
