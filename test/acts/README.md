# A2A conformance suite (ACTS)

Runs the official A2A conformance suite, ACTS, from
[a2aproject/a2a-itk](https://github.com/a2aproject/a2a-itk) (pinned in
`Phantom.Test.ACTS`) against Phantom's A2A agents. Requires
[uv](https://docs.astral.sh/uv/) and git.

```sh
mix test --only acts
```

The first run clones a2a-itk into `_build/a2a-itk`. Set `A2A_ITK_PATH` to use
another checkout.

`Phantom.ACTS.Agent` implements the `tck-*` behaviors that the suite's tests
name in their first message, as declared in `sut-behaviors.yaml`. ACTS tests it
three ways, each served by `Phantom.ACTS.HTTP`:

- **default**, with a pubsub, so it streams;
- **reduced**, without a pubsub or push notifications, for the tests of an
  agent that does neither (`--reduced-sut-url`);
- **auth**, `Phantom.ACTS.AuthRouter`, which requires
  `Bearer itk-valid-token` and answers `itk-insufficient-token` with 403
  (`--auth-sut-url`).

Only the JSON-RPC binding runs, because it is the only one Phantom serves.
The routers allow private push URLs, because the suite's webhook receiver
listens on 127.0.0.1. Tests for extended agent cards are skipped, because the
card doesn't advertise them.

## Expected failures

`expected-failures.yml` lists the tests Phantom is known to fail, each with its
cause. The run fails when a test outside the list fails, or a listed one
passes, so update the list as fixes land.

## Running tests by hand

Serve the agents, then run the suite from the a2a-itk checkout with any
`run_acts.py` options, such as one test with request logging:

```sh
MIX_ENV=test mix run test/acts/server.exs

cd _build/a2a-itk
uv run run_acts.py --sut-url http://127.0.0.1:4130 \
  --reduced-sut-url http://127.0.0.1:4131 --auth-sut-url http://127.0.0.1:4132 \
  --sdk phantom_mcp --behaviors ../../test/acts/sut-behaviors.yaml \
  -t STREAM-SSE-001 -v
```
