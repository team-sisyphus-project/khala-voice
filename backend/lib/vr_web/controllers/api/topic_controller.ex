defmodule VRWeb.API.TopicController do
  @moduledoc """
  Topic CRUD.

  **Someone else's topic and a nonexistent topic get the same response (404).**
  A 403 would leak "that id exists — it's just not yours."
  """

  use VRWeb, :controller

  alias VR.Taxonomy
  alias VR.Taxonomy.Topic
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  def index(conn, _params) do
    account = conn.assigns.current_account
    json(conn, %{topics: Enum.map(Taxonomy.list_topics_with_counts(account), &JSONView.topic/1)})
  end

  def create(conn, params) do
    account = conn.assigns.current_account

    with {:ok, topic} <- Taxonomy.create_topic(account, Map.take(params, ~w(name color))) do
      conn |> put_status(:created) |> json(JSONView.topic(topic))
    end
  end

  def update(conn, %{"id" => id} = params) do
    account = conn.assigns.current_account

    with %Topic{} = topic <- Taxonomy.get_topic(account.id, id),
         {:ok, updated} <- Taxonomy.update_topic(topic, Map.take(params, ~w(name color))) do
      json(conn, JSONView.topic(updated))
    end
  end

  def delete(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with %Topic{} = topic <- Taxonomy.get_topic(account.id, id),
         {:ok, %{detached_meetings: count}} <- Taxonomy.delete_topic(topic) do
      json(conn, %{status: "ok", detached_meetings: count})
    end
  end

  @doc "Reorder. Accepts **the entire list at once.**"
  def reorder(conn, %{"ids" => ids}) when is_list(ids) do
    account = conn.assigns.current_account

    with {:ok, topics} <- Taxonomy.reorder_topics(account, ids) do
      json(conn, %{topics: Enum.map(topics, &JSONView.topic/1)})
    end
  end

  def reorder(_conn, _params), do: {:error, :invalid_request}
end
