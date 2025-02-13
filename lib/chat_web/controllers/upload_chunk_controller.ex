defmodule ChatWeb.UploadChunkController do
  @moduledoc "Serve files"
  use ChatWeb, :controller
  require Logger

  alias Chat.ChunkedFiles
  alias Chat.Upload.UploadStatus

  def put(conn, params) do
    with %{"key" => text_key} <- params,
         {:ok, key} <- Base.decode16(text_key, case: :lower),
         {:ok, chunk, conn} <- read_out_chunk(conn),
         [range] <- get_req_header(conn, "content-range"),
         {range_start, range_end, size} <- parse_range(range),
         true <- upload_is_active?(key),
         :ok <- save_chunk_till({key, {range_start, range_end}, size, chunk}, time_mark() + 20) do
      conn
      |> send_resp(200, "")
    else
      e ->
        Logger.error("[upload] error processing chunk " <> inspect(e))

        conn
        |> send_resp(503, "Busy")
    end
  end

  defp upload_is_active?(key) do
    case UploadStatus.get(key) do
      :active ->
        true

      _status ->
        {:error, "upload is inactive"}
    end
  end

  defp save_chunk_till({key, range, size, chunk} = data, till) do
    if ChunkedFiles.save_upload_chunk(key, range, size, chunk) == :ok do
      # Logger.debug("+")
      :ok
    else
      # Logger.debug("_")
      Process.sleep(100)
      save_chunk_till(data, till)
    end

    # Slows down upload tremendeously
    #
    # time_mark() > till ->
    #   # Logger.debug("-")
    #   :failed
  end

  defp time_mark, do: System.monotonic_time(:second)

  defp read_out_chunk(conn, acc \\ [""]) do
    case read_body(conn) do
      {:ok, data, conn} ->
        {:ok, IO.iodata_to_binary([acc, data]), conn}

      {:more, chunk, conn} ->
        read_out_chunk(conn, [acc, chunk])
    end
  end

  defp parse_range("bytes " <> str) do
    [range, size] = String.split(str, "/", parts: 2)

    [range_start, range_end] =
      range
      |> String.split("-", parts: 2)
      |> Enum.map(&String.to_integer/1)

    {range_start, range_end, size |> String.to_integer()}
  end
end
