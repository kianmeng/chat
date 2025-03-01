defmodule ChatWeb.Helpers.OnlinersSync do
  @moduledoc """
  Fetches user's keys from the LiveView socket and
  and sends them to the platform for the synchronization.
  """

  alias Chat.Identity
  alias Phoenix.LiveView.Socket
  alias Phoenix.PubSub

  @type socket :: Socket.t()

  @outgoing_topic "chat_onliners->platform_onliners"

  @spec get_user_keys(socket()) :: socket()
  def get_user_keys(%Socket{assigns: %{me: me, rooms: rooms}} = socket)
      when not is_nil(me) and not is_nil(rooms) do
    keys =
      [me | rooms]
      |> Enum.map(&Identity.pub_key/1)
      |> MapSet.new()

    PubSub.broadcast(Chat.PubSub, @outgoing_topic, {:user_keys, keys})

    socket
  end

  def get_user_keys(socket), do: socket
end
