# MCP conformance suite

Runs the official [MCP conformance suite](https://github.com/modelcontextprotocol/conformance)
(`@modelcontextprotocol/conformance`, pinned in `package.json`) against a
Phantom server.

```sh
npm ci
npm run build:test
bin/conformance                    # every scenario
bin/conformance ping tools-list    # only the given scenarios
```

`bin/conformance` starts `server.exs` with `MIX_ENV=test`, runs each scenario
against it, and stops it again. It exits non-zero when a scenario fails that is
not listed in `expected-failures.yml`, or when a listed scenario passes.

## Files

- `router.ex` - `Conformance.MCP.Router`, which mirrors the suite's reference
  ["everything" server](https://github.com/modelcontextprotocol/conformance/blob/main/examples/servers/typescript/everything-server.ts)
  using only Phantom's public API. Where Phantom cannot express a fixture, the
  closest equivalent is used and the gap is noted in a comment.
- `server.exs` - serves the router with Bandit on `PORT` (default `3999`).
  Origin validation is off by default because the conformance client sends no
  `Origin` header; set `VALIDATE_ORIGIN=true` to turn it on.
- `expected-failures.yml` - known failures, each with the reason.

To run the server alone, for example to point the CLI at it with other
options:

```sh
MIX_ENV=test mix run test/conformance/server.exs
npx conformance server --url http://localhost:3999/mcp --scenario server-initialize
```
