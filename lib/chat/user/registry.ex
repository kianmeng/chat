defmodule Chat.User.Registry do
  @moduledoc "Registry of User Cards"

  use GenServer
  require Logger

  alias Chat.User.Card
  alias Chat.User.Identity

  ### Interface

  def enlist(%Identity{} = user), do: GenServer.call(__MODULE__, {:enlist, user})

  def all, do: GenServer.call(__MODULE__, :all)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, opts)
  end

  ### Implementation

  @impl true
  def init(_) do
    {:ok, %{list: %{}}}
  end

  @impl true
  def handle_call(:all, _, %{list: list} = state) do
    {:reply, list, state}
  end

  @impl true
  def handle_call({:enlist, %Identity{} = user}, _, %{list: list} = state) do
    card = Card.from_identity(user)
    new_list = Map.put(list, card.pub_key, card)
    {:reply, card.id, %{state | list: new_list}}
  end
end
