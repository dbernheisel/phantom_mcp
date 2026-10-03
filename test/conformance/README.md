# MCP conformance suite

Runs the official [MCP conformance suite](https://github.com/modelcontextprotocol/conformance)
(`@modelcontextprotocol/conformance`, pinned in `package.json`) against
Phantom. Requires `epmd` (`epmd -daemon`), like the other clustered tests.

```sh
npm ci
mix test --only conformance    # or: bin/conformance
```

Each spec revision's requirement set (`--requirements 2025-11-25` and
`--requirements 2026-07-28`) runs against two topologies:

- **single**: one node serves every request.
- **distributed**: `Phantom.Test.ConformanceProxy` sends each HTTP request
  to the next of two nodes, so a session's requests, its SSE streams, and
  its `requestState` continuations are served by different nodes.

The nodes are the test cluster peers started by `test/test_helper.exs`. Each
one serves `Conformance.MCP.Router` (`router.ex`) on its own port, and the
proxy listens on the primary node. See `Phantom.Test.Conformance`.

## Expected failures

`expected-failures/<revision>.yml` lists what Phantom is known to fail on
every topology, each with its cause. `<revision>.<topology>.yml`, when present,
adds failures that only occur on that topology. An entry is either a whole
scenario or one check (`scenario:check-id`). A run fails when a scenario or
check outside the list fails, or when a listed one passes, so update the list
as fixes land.

Scenarios a requirement set runs without scoring (extensions such as tasks,
and scenarios added after the revision shipped) are reported but never fail
the run, so they are not listed. To enforce one, add it to
`@unscored_scenarios` in `conformance_test.exs`; it then runs on its own and
must pass.

## Running scenarios by hand

`bin/conformance` with arguments starts the cluster with `server.exs` and
passes the arguments to `npx conformance server`:

```sh
bin/conformance --scenario tools-call-with-logging --spec-version 2025-11-25
TOPOLOGY=distributed bin/conformance --requirements 2026-07-28
```

To keep the servers running, for example to run the CLI with `-o` or
`--verbose`:

```sh
MIX_ENV=test mix run test/conformance/server.exs
npx conformance server --url http://127.0.0.1:4111/mcp --scenario ping    # single
npx conformance server --url http://127.0.0.1:4110/mcp --scenario ping    # distributed
```

## Fixture router

`Conformance.MCP.Router` mirrors the suite's reference
["everything" server](https://github.com/modelcontextprotocol/conformance/blob/main/examples/servers/typescript/everything-server.ts)
using Phantom's public API. Where Phantom cannot express a fixture, the
closest equivalent is used and the gap is noted in a comment. The nodes only
accept localhost `Host` and `Origin` headers, like a local server should.
