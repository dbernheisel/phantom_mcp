## Project Overview

This is an Elixir library that implements the Model Context Protocol (MCP)
server specification using Plug. It provides a complete MCP server
implementation with JSON-RPC 2.0 support, SSE streaming, session management,
and security features. See @README.md

## Development Commands

### Dependencies and Setup
- `mix deps.get` - Install dependencies
- `mix deps.compile` - Compile dependencies

### Testing
- `mix test` - Run all tests
- `mix test test/specific_test.exs` - Run a specific test file
- `mix test --trace` - Run tests with detailed output

### Code Quality
- `mix format` - Format code according to Elixir style guidelines.
- `mix compile --warnings-as-errors` - Compile with strict warnings

### Documentation
- `mix docs` - Generate documentation with ExDoc.
- `h {Module}` - Lookup documentation in IEX for the module.
- `h {Module.function}` - Lookup documentation in IEX for a function

When getting documentation on an Elixir function, lookup both the module
  and the function to get more context on its appropriate usage.

### Development Server
- `iex -S mix` - Start a server and IEX session

## Architecture

The library is organized into several key modules:

### Core Protocol (`lib/phantom/`)
- `Phantom.Protocol` - JSON-RPC 2.0 message parsing, encoding, and validation
- `Phantom.Cache` - Manages `:persistent_term` that loads available MCP
  tools, prompts, and resources defined at compile time and added or removed
  at runtime.
- `Phantom.Session` - Session management with timeouts and data storage
- `Phantom.Handler` - Behaviour for implementing MCP methods
- `Phantom.Plug` - Main Plug implementation for HTTP transport with SSE support
- `Phantom.Server` - Starts a standalone Bandit server that mounts the user's
    MCP.Plug handlers
- `Phantom.Console` - Starts a stdio socket

### Test Structure (`test/`)
- Comprehensive test coverage for all modules
- Integration tests for HTTP requests including stateful SSE connections with
  sessions
- Handler behavior testing
- Protocol compliance verification

Session Management is optional and should use Elixir's Supervisor and have each
MCP session be its own GenServer supervised by a DynamicSupervisor. Elixir can
have many remote nodes with MCP Sessions on another node, so use Phoenix.Tracker
from the hex package phoenix_pubsub to allow Session management to work across
nodes transparently. It should be inspired by Phoenix.Socket which can be found
with the Tidewave MCP tool project_eval with `h Phoenix.Socket`.

The Handler provides an interface like Plug.Router with new macros that compiles
tools, resources, and prompts that are available, however these should be
configurable in runtime as well. The syntax should be inspired by
`Ecto.Schema` which can be found with the Tidewave MCP tool project_eval with
`h Ecto.Schema`.

The MCP.Server is optional and designed for extending non-web applications to be
exposed via a slim Bandit and Plug server. Normal usage of Phantom should be
through Phoenix applications that already have a web server.

The MCP.Console is optional and designed for using the MCP server locally only.

You write code using Test-Driven-Development method, which means you write the tests first, run the tests to verify they fail,
and then write the code to make the tests pass. Finally you run `mix format`
when everything is done.

## Key Features Implemented

1. **MCP Specification Compliance**: Full JSON-RPC 2.0 with streamable HTTP transport
2. **Plug Integration**: First-class Plug support
3. **Security**: Origin validation, CORS handling, localhost binding, session management
4. **Performance**: Bandit HTTP server, efficient message handling
5. **Configuration**: Application config, environment-specific settings, runtime configuration
6. **Testing**: Complete test suite with Phoenix integration tests

## Phoenix Integration Features

- **Phantom.Plug**: Dedicated Plug with CORS and authentication support
- **Multiple Integration Patterns**: Standalone server, Phoenix Endpoint integration
- **Security**: Origin validation, remote access control, preflight request handling
