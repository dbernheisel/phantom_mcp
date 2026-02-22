defmodule Phantom.MockIO do
  @moduledoc false
  use GenServer

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def push_input(pid, data) do
    GenServer.call(pid, {:push_input, data})
  end

  def push_eof(pid) do
    GenServer.call(pid, :push_eof)
  end

  def get_output(pid) do
    GenServer.call(pid, :get_output)
  end

  @doc "Block until output is available, then return it."
  def await_output(pid, timeout \\ 5000) do
    GenServer.call(pid, :await_output, timeout)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, %{input: :queue.new(), output: [], waiters: :queue.new(), eof: false}}
  end

  @impl true
  def handle_call({:push_input, data}, _from, state) do
    state = enqueue_input(state, data)
    {:reply, :ok, state}
  end

  def handle_call(:push_eof, _from, state) do
    state = %{state | eof: true}
    state = flush_waiters_eof(state)
    {:reply, :ok, state}
  end

  def handle_call(:get_output, _from, state) do
    output = state.output |> Enum.reverse() |> IO.iodata_to_binary()
    {:reply, output, %{state | output: []}}
  end

  def handle_call(:await_output, _from, state) do
    {output, state} = try_collect_output(state)
    {:reply, output, state}
  end

  # Erlang IO protocol
  @impl true
  def handle_info({:io_request, from, reply_as, request}, state) do
    {result, state} = io_request(request, state)
    send(from, {:io_reply, reply_as, result})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # IO request handling

  defp io_request({:get_line, _encoding, _prompt}, state) do
    try_read_line(state)
  end

  defp io_request({:get_line, _prompt}, state) do
    try_read_line(state)
  end

  defp io_request({:put_chars, _encoding, chars}, state) do
    {:ok, %{state | output: [chars | state.output]}}
  end

  defp io_request({:put_chars, chars}, state) do
    {:ok, %{state | output: [chars | state.output]}}
  end

  defp io_request({:put_chars, _encoding, module, func, args}, state) do
    chars = apply(module, func, args)
    {:ok, %{state | output: [chars | state.output]}}
  end

  defp io_request({:requests, requests}, state) do
    Enum.reduce(requests, {:ok, state}, fn
      _request, {{:error, _} = error, state} -> {error, state}
      request, {_, state} -> io_request(request, state)
    end)
  end

  defp io_request({:setopts, _opts}, state) do
    {:ok, state}
  end

  defp io_request({:get_geometry, _}, state) do
    {{:error, :enotsup}, state}
  end

  defp io_request(_request, state) do
    {{:error, :request}, state}
  end

  # Line reading

  defp try_read_line(state) do
    case :queue.out(state.input) do
      {{:value, line}, rest} ->
        {line, %{state | input: rest}}

      {:empty, _} ->
        if state.eof do
          {:eof, state}
        else
          # Block until input arrives - use a synchronous wait
          receive do
            {:"$gen_call", from, {:push_input, data}} ->
              GenServer.reply(from, :ok)
              state = enqueue_input(state, data)
              try_read_line(state)

            {:"$gen_call", from, :push_eof} ->
              GenServer.reply(from, :ok)
              {:eof, %{state | eof: true}}
          end
        end
    end
  end

  defp enqueue_input(state, data) do
    lines =
      data
      |> String.split("\n", trim: false)
      |> then(fn
        # "foo\n" splits to ["foo", ""] - we want ["foo\n"]
        # "foo\nbar\n" splits to ["foo", "bar", ""] - we want ["foo\n", "bar\n"]
        parts ->
          parts
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.map(fn [line, _] -> line <> "\n" end)
      end)

    input = Enum.reduce(lines, state.input, fn line, q -> :queue.in(line, q) end)
    %{state | input: input}
  end

  # Output reading — blocks until output is available

  defp try_collect_output(state) do
    output = state.output |> Enum.reverse() |> IO.iodata_to_binary()

    if output != "" do
      {output, %{state | output: []}}
    else
      receive do
        {:io_request, from, reply_as, request} ->
          {result, state} = io_request(request, state)
          send(from, {:io_reply, reply_as, result})
          try_collect_output(state)

        {:"$gen_call", from, :get_output} ->
          GenServer.reply(from, "")
          try_collect_output(state)
      end
    end
  end

  defp flush_waiters_eof(state) do
    # No waiters mechanism needed since we handle it inline in try_read_line
    state
  end
end
