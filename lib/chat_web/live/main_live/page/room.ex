defmodule ChatWeb.MainLive.Page.Room do
  @moduledoc "Room page"

  use ChatWeb, :component

  import ChatWeb.MainLive.Page.Shared
  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [consume_uploaded_entry: 3, push_event: 3, send_update: 2]

  require Logger

  alias Chat.Broker
  alias Chat.ChunkedFiles
  alias Chat.Content.Memo
  alias Chat.Dialogs
  alias Chat.FileIndex
  alias Chat.Identity
  alias Chat.Log
  alias Chat.MemoIndex
  alias Chat.Messages
  alias Chat.RoomInviteIndex
  alias Chat.Rooms
  alias Chat.Rooms.RoomRequest
  alias Chat.Upload.UploadMetadata
  alias Chat.User
  alias Chat.Utils.StorageId

  alias ChatWeb.MainLive.Layout

  alias Phoenix.PubSub

  @per_page 15

  def init(socket), do: socket |> assign(:room, nil)

  def init(%{assigns: %{room_map: rooms}} = socket, room_key) when is_binary(room_key) do
    room = Rooms.get(room_key)
    room_identity = rooms |> Map.fetch!(room_key)

    socket
    |> init({room_identity, room})
  end

  def init(
        %{assigns: %{me: me, monotonic_offset: time_offset}} = socket,
        {%Identity{} = room_identity, room}
      ) do
    PubSub.subscribe(Chat.PubSub, room.pub_key |> room_topic())

    time = Chat.Time.monotonic_to_unix(time_offset)
    Log.visit_room(me, time, room_identity)

    socket
    |> assign(:page, 0)
    |> assign(:lobby_mode, :rooms)
    |> assign(:input_mode, :plain)
    |> assign(:edit_content, nil)
    |> assign(:room, room)
    |> assign(:room_identity, room_identity)
    |> assign(:last_load_timestamp, nil)
    |> assign(:has_more_messages, true)
    |> assign(:message_update_mode, :replace)
    |> assign_messages()
    |> assign_requests()
  end

  def load_more_messages(%{assigns: %{page: page}} = socket) do
    socket
    |> assign(:page, page + 1)
    |> assign(:message_update_mode, :prepend)
    |> assign_messages()
    |> case do
      %{assigns: %{input_mode: :select}} = socket ->
        socket
        |> push_event("chat:toggle", %{to: "#chat-messages", class: "selectMode"})

      socket ->
        socket
    end
  end

  def send_text(
        %{assigns: %{room: room, me: me, room_map: rooms, monotonic_offset: time_offset}} =
          socket,
        text
      ) do
    time = Chat.Time.monotonic_to_unix(time_offset)

    case String.trim(text) do
      "" ->
        nil

      content ->
        content
        |> Messages.Text.new(time)
        |> Rooms.add_new_message(me, room.pub_key)
        |> MemoIndex.add(room, rooms[room.pub_key])
        |> broadcast_new_message(room.pub_key, me, time)
    end

    socket
  end

  def send_file(
        %{assigns: %{me: me, monotonic_offset: time_offset}} = socket,
        entry,
        %UploadMetadata{
          credentials: {chunk_key, chunk_secret},
          destination: %{pub_key: text_pub_key}
        } = _metadata
      ) do
    time = Chat.Time.monotonic_to_unix(time_offset)
    pub_key = text_pub_key |> Base.decode16!(case: :lower)

    message =
      consume_uploaded_entry(
        socket,
        entry,
        fn _ ->
          Messages.File.new(
            entry,
            chunk_key,
            ChunkedFiles.decrypt_secret(chunk_secret, me),
            time
          )
          |> Rooms.add_new_message(me, pub_key)
          |> then(&{:ok, &1})
        end
      )

    {_index, msg} = message

    FileIndex.save(chunk_key, pub_key, msg.id, chunk_secret)

    Rooms.on_saved(message, pub_key, fn ->
      broadcast_new_message(message, pub_key, me, time)
    end)

    socket
  end

  def show_new(
        %{assigns: %{room_identity: %Identity{} = identity}} = socket,
        {index, new_message}
      ) do
    verified_message = Rooms.read_message({index, new_message}, identity)

    if verified_message do
      socket
      |> assign(:page, 0)
      |> assign(:messages, [verified_message])
      |> assign(:message_update_mode, :append)
      |> push_event("chat:scroll-down", %{})
    else
      socket
    end
  end

  def show_new(socket, new_message) do
    identity = socket.assigns[:room_identity] |> inspect()
    message = new_message |> inspect()
    Logger.warn(["Cannot show new message in room. ", "msg: ", message, " room: ", identity])

    socket
  end

  def edit_message(
        %{assigns: %{room_identity: room_identity}} = socket,
        msg_id
      ) do
    content =
      Rooms.read_message(msg_id, room_identity)
      |> then(fn
        %{type: :text, content: text} ->
          text

        %{type: :memo, content: json} ->
          json |> StorageId.from_json() |> Memo.get()
      end)

    socket
    |> assign(:input_mode, :edit)
    |> assign(:edit_content, content)
    |> assign(:edit_message_id, msg_id)
    |> forget_current_messages()
    |> push_event("chat:focus", %{to: "#room-edit-input"})
  end

  def update_edited_message(
        %{
          assigns: %{
            room_identity: room_identity,
            room: room,
            me: me,
            edit_message_id: msg_id,
            monotonic_offset: time_offset
          }
        } = socket,
        text
      ) do
    time = Chat.Time.monotonic_to_unix(time_offset)

    text
    |> Messages.Text.new(0)
    |> Rooms.update_message(msg_id, me, room_identity)
    |> MemoIndex.add(room, room_identity)

    broadcast_message_updated(msg_id, room.pub_key, me, time)

    socket
    |> cancel_edit()
  end

  def update_message(
        %{assigns: %{room_identity: room_identity, my_id: my_id}} = socket,
        {_time, id} = msg_id,
        render_fun
      ) do
    content =
      Rooms.read_message(msg_id, room_identity)
      |> then(&%{msg: &1, my_id: my_id})
      |> render_to_html_string(render_fun)

    socket
    |> forget_current_messages()
    |> push_event("chat:change", %{to: "#room-message-#{id} .x-content", content: content})
  end

  def update_message(socket, msg_id, _) do
    identity = socket.assigns[:room_identity] |> inspect()

    Logger.warn([
      "Cannot show upated message in room. ",
      "msg_id: ",
      inspect(msg_id),
      " room: ",
      identity
    ])

    socket
  end

  def cancel_edit(socket) do
    socket
    |> assign(:input_mode, :plain)
    |> assign(:edit_content, nil)
    |> assign(:edit_message_id, nil)
  end

  def approve_request(%{assigns: %{room_identity: room_identity}} = socket, user_key) do
    Rooms.approve_request(room_identity |> Identity.pub_key(), user_key, room_identity)

    socket
    |> push_event("put-flash", %{key: :info, message: "Request approved!"})
  end

  def delete_messages(
        %{
          assigns: %{
            me: me,
            room_identity: room_identity,
            room: room,
            monotonic_offset: time_offset
          }
        } = socket,
        %{
          "messages" => messages
        }
      ) do
    time = Chat.Time.monotonic_to_unix(time_offset)

    messages
    |> Jason.decode!()
    |> Enum.each(fn %{"id" => msg_id, "index" => index} ->
      Rooms.delete_message({String.to_integer(index), msg_id}, room_identity, me)
      broadcast_deleted_message(msg_id, room.pub_key, me, time)
    end)

    socket
    |> assign(:input_mode, :plain)
  end

  def download_messages(
        %{assigns: %{my_id: my_id, room: room, room_identity: room_identity, timezone: timezone}} =
          socket,
        %{"messages" => messages}
      ) do
    messages_ids =
      messages
      |> Jason.decode!()
      |> Enum.map(fn %{"id" => message_id, "index" => index} ->
        {String.to_integer(index), message_id}
      end)

    key = Broker.store({:room, {messages_ids, room, my_id, room_identity}, timezone})

    push_event(socket, "chat:redirect", %{url: url(~p"/get/zip/#{key}")})
  end

  def hide_deleted_message(socket, id) do
    socket
    |> forget_current_messages()
    |> push_event("chat:toggle", %{to: "#message-block-#{id}", class: "hidden"})
  end

  def invite_user(
        %{assigns: %{room: %{name: room_name}, room_identity: identity, me: me}} = socket,
        user_key
      ) do
    dialog = Dialogs.find_or_open(me, user_key |> User.by_id())

    identity
    |> Map.put(:name, room_name)
    |> Messages.RoomInvite.new()
    |> Dialogs.add_new_message(me, dialog)
    |> RoomInviteIndex.add(dialog, me)

    socket
    |> push_event("put-flash", %{key: :info, message: "Invitation Sent!"})
  rescue
    _ -> socket
  end

  def close(%{assigns: %{room: nil}} = socket), do: socket

  def close(%{assigns: %{room: room}} = socket) do
    PubSub.unsubscribe(Chat.PubSub, room.pub_key |> room_topic())

    socket
    |> assign(:room, nil)
    |> assign(:room_requests, nil)
    |> assign(:edit_room, nil)
    |> assign(:room_identity, nil)
    |> assign(:messages, nil)
    |> assign(:message_update_mode, nil)
  end

  def close(socket), do: socket

  def download_message(
        %{assigns: %{room_identity: room_identity}} = socket,
        msg_id
      ) do
    msg_id
    |> Rooms.read_message(room_identity)
    |> maybe_redirect_to_file(socket)
  end

  defp maybe_redirect_to_file(%{type: type, content: json}, socket)
       when type in [:audio, :file, :image, :video] do
    {file_id, secret} = StorageId.from_json(json)
    params = %{a: Base.url_encode64(secret)}

    url =
      case type do
        :image ->
          params = Map.put(params, :download, true)
          ~p"/get/image/#{file_id}?#{params}"

        _ ->
          ~p"/get/file/#{file_id}?#{params}"
      end

    push_event(socket, "chat:redirect", %{url: url})
  end

  defp maybe_redirect_to_file(_message, socket), do: socket

  def toggle_messages_select(%{assigns: %{}} = socket, %{"action" => "on"}) do
    socket
    |> forget_current_messages()
    |> assign(:input_mode, :select)
    |> push_event("chat:toggle", %{to: "#chat-messages", class: "selectMode"})
  end

  def toggle_messages_select(%{assigns: %{input_mode: :select}} = socket, %{"action" => "off"}) do
    socket
    |> forget_current_messages()
    |> assign(:input_mode, :plain)
  end

  def open_image_gallery(socket, msg_id) do
    send_update(Layout.ImageGallery, id: "imageGallery", action: :open, incoming_msg_id: msg_id)
    socket
  end

  def image_gallery_preload_next(socket) do
    send_update(Layout.ImageGallery, id: "imageGallery", action: :preload_next)

    socket
  end

  def image_gallery_preload_prev(socket) do
    send_update(Layout.ImageGallery, id: "imageGallery", action: :preload_prev)

    socket
  end

  defp room_topic(pub_key) do
    pub_key
    |> Base.encode16(case: :lower)
    |> then(&"room:#{&1}")
  end

  defp assign_messages(socket, per_page \\ @per_page)

  defp assign_messages(%{assigns: %{has_more_messages: false}} = socket, _), do: socket

  defp assign_messages(
         %{
           assigns: %{
             room: room,
             room_identity: identity,
             last_load_timestamp: index
           }
         } = socket,
         per_page
       ) do
    messages = Rooms.read(room, identity, {index, 0}, per_page + 1)
    page_messages = Enum.take(messages, -per_page)

    socket
    |> assign(:messages, page_messages)
    |> assign(:has_more_messages, length(messages) > per_page)
    |> assign(:last_load_timestamp, set_messages_timestamp(page_messages))
  end

  defp assign_requests(%{assigns: %{room: %{type: :request} = room}} = socket) do
    request_list =
      room.pub_key
      |> Rooms.list_pending_requests()
      |> Enum.map(fn %RoomRequest{requester_key: pub_key} -> User.by_id(pub_key) end)

    socket
    |> assign(:room_requests, request_list)
  end

  defp assign_requests(socket), do: socket

  defp broadcast_message_updated(msg_id, pub_key, me, time) do
    {:updated_message, msg_id}
    |> room_broadcast(pub_key)

    Log.update_room_message(me, time, pub_key)
  end

  defp broadcast_new_message(message, pub_key, me, time) do
    {:new_message, message}
    |> room_broadcast(pub_key)

    Log.message_room(me, time, pub_key)
  end

  defp broadcast_deleted_message(msg_id, pub_key, me, time) do
    {:deleted_message, msg_id}
    |> room_broadcast(pub_key)

    Log.delete_room_message(me, time, pub_key)
  end

  defp room_broadcast(message, pub_key) do
    PubSub.broadcast!(
      Chat.PubSub,
      pub_key |> room_topic(),
      {:room, message}
    )
  end

  defp set_messages_timestamp([]), do: nil
  defp set_messages_timestamp([message | _]), do: message.index

  defp forget_current_messages(socket) do
    socket
    |> assign(:messages, [])
    |> assign(:message_update_mode, :append)
  end
end
