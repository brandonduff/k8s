defmodule K8s.Client.Mint.Request.WebSocket do
  @moduledoc """
  Represents a WebSocket connection state.

  ### Fields

  - `:caller` - Synchronous requests only: The calling process.
  - `:stream_to` - StreamTo requests only: The process expecting response parts sent to.
  - `:waiting` - Streamed requests only: The process waiting for the next response part.
  - `:websocket` - The websocket state (`Mint.WebSocket.t()`).
  - `:response` - The response containing received parts.
  """

  alias K8s.Client.Mint.Request.HTTP, as: HTTPRequest

  @type t :: %__MODULE__{
          caller: pid() | nil,
          caller_ref: reference(),
          stream_to: pid() | nil,
          waiting: pid() | nil,
          websocket: Mint.WebSocket.t() | nil,
          response: %{},
          type: HTTPRequest.request_types()
        }

  defstruct [:caller, :caller_ref, :stream_to, :websocket, :waiting, :type, response: %{}]

  @spec new(keyword()) :: t()
  def new(fields \\ []), do: struct!(__MODULE__, fields)

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
end
