defmodule Glimesh.Streams do
  @moduledoc """
  The Streams context. Contains Channels, Streams, Followers
  """

  import Ecto.Query, warn: false
  alias Glimesh.Accounts.User
  alias Glimesh.Chat
  alias Glimesh.Repo
  alias Glimesh.Streams.Category
  alias Glimesh.Streams.Channel
  alias Glimesh.Streams.Followers
  alias Glimesh.Streams.UserModerationLog
  alias Glimesh.Streams.UserModerator

  ## Broadcasting Functions

  def get_subscribe_topic(:channel, streamer_id), do: "streams:channel:#{streamer_id}"
  def get_subscribe_topic(:chat, streamer_id), do: "streams:chat:#{streamer_id}"
  def get_subscribe_topic(:chatters, streamer_id), do: "streams:chatters:#{streamer_id}"
  def get_subscribe_topic(:viewers, streamer_id), do: "streams:viewers:#{streamer_id}"

  def subscribe_to(topic_atom, streamer_id),
    do: sub_and_return(get_subscribe_topic(topic_atom, streamer_id))

  defp sub_and_return(topic), do: {Phoenix.PubSub.subscribe(Glimesh.PubSub, topic), topic}

  defp broadcast({:error, _reason} = error, _event), do: error

  defp broadcast({:ok, data}, :update_channel = event) do
    Phoenix.PubSub.broadcast(
      Glimesh.PubSub,
      get_subscribe_topic(:channel, data.user.id),
      {event, data}
    )

    {:ok, data}
  end

  defp broadcast_timeout({:error, _reason} = error, _event), do: error

  defp broadcast_timeout({:ok, streamer_id, bad_user}, :user_timedout) do
    Phoenix.PubSub.broadcast(
      Glimesh.PubSub,
      get_subscribe_topic(:chat, streamer_id),
      {:user_timedout, bad_user}
    )

    {:ok, bad_user}
  end

  ## Database getters

  def list_channels do
    Repo.all(
      from c in Channel,
        join: cat in Category,
        on: cat.id == c.category_id
    )
    |> Repo.preload([:category, :user])
  end

  def list_in_category(category) do
    Repo.all(
      from c in Channel,
        join: cat in Category,
        on: cat.id == c.category_id,
        where: c.status == "live",
        where: cat.id == ^category.id or cat.parent_id == ^category.id
    )
    |> Repo.preload([:category, :user])
  end

  def list_all_follows do
    Repo.all(from(f in Followers))
  end

  def list_followers(user) do
    Repo.all(from f in Followers, where: f.streamer_id == ^user.id) |> Repo.preload(:user)
  end

  def list_following(user) do
    Repo.all(from f in Followers, where: f.user_id == ^user.id)
  end

  def list_followed_channels(user) do
    Repo.all(
      from c in Channel,
        join: f in Followers,
        on: c.user_id == f.streamer_id,
        where: c.status == "live",
        where: f.user_id == ^user.id
    )
    |> Repo.preload([:category, :user])
  end

  def get_channel!(id) do
    Repo.get_by!(Channel, id: id) |> Repo.preload([:category, :user])
  end

  def get_channel_for_username!(username) do
    Repo.one(
      from c in Channel,
        join: u in User,
        on: c.user_id == u.id,
        where: u.username == ^username,
        where: c.inaccessible == false
    )
    |> Repo.preload([:category, :user])
  end

  def get_channel_for_stream_key!(stream_key) do
    Repo.one(
      from c in Channel,
        where: c.stream_key == ^stream_key and c.inaccessible == false
    )
    |> Repo.preload([:category, :user])
  end

  def get_channel_for_user!(user) do
    Repo.get_by(Channel, user_id: user.id) |> Repo.preload([:category, :user])
  end

  def create_channel(user, attrs \\ %{category_id: Enum.at(list_categories(), 0).id}) do
    %Channel{
      user: user
    }
    |> Channel.create_changeset(attrs)
    |> Repo.insert()
  end

  def delete_channel(channel) do
    attrs = %{inaccessible: true}

    channel
    |> Channel.changeset(attrs)
    |> Repo.update()
  end

  def update_channel(%Channel{} = channel, attrs) do
    new_channel =
      channel
      |> Channel.changeset(attrs)
      |> Repo.update()

    case new_channel do
      {:error, changeset} ->
        new_channel

      {:ok, changeset} ->
        broadcast_message = Repo.preload(changeset, :category, force: true)
        broadcast({:ok, broadcast_message}, :update_channel)
    end
  end

  def change_channel(%Channel{} = channel, attrs \\ %{}) do
    Channel.changeset(channel, attrs)
  end

  ## Moderation

  def add_moderator(streamer, moderator) do
    %UserModerator{
      streamer: streamer,
      user: moderator
    }
    |> UserModerator.changeset(%{
      :can_short_timeout => true,
      :can_long_timeout => true,
      :can_un_timeout => true,
      :can_ban => true,
      :can_unban => true
    })
    |> Repo.insert()
  end

  def timeout_user(streamer, moderator, user_to_timeout, time) do
    if Chat.can_moderate?(streamer, moderator) === false do
      raise "User does not have permission to moderate."
    end

    log =
      %UserModerationLog{
        streamer: streamer,
        moderator: moderator,
        user: user_to_timeout
      }
      |> UserModerationLog.changeset(%{action: "timeout"})
      |> Repo.insert()

    :ets.insert(:timedout_list, {user_to_timeout.username, {streamer.id, time}})

    Chat.delete_chat_messages_for_user(streamer, user_to_timeout)

    broadcast_timeout({:ok, streamer.id, user_to_timeout}, :user_timedout)

    log
  end

  def ban_user(streamer, moderator, user_to_ban) do
    if Chat.can_moderate?(streamer, moderator) === false do
      raise "User does not have permission to moderate."
    end

    log =
      %UserModerationLog{
        streamer: streamer,
        moderator: moderator,
        user: user_to_ban
      }
      |> UserModerationLog.changeset(%{action: "ban"})
      |> Repo.insert()

    :ets.insert(:banned_list, {user_to_ban.username, {streamer.id, true}})

    Chat.delete_chat_messages_for_user(streamer, user_to_ban)

    broadcast_chats({:ok, user_to_ban}, :user_banned, streamer)

    log
  end

  defp broadcast_chats({:error, _reason} = error, _event), do: error

  defp broadcast_chats({:ok, chat_message}, event, streamer) do
    Phoenix.PubSub.broadcast(Glimesh.PubSub, "chats:#{streamer.id}", {event, chat_message})
    {:ok, chat_message}
  end

  def list_followed_streams(user) do
    Repo.all(
      from f in Followers,
        where: f.user_id == ^user.id,
        join: streamer in assoc(f, :streamer),
        select: streamer
    )
  end

  ## Following

  def follow(streamer, user, live_notifications \\ false) do
    attrs = %{
      has_live_notifications: live_notifications
    }

    results =
      %Followers{
        streamer: streamer,
        user: user
      }
      |> Followers.changeset(attrs)
      |> Repo.insert()

    Glimesh.Chat.create_chat_message(streamer, user, %{message: "just followed the stream!"})

    results
  end

  def unfollow(streamer, user) do
    Repo.get_by(Followers, streamer_id: streamer.id, user_id: user.id) |> Repo.delete()
  end

  def is_following?(streamer, user) do
    Repo.exists?(
      from f in Followers, where: f.streamer_id == ^streamer.id and f.user_id == ^user.id
    )
  end

  def get_following(streamer, user) do
    Repo.one!(from f in Followers, where: f.streamer_id == ^streamer.id and f.user_id == ^user.id)
  end

  def count_followers(user) do
    Repo.one!(from f in Followers, select: count(f.id), where: f.streamer_id == ^user.id)
  end

  def count_following(user) do
    Repo.one!(from f in Followers, select: count(f.id), where: f.user_id == ^user.id)
  end

  ## Categories

  alias Glimesh.Streams.Category

  @doc """
  Returns the list of categories.

  ## Examples

      iex> list_categories()
      [%Category{}, ...]

  """
  def list_categories do
    Repo.all(Category) |> Repo.preload(:parent)
  end

  def list_categories_for_select do
    Repo.all(from c in Category, order_by: [asc: :tag_name])
    |> Enum.map(&{&1.tag_name, &1.id})
  end

  def list_parent_categories do
    Repo.all(from c in Category, where: is_nil(c.parent_id))
  end

  @spec list_categories_by_parent(atom | %{id: any}) :: any
  def list_categories_by_parent(category) do
    Repo.all(from c in Category, where: c.parent_id == ^category.id)
  end

  @doc """
  Gets a single category.

  Raises `Ecto.NoResultsError` if the Category does not exist.

  ## Examples

      iex> get_category!(123)
      %Category{}

      iex> get_category!(456)
      ** (Ecto.NoResultsError)

  """
  def get_category!(slug),
    do: Repo.one(from c in Category, where: c.slug == ^slug and is_nil(c.parent_id))

  def get_category_by_id!(id), do: Repo.get_by!(Category, id: id)

  @doc """
  Creates a category.

  ## Examples

      iex> create_category(%{field: value})
      {:ok, %Category{}}

      iex> create_category(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_category(attrs \\ %{}) do
    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a category.

  ## Examples

      iex> update_category(category, %{field: new_value})
      {:ok, %Category{}}

      iex> update_category(category, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_category(%Category{} = category, attrs) do
    category
    |> Category.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a category.

  ## Examples

      iex> delete_category(category)
      {:ok, %Category{}}

      iex> delete_category(category)
      {:error, %Ecto.Changeset{}}

  """
  def delete_category(%Category{} = category) do
    Repo.delete(category)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking category changes.

  ## Examples

      iex> change_category(category)
      %Ecto.Changeset{data: %Category{}}

  """
  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

  # Streams

  def get_stream!(id) do
    Repo.get_by!(Glimesh.Streams.Stream, id: id)
  end

  @doc """
  Starts a stream for a specific channel
  Only called very intentionally by Janus after stream authentication
  Also sends notifications
  """
  def start_stream(channel) do
    channel
  end

  @doc """
  Ends a stream for a specific channel
  Called either intentionally by Janus when the stream ends, or manually by the platform on a timer
  Archives the stream
  """
  def end_stream(channel) do
    channel
  end

  def create_stream(channel, attrs \\ %{}) do
    %Glimesh.Streams.Stream{
      channel: channel
    }
    |> Glimesh.Streams.Stream.changeset(attrs)
    |> Repo.insert()
  end

  def update_stream(%Glimesh.Streams.Stream{} = stream, attrs) do
    stream
    |> Glimesh.Streams.Stream.changeset(attrs)
    |> Repo.update()
  end
end
