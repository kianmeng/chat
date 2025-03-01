defmodule ChatWeb.MainLive.Index do
  @moduledoc "Main Liveview"
  use ChatWeb, :live_view

  require Logger

  alias Phoenix.LiveView.JS
  alias ChatWeb.Hooks.{LocalTimeHook, OnlinersSyncHook, UploaderHook}
  alias ChatWeb.MainLive.Admin.MediaSettingsForm
  alias ChatWeb.MainLive.{Layout, Page}

  on_mount LocalTimeHook
  on_mount UploaderHook
  on_mount OnlinersSyncHook

  @impl true
  def mount(
        params,
        %{"operating_system" => operating_system},
        %{assigns: %{live_action: action}} = socket
      ) do
    Process.flag(:sensitive, true)
    socket = assign(socket, :operating_system, operating_system)

    if connected?(socket) do
      if action == :export do
        socket
        |> assign(:need_login, false)
        |> Page.ExportKeyRing.init(params["id"])
        |> Page.Login.check_stored()
        |> ok()
      else
        socket
        |> assign(
          need_login: true,
          handshaked: false,
          mode: :user_list,
          monotonic_offset: 0
        )
        |> LocalTimeHook.assign_time(Phoenix.LiveView.get_connect_params(socket)["tz_info"])
        |> allow_any500m_upload(:my_keys_file)
        |> Page.Login.check_stored()
        |> ok()
      end
    else
      socket
      |> ok()
    end
  end

  @impl true
  def handle_event("login", %{"login" => %{"name" => name}}, socket) do
    socket
    |> Page.Login.create_user(name)
    |> Page.Lobby.init()
    |> Page.Dialog.init()
    |> Page.Logout.init()
    |> noreply()
  end

  def handle_event("restoreAuth", data, socket) when data == %{} do
    socket
    |> Page.Login.handshaked()
    |> noreply()
  end

  def handle_event("restoreAuth", data, %{assigns: %{live_action: :export}} = socket) do
    socket
    |> Page.Login.load_user(data)
    |> noreply()
  end

  def handle_event("restoreAuth", data, socket) do
    socket
    |> Page.Login.handshaked()
    |> Page.Login.load_user(data)
    |> Page.Lobby.init()
    |> Page.Dialog.init()
    |> Page.Logout.init()
    |> noreply()
  end

  def handle_event("client-timestamp", %{"timestamp" => timestamp}, socket) do
    socket
    |> assign(:monotonic_offset, timestamp |> Chat.Time.monotonic_offset())
    |> noreply()
  end

  def handle_event("login:request-key-ring", _, socket) do
    socket
    |> Page.Login.close()
    |> Page.ImportKeyRing.init()
    |> noreply()
  end

  def handle_event("login:import-own-key-ring", _, socket) do
    socket
    |> Page.Login.close()
    |> Page.ImportOwnKeyRing.init()
    |> noreply()
  end

  def handle_event("login:my-keys-file-submit", _, socket) do
    socket |> noreply()
  end

  def handle_event(
        "login:import-own-keyring-decrypt",
        %{"import_own_keyring_password" => %{"password" => password}},
        socket
      ) do
    socket
    |> Page.ImportOwnKeyRing.try_password(password)
    |> noreply()
  end

  def handle_event("login:import-own-keyring-reupload", _, socket) do
    socket
    |> Page.ImportOwnKeyRing.back_to_file()
    |> noreply()
  end

  def handle_event("login:import-own-keyring:drop-password-error", _, socket) do
    socket
    |> Page.ImportOwnKeyRing.drop_error()
    |> noreply()
  end

  def handle_event("login:import-keyring-close", _, socket) do
    socket
    |> Page.ImportKeyRing.close()
    |> assign(:need_login, true)
    |> noreply()
  end

  def handle_event("login:import-own-keyring-close", _, socket) do
    socket
    |> Page.ImportOwnKeyRing.close()
    |> assign(:need_login, true)
    |> noreply()
  end

  def handle_event("login:export-code-close", _, socket) do
    socket
    |> push_event("chat:redirect", %{url: Routes.main_index_path(socket, :index)})
    |> noreply()
  end

  def handle_event("switch-lobby-mode", %{"lobby-mode" => mode}, socket) do
    socket
    |> Page.Lobby.switch_lobby_mode(mode)
    |> Page.Room.init()
    |> noreply()
  end

  def handle_event("chat:load-more", _, %{assigns: %{dialog: %{}}} = socket) do
    socket
    |> Page.Dialog.load_more_messages()
    |> noreply()
  end

  def handle_event("chat:load-more", _, %{assigns: %{room: %{}}} = socket) do
    socket
    |> Page.Room.load_more_messages()
    |> noreply()
  end

  def handle_event("export-keys", %{"export_key_ring" => %{"code" => code}}, socket) do
    socket
    |> Page.ExportKeyRing.send_key_ring(code |> String.to_integer())
    |> noreply
  end

  def handle_event("feed-more", _, socket) do
    socket
    |> Page.Feed.more()
    |> noreply()
  end

  def handle_event("close-feeds", _, socket) do
    socket
    |> Page.Feed.close()
    |> noreply()
  end

  def handle_event("open-data-restore", _, socket) do
    socket
    |> assign(:mode, :restore_data)
    |> noreply()
  end

  def handle_event("backup-file-submit", _, socket), do: socket |> noreply()

  def handle_event("close-data-restore", _, socket) do
    socket
    |> assign(:mode, :lobby)
    |> noreply()
  end

  def handle_event("logout-open", _, socket) do
    socket
    |> Page.Logout.open()
    |> noreply()
  end

  def handle_event("logout-go-middle", _, socket) do
    socket
    |> Page.Logout.go_middle()
    |> noreply()
  end

  def handle_event("logout:toggle-password-visibility", _, socket) do
    socket
    |> Page.Logout.toggle_password_visibility()
    |> noreply()
  end

  def handle_event("logout:toggle-password-confirmation-visibility", _, socket) do
    socket
    |> Page.Logout.toggle_password_confirmation_visibility()
    |> noreply()
  end

  def handle_event("logout-download-insecure", _, socket) do
    socket
    |> Page.Logout.generate_backup("")
    |> Page.Logout.go_final()
    |> noreply()
  end

  def handle_event(
        "logout-download-with-password",
        %{"logout" => form},
        socket
      ) do
    socket
    |> Page.Logout.download_on_good_password(form)
    |> noreply()
  end

  def handle_event("logout-check-password", %{"logout" => form}, socket) do
    socket
    |> Page.Logout.check_password(form)
    |> noreply()
  end

  def handle_event("logout-wipe", _, socket) do
    socket
    |> Page.Login.clear()
    |> Page.Logout.wipe()
    |> noreply()
  end

  def handle_event("logout-close", _, socket) do
    socket
    |> Page.Logout.close()
    |> noreply()
  end

  def handle_event("dialog/" <> event, params, socket) do
    socket
    |> Page.DialogRouter.event({event, params})
    |> noreply()
  end

  def handle_event("room/" <> event, params, socket) do
    socket
    |> Page.RoomRouter.event({event, params})
    |> noreply()
  end

  def handle_event("admin/" <> event, params, socket) do
    socket
    |> Page.AdminPanelRouter.event({event, params})
    |> noreply()
  end

  def handle_event("put-flash", %{"key" => key, "message" => message}, socket) do
    socket
    |> put_flash(key, message)
    |> noreply()
  end

  @impl true
  def handle_info({:new_user, card}, socket) do
    socket
    |> Page.Lobby.show_new_user(card)
    |> noreply()
  end

  def handle_info({:new_room, card}, socket) do
    socket
    |> Page.Lobby.show_new_room(card)
    |> noreply()
  end

  def handle_info({:room_request, room_key, user_key}, socket) do
    socket
    |> Page.Lobby.approve_room_request(room_key, user_key)
    |> noreply()
  end

  def handle_info({:room_request_approved, encrypted_room_entity, user_key, room_key}, socket) do
    socket
    |> Page.Lobby.join_approved_room(encrypted_room_entity, user_key, room_key)
    |> noreply()
  end

  def handle_info({:sync_stored_room, key, room_count}, socket) do
    socket
    |> Page.Login.sync_stored_room(key, room_count)
    |> Page.Lobby.show_new_room(%{})
    |> noreply()
  end

  def handle_info(:reset_rooms_to_backup, socket) do
    socket
    |> Page.Login.reset_rooms_to_backup()
    |> noreply()
  end

  def handle_info({:exported_key_ring, keys}, socket) do
    socket
    |> Page.ImportKeyRing.save_key_ring(keys)
    |> Page.Login.store()
    |> Page.ImportKeyRing.close()
    |> Page.Lobby.init()
    |> Page.Logout.init()
    |> Page.Dialog.init()
    |> noreply()
  end

  def handle_info({:db_status, msg}, socket),
    do: socket |> Page.Lobby.set_db_status(msg) |> noreply()

  def handle_info({:room, msg}, socket),
    do: socket |> Page.RoomRouter.info(msg) |> noreply()

  def handle_info({:platform_response, msg}, socket),
    do: socket |> Page.AdminPanelRouter.info(msg) |> noreply()

  def handle_info({:dialog, msg}, socket), do: socket |> Page.DialogRouter.info(msg) |> noreply()

  def handle_info({ref, :ok}, socket) do
    Process.demonitor(ref, [:flush])

    socket |> noreply()
  end

  def handle_info({ref, {:error, task, _reason}}, socket) do
    Process.demonitor(ref, [:flush])

    socket
    |> Page.Lobby.process(task)
    |> noreply()
  end

  def handle_progress(:my_keys_file, %{done?: true}, socket) do
    socket
    |> Page.ImportOwnKeyRing.read_file()
    |> noreply()
  end

  def handle_progress(_file, _entry, socket) do
    socket |> noreply()
  end

  def loading_screen(assigns) do
    ~H"""
    <img class="vectorGroup bottomVectorGroup" src="/images/bottom_vector_group.svg" />
    <img class="vectorGroup topVectorGroup" src="/images/top_vector_group.svg" />

    <div class="flex flex-col items-center justify-center w-screen h-screen">
      <div class="container unauthenticated z-10">
        <img src="/images/logo.png" />
      </div>
    </div>
    """
  end

  def message_of(%{author_key: _}), do: "room"
  def message_of(_), do: "dialog"

  defp action_confirmation_popup(assigns) do
    ~H"""
    <.modal id={@id} class="">
      <h1 class="text-base font-bold text-grayscale"><%= @title %></h1>
      <p class="mt-3 text-sm text-black/50"><%= @description %></p>
      <div class="mt-5 flex items-center justify-between">
        <button phx-click={hide_modal(@id)} class="w-full mr-1 h-12 border rounded-lg border-black/10">
          Cancel
        </button>
        <button class="confirmButton w-full ml-1 h-12 border-0 rounded-lg bg-grayscale text-white flex items-center justify-center">
          Confirm
        </button>
      </div>
    </.modal>
    """
  end

  defp room_request_button(assigns) do
    ~H"""
    <button
      class="mr-4 flex items-center"
      phx-click={
        cond do
          @restricted -> show_modal("restrict-write-actions")
          @requests == [] -> nil
          true -> show_modal("room-request-list")
        end
      }
    >
      <.icon id="requestList" class="w-4 h-4 mr-1 z-20 stroke-white fill-white" />
      <span class="text-base text-white">Requests</span>
    </button>
    """
  end

  defp room_invite_button(assigns) do
    ~H"""
    <button
      class="flex items-center t-invite-btn"
      phx-click={
        cond do
          @restricted -> show_modal("restrict-write-actions")
          @users |> length == 1 -> nil
          true -> show_modal("room-invite-list")
        end
      }
    >
      <.icon id="share" class="w-4 h-4 mr-1 z-20 fill-white" />
      <span class="text-base text-white"> Invite</span>
    </button>
    """
  end

  defp room_count_to_backup_message(%{count: 0} = assigns), do: ~H""

  defp room_count_to_backup_message(assigns) do
    assigns =
      assigns
      |> assign_new(:output, fn
        %{count: 1} -> "1 room"
        %{count: count} -> "#{count} rooms"
      end)

    ~H"""
    <p class="mt-3 text-sm text-red-500">
      You have <%= @output %> not backed up. Download the keys to make sure you have access to them after logging out.
    </p>
    """
  end

  defp allow_any500m_upload(socket, type, opts \\ []) do
    socket
    |> allow_upload(type,
      auto_upload: true,
      max_file_size: 1_024_000_000,
      accept: :any,
      max_entries: Keyword.get(opts, :max_entries, 1),
      progress: &handle_progress/3
    )
  end
end
