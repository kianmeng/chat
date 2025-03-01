defmodule ChatWeb.LiveHelpers.Uploader do
  @moduledoc """
  LiveView helper handling file upload.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Chat.{ChunkedFiles, ChunkedFilesMultisecret, FileIndex}
  alias Chat.Upload.{Upload, UploadIndex, UploadMetadata, UploadStatus, UploadSupervisor}
  alias ChatWeb.Endpoint
  alias ChatWeb.MainLive.Page
  alias ChatWeb.Router.Helpers
  alias Phoenix.LiveView.{Socket, UploadEntry}

  @max_concurrent_uploads 2

  @type entry :: UploadEntry.t()
  @type params :: map()
  @type uploader_data ::
          %{skip: true}
          | %{
              chunk_count: integer(),
              entrypoint: String.t(),
              status: atom(),
              uploader: String.t(),
              uuid: String.t()
            }
  @type socket :: Socket.t()

  @spec allow_file_upload(socket()) :: socket()
  def allow_file_upload(%Socket{} = socket) do
    socket
    |> allow_upload(:file,
      accept: :any,
      auto_upload: true,
      external: &__MODULE__.presign_url/2,
      max_entries: 2000,
      max_file_size: 102_400_000_000,
      progress: &__MODULE__.handle_progress/3
    )
    |> assign(:uploads_metadata, %{})
  end

  @spec cancel_upload(socket(), params()) :: socket()
  def cancel_upload(%Socket{} = socket, %{"ref" => ref, "uuid" => uuid}) do
    uploads = Map.get(socket.assigns, :uploads_metadata, %{})

    case Map.get(uploads, uuid) do
      %UploadMetadata{} = metadata ->
        {key, _secret} = metadata.credentials
        UploadStatus.stop(key)

        socket
        |> assign(:uploads_metadata, Map.delete(uploads, uuid))
        |> cancel_upload(:file, ref)
        |> maybe_resume_next_upload()

      nil ->
        socket
    end
  end

  @spec move_upload(socket(), params()) :: socket()
  def move_upload(%Socket{} = socket, %{"index" => new_index, "uuid" => uuid}) do
    uploads = socket.assigns.uploads
    entries = Map.get(uploads.file, :entries, [])

    case Enum.find_index(entries, &(&1.uuid == uuid)) do
      nil ->
        socket

      old_index ->
        {entry, entries} = List.pop_at(entries, old_index)
        entries = List.insert_at(entries, new_index, entry)
        uploads = update_in(uploads.file.entries, fn _old_entries -> entries end)
        assign(socket, :uploads, uploads)
    end
  end

  @spec pause_upload(socket(), params()) :: socket()
  def pause_upload(%Socket{} = socket, %{"uuid" => uuid}) do
    uploads = Map.get(socket.assigns, :uploads_metadata, %{})

    case Map.get(uploads, uuid) do
      %UploadMetadata{} ->
        metadata = Map.put(uploads[uuid], :status, :paused)

        {key, _secret} = metadata.credentials
        UploadStatus.put(key, :inactive)

        assign(socket, :uploads_metadata, Map.put(uploads, uuid, metadata))

      nil ->
        socket
    end
  end

  @spec resume_upload(socket(), params()) :: socket()
  def resume_upload(%Socket{} = socket, %{"uuid" => uuid}) do
    uploads = Map.get(socket.assigns, :uploads_metadata, %{})

    case Map.get(uploads, uuid) do
      %UploadMetadata{} ->
        metadata = Map.put(uploads[uuid], :status, :active)

        {key, _secret} = metadata.credentials
        UploadStatus.put(key, :active)

        socket
        |> assign(:uploads_metadata, Map.put(uploads, uuid, metadata))
        |> push_event("upload:resume", %{uuid: uuid})

      nil ->
        socket
    end
  end

  @spec presign_url(entry(), socket()) :: {:ok, uploader_data(), socket()}
  def presign_url(entry, socket) do
    upload_key = get_upload_key(entry, socket.assigns)

    {uploader_data, socket} =
      cond do
        secret = FileIndex.get(reader_hash(socket.assigns), upload_key) ->
          entry = Map.put(entry, :done?, true)

          metadata =
            %UploadMetadata{}
            |> Map.put(:credentials, {upload_key, secret})
            |> Map.put(:destination, file_upload_destination(socket.assigns))

          case metadata.destination.type do
            :dialog -> Page.Dialog.send_file(socket, entry, metadata)
            :room -> Page.Room.send_file(socket, entry, metadata)
          end

          {%{skip: true}, socket}

        upload_in_progress?(socket.assigns, upload_key) ->
          {%{skip: true}, socket}

        true ->
          {next_chunk, secret} = maybe_resume_existing_upload(upload_key, socket.assigns)

          initial_secret = ChunkedFiles.get_file(upload_key)
          ChunkedFilesMultisecret.generate(upload_key, entry.client_size, initial_secret)

          {socket, uploader_data} =
            start_chunked_upload(socket, entry, upload_key, secret, next_chunk)

          link =
            Helpers.upload_chunk_url(Endpoint, :put, upload_key |> Base.encode16(case: :lower))

          uploader_data = Map.merge(%{entrypoint: link, uuid: entry.uuid}, uploader_data)

          {uploader_data, socket}
      end

    uploader_data = Map.merge(%{uploader: "UpChunkUploader"}, uploader_data)

    {:ok, uploader_data, socket}
  end

  defp get_upload_key(%UploadEntry{} = entry, %{my_id: id} = assigns) do
    destination =
      assigns
      |> file_upload_destination()
      |> Jason.encode!()
      |> Base.encode64()

    [
      id,
      destination,
      entry.client_relative_path,
      entry.client_name,
      entry.client_type,
      entry.client_size,
      entry.client_last_modified
    ]
    |> Enum.join(":")
    |> Enigma.hash()
  end

  defp reader_hash(%{lobby_mode: :chats, peer: %{pub_key: peer_pub_key}}),
    do: peer_pub_key

  defp reader_hash(%{lobby_mode: :rooms, room: %{pub_key: room_pub_key}}),
    do: room_pub_key

  defp maybe_resume_existing_upload(upload_key, assigns) do
    case UploadIndex.get(upload_key) do
      nil ->
        secret =
          upload_key
          |> ChunkedFiles.new_upload()
          |> ChunkedFiles.encrypt_secret(assigns.me)

        add_upload_to_index(assigns, upload_key, secret)
        {0, secret}

      %Upload{} = upload ->
        UploadIndex.delete(upload_key)
        add_upload_to_index(assigns, upload_key, upload.secret)
        next_chunk = ChunkedFiles.next_chunk(upload_key)
        {next_chunk, upload.secret}
    end
  end

  defp add_upload_to_index(assigns, key, secret) do
    timestamp = Chat.Time.monotonic_to_unix(assigns.monotonic_offset)
    upload = %Upload{secret: secret, timestamp: timestamp}
    UploadIndex.add(key, upload)
  end

  defp upload_in_progress?(%{uploads_metadata: uploads} = _assigns, upload_key) do
    Enum.any?(uploads, fn {_uuid,
                           %UploadMetadata{
                             credentials: {key, _secret}
                           }} ->
      key == upload_key
    end)
  end

  @spec handle_progress(:file, entry(), socket()) :: {:noreply, socket()}
  def handle_progress(
        _name,
        %{progress: 100, uuid: uuid} = entry,
        %{assigns: %{uploads_metadata: uploads}} = socket
      ) do
    %UploadMetadata{} = metadata = uploads[uuid]
    {key, _} = metadata.credentials
    ChunkedFiles.mark_consumed(key)
    UploadIndex.delete(key)

    case metadata.destination.type do
      :dialog -> Page.Dialog.send_file(socket, entry, metadata)
      :room -> Page.Room.send_file(socket, entry, metadata)
    end

    {:noreply,
     socket
     |> assign(:uploads_metadata, Map.delete(uploads, uuid))
     |> maybe_resume_next_upload()}
  end

  def handle_progress(_name, _entry, socket), do: {:noreply, socket}

  defp start_chunked_upload(socket, entry, key, secret, next_chunk) do
    uploads = Map.get(socket.assigns, :uploads_metadata, %{})

    active_uploads =
      uploads
      |> Enum.filter(fn {_uuid, metadata} -> metadata.status == :active end)
      |> length()

    status =
      if active_uploads < @max_concurrent_uploads do
        :active
      else
        :pending
      end

    metadata =
      %UploadMetadata{}
      |> Map.put(:credentials, {key, secret})
      |> Map.put(:destination, file_upload_destination(socket.assigns))
      |> Map.put(:status, status)

    uploader_data = %{
      chunk_count: next_chunk,
      status: status
    }

    child_spec =
      UploadStatus.child_spec(
        key: key,
        status: if(status == :active, do: :active, else: :inactive)
      )

    DynamicSupervisor.start_child(UploadSupervisor, child_spec)

    {assign(socket, :uploads_metadata, Map.put(uploads, entry.uuid, metadata)), uploader_data}
  end

  defp file_upload_destination(%{
         dialog: dialog,
         lobby_mode: :chats,
         peer: %{pub_key: peer_pub_key}
       }),
       do: %{dialog: dialog, pub_key: peer_pub_key |> Base.encode16(case: :lower), type: :dialog}

  defp file_upload_destination(%{lobby_mode: :rooms, room: %{pub_key: room_pub_key}}),
    do: %{pub_key: room_pub_key |> Base.encode16(case: :lower), type: :room}

  defp maybe_resume_next_upload(%{assigns: %{uploads_metadata: uploads}} = socket) do
    active_uploads =
      uploads
      |> Enum.filter(fn {_uuid, metadata} -> metadata.status == :active end)
      |> length()

    next_entry =
      Enum.find(socket.assigns.uploads.file.entries, fn %UploadEntry{} = entry ->
        case Map.get(uploads, entry.uuid) do
          nil ->
            false

          %UploadMetadata{} = metadata ->
            entry.valid? and metadata.status == :pending
        end
      end)

    cond do
      active_uploads >= @max_concurrent_uploads ->
        socket

      is_nil(next_entry) ->
        socket

      true ->
        resume_upload(socket, %{"uuid" => next_entry.uuid})
    end
  end
end
