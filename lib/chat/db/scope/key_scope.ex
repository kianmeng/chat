defmodule Chat.Db.Scope.KeyScope do
  @moduledoc """
  Builds db keys accessible by keys_list
  """

  alias Chat.Dialogs.Dialog

  def get_keys(db, pub_keys_list) do
    pub_keys = MapSet.new(pub_keys_list)

    CubDB.with_snapshot(db, fn snap ->
      MapSet.new()
      |> add_full_users(snap)
      |> add_dialogs(snap, pub_keys)
      |> add_rooms(snap, pub_keys)
      |> add_content(snap, pub_keys)
    end)
  end

  defp add_full_users(acc_set, snap) do
    snap
    |> db_keys_stream({:users, 0}, {:"users\0", 0})
    |> union_set(acc_set)
  end

  defp add_dialogs(acc_set, snap, pub_keys) do
    dialog_keys =
      snap
      |> db_stream({:dialogs, 0}, {:"dialogs\0", 0})
      |> Stream.filter(fn {_full_dilaog_key, %Dialog{a_key: a_key, b_key: b_key}} ->
        MapSet.member?(pub_keys, a_key) or MapSet.member?(pub_keys, b_key)
      end)
      |> Stream.map(fn {dialog_key, _dialog} -> dialog_key end)
      |> MapSet.new()

    dialog_binkeys =
      dialog_keys
      |> Enum.map(fn {:dialogs, dialog_key} -> dialog_key end)
      |> MapSet.new()

    snap
    |> db_keys_stream({:dialog_message, 0, 0, 0}, {:"dialog_message\0", 0, 0, 0})
    |> Stream.filter(fn {:dialog_message, key, _, _} ->
      MapSet.member?(dialog_binkeys, key)
    end)
    |> union_set(dialog_keys)
    |> union_set(acc_set)
  end

  defp add_rooms(acc_set, snap, pub_keys) do
    with_rooms =
      snap
      |> db_keys_stream({:rooms, 0}, {:"rooms\0", 0})
      |> Stream.filter(fn {:rooms, key} ->
        MapSet.member?(pub_keys, key)
      end)
      |> union_set(acc_set)

    snap
    |> db_keys_stream({:room_message, 0, 0, 0}, {:"room_message\0", 0, 0, 0})
    |> Stream.filter(fn {:room_message, room_key, _, _} ->
      MapSet.member?(pub_keys, room_key)
    end)
    |> union_set(with_rooms)
  end

  defp add_content(acc_set, snap, pub_keys) do
    [file_index, file_keys, files] =
      fetch_index_and_records(
        snap,
        pub_keys,
        "file",
        min_key: {:file_index, 0, 0, 0},
        max_key: {:"file_index\0", 0, 0, 0},
        reader_hash_getter: fn {:file_index, reader_key, _file_key, _message_id} ->
          reader_key
        end,
        record_key_getter: fn {:file_index, _reader_key, file_key, _message_id} -> file_key end
      )

    chunk_keys =
      snap
      |> db_keys_stream(
        {:chunk_key, {:file_chunk, 0, 0, 0}},
        {:chunk_key, {:"file_chunk\0", 0, 0, 0}}
      )
      |> Stream.filter(fn {:chunk_key, {:file_chunk, file_key, _chunk_start, _chunk_end}} ->
        MapSet.member?(file_keys, file_key)
      end)
      |> MapSet.new()

    file_chunks =
      chunk_keys
      |> Enum.map(fn {:chunk_key, file_chunk_key} -> file_chunk_key end)
      |> MapSet.new()

    [memo_index, _memo_keys, memos] =
      fetch_index_and_records(
        snap,
        pub_keys,
        "memo",
        min_key: {:memo_index, 0, 0},
        max_key: {:"memo_index\0", 0, 0},
        reader_hash_getter: fn {:memo_index, reader_key, _memo_key} -> reader_key end,
        record_key_getter: fn {:memo_index, _reader_key, memo_key} -> memo_key end
      )

    [room_invite_index, _room_invite_keys, room_invites] =
      fetch_index_and_records(
        snap,
        pub_keys,
        "room_invite",
        min_key: {:room_invite_index, 0, 0},
        max_key: {:"room_invite_index\0", 0, 0},
        reader_hash_getter: fn {:room_invite_index, reader_key, _invite_key} -> reader_key end,
        record_key_getter: fn {:room_invite_index, _reader_key, invite_key} -> invite_key end
      )

    acc_set
    |> union_set(chunk_keys)
    |> union_set(file_index)
    |> union_set(file_chunks)
    |> union_set(files)
    |> union_set(memo_index)
    |> union_set(memos)
    |> union_set(room_invite_index)
    |> union_set(room_invites)
  end

  defp db_keys_stream(snap, min, max) do
    snap
    |> db_stream(min, max)
    |> Stream.map(&just_keys/1)
  end

  defp db_stream(snap, min, max) do
    CubDB.Snapshot.select(snap, min_key: min, max_key: max)
  end

  defp union_set(list, set) do
    list
    |> MapSet.new()
    |> MapSet.union(set)
  end

  defp just_keys({k, _v}), do: k

  defp fetch_index_and_records(snap, pub_keys, record_name, opts) do
    reader_hash_getter = opts[:reader_hash_getter]
    record_key_getter = opts[:record_key_getter]

    index =
      snap
      |> db_keys_stream(opts[:min_key], opts[:max_key])
      |> Stream.filter(fn key ->
        reader_hash = reader_hash_getter.(key)
        MapSet.member?(pub_keys, reader_hash)
      end)
      |> MapSet.new()

    keys =
      index
      |> Enum.map(&record_key_getter.(&1))
      |> MapSet.new()

    records =
      snap
      |> db_keys_stream({:"#{record_name}", 0}, {:"#{record_name}\0", 0})
      |> Stream.filter(fn {_record_name, record_key} ->
        MapSet.member?(keys, record_key)
      end)
      |> MapSet.new()

    [index, keys, records]
  end
end
