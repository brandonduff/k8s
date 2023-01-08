defmodule K8s.Client.Mint.Request do
  @moduledoc """
  Maintains the state of a HTTP or Websocket request.
  """

  alias K8s.Client.Mint.ConnectionRegistry

  @typedoc """
  Describes the mode the request is currently in.

  - `:receiving` - The request is currently receiving response parts / frames
  - `:closing` - Websocket requests only: The `:close` frame was received but the process wasn't terminated yet
  - `:terminating` - HTTP requests only: The `:done` part was received but the request isn't cleaned up yet
  - `:closed` - The websocket request is closed. The process is going to terminate any moment now
  """
  @type request_modes :: :receiving | :closing | :terminating | :closed

  @typedoc """
  Defines the state of the request.

  - `:caller_ref` - ,onitor reference of the calling process.
  - `:stream_to` - the process expecting response parts sent to.
  - `:pool` - the PID of the pool so we can checkin after the last part is sent.
  - `:websocket` - for WebSocket requests: The websocket state (`Mint.WebSocket.t()`).
  - `:mode` - defines what mode the request is currently in.
  - `:buffer` - Holds the buffered response parts or frames that haven't been
    sent to / received by the caller yet
  """
  @type t :: %__MODULE__{
          caller_ref: reference(),
          stream_to: pid() | {pid(), reference()} | nil,
          pool: pid() | nil,
          websocket: Mint.WebSocket.t() | nil,
          mode: request_modes(),
          buffer: list()
        }

  defstruct [:caller_ref, :stream_to, :pool, :websocket, mode: :receiving, buffer: []]

  @spec new(keyword()) :: t()
  def new(fields), do: struct!(__MODULE__, fields)

  @spec put_response(t(), :done | {atom(), any()}) :: :pop | {t() | :stop, t()}
  def put_response(request, response) do
    request
    |> struct!(buffer: [response | request.buffer])
    |> update_mode(response)
    |> send_response()
    |> maybe_terminate_request()
  end

  @spec recv(t(), GenServer.from()) :: :pop | {t() | :stop, t()}
  def recv(request, from) do
    request
    |> struct!(stream_to: {:reply, from})
    |> send_response()
    |> maybe_terminate_request()
  end

  @spec update_mode(t(), :done | {atom(), term()}) :: t()
  defp update_mode(%__MODULE__{mode: mode} = request, _) when mode != :receiving, do: request

  defp update_mode(request, {:close, _}) do
    struct!(request, mode: :closing)
  end

  defp update_mode(request, :done) do
    struct!(request, mode: :terminating)
  end

  defp update_mode(request, _), do: request

  @spec maybe_terminate_request(t()) :: {t() | :stop, t()} | :pop
  def maybe_terminate_request(%__MODULE__{mode: :closing, buffer: []} = request),
    do: {:stop, struct!(request, mode: :closed)}

  def maybe_terminate_request(%__MODULE__{mode: :terminating, buffer: []} = request) do
    Process.demonitor(request.caller_ref)
    ConnectionRegistry.checkin(%{pool: request.pool, adapter: self()})
    :pop
  end

  def maybe_terminate_request(request), do: {request, request}

  @spec send_response(t()) :: t()
  defp send_response(%__MODULE__{stream_to: nil} = request) do
    request
  end

  defp send_response(%__MODULE__{stream_to: {:reply, from}, buffer: [_ | _]} = request) do
    GenServer.reply(from, request.buffer)
    struct!(request, stream_to: nil, buffer: [])
  end

  defp send_response(%__MODULE__{stream_to: {pid, ref}} = request) do
    Enum.each(request.buffer, &send(pid, {ref, &1}))
    struct!(request, buffer: [])
  end

  defp send_response(%__MODULE__{stream_to: pid} = request) do
    Enum.each(request.buffer, &send(pid, &1))
    struct!(request, buffer: [])
  end

  @spec map_response({:done, reference()} | {atom(), reference(), any}) ::
          {:done | {atom(), any}, reference()}
  def map_response({:done, ref}), do: {:done, ref}
  def map_response({type, ref, value}), do: {{type, value}, ref}

  @spec map_frame({:binary, binary} | {:close, any, any}) ::
          {:close, {integer(), binary()}}
          | {:error, binary}
          | {:stderr, binary}
          | {:stdout, binary}
  def map_frame({:close, code, reason}), do: {:close, {code, reason}}
  def map_frame({:binary, <<1, msg::binary>>}), do: {:stdout, msg}
  def map_frame({:binary, <<2, msg::binary>>}), do: {:stderr, msg}
  def map_frame({:binary, <<3, msg::binary>>}), do: {:error, msg}

  @spec map_outgoing_frame({:stdin, binary()} | {:close, integer(), binary()} | :close | :exit) ::
          {:ok, :close | {:text, binary} | {:close, integer(), binary()}}
          | K8s.Client.HTTPError.t()
  def map_outgoing_frame({:stdin, data}), do: {:ok, {:text, <<0>> <> data}}
  def map_outgoing_frame(:close), do: {:ok, :close}
  def map_outgoing_frame(:exit), do: {:ok, :close}
  def map_outgoing_frame({:close, code, reason}), do: {:ok, {:close, code, reason}}

  def map_outgoing_frame(data) do
    K8s.Client.HTTPError.new(
      message: "The given message #{inspect(data)} is not supported to be sent to the Pod."
    )
  end

  @spec receive_upgrade_response(Mint.HTTP.t(), reference()) ::
          {:ok, Mint.HTTP.t(), map()} | {:error, Mint.HTTP.t(), Mint.Types.error()}
  def receive_upgrade_response(conn, ref) do
    Enum.reduce_while(Stream.cycle([:ok]), {conn, %{}}, fn _, {conn, response} ->
      case Mint.HTTP.recv(conn, 0, 5000) do
        {:ok, conn, parts} ->
          response =
            parts
            |> Map.new(fn
              {type, ^ref} -> {type, true}
              {type, ^ref, value} -> {type, value}
            end)
            |> Map.merge(response)

          # credo:disable-for-lines:3
          if response[:done],
            do: {:halt, {:ok, conn, response}},
            else: {:cont, {conn, response}}

        {:error, conn, error, _} ->
          {:halt, {:error, conn, error}}
      end
    end)
  end
end
