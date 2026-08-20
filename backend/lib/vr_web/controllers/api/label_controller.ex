defmodule VRWeb.API.LabelController do
  @moduledoc """
  라벨 CRUD. 응답 규칙은 `VRWeb.API.TopicController` 와 같다 — 없는 것도 남의 것도 404.
  """

  use VRWeb, :controller

  alias VR.Taxonomy
  alias VR.Taxonomy.Label
  alias VRWeb.API.JSONView

  action_fallback VRWeb.API.FallbackController

  def index(conn, _params) do
    account = conn.assigns.current_account
    json(conn, %{labels: Enum.map(Taxonomy.list_labels_with_counts(account), &JSONView.label/1)})
  end

  def create(conn, params) do
    account = conn.assigns.current_account

    with {:ok, label} <- Taxonomy.create_label(account, Map.take(params, ~w(name color))) do
      conn |> put_status(:created) |> json(JSONView.label(label))
    end
  end

  def update(conn, %{"id" => id} = params) do
    account = conn.assigns.current_account

    with %Label{} = label <- Taxonomy.get_label(account.id, id),
         {:ok, updated} <- Taxonomy.update_label(label, Map.take(params, ~w(name color))) do
      json(conn, JSONView.label(updated))
    end
  end

  def delete(conn, %{"id" => id}) do
    account = conn.assigns.current_account

    with %Label{} = label <- Taxonomy.get_label(account.id, id),
         {:ok, %{detached_meetings: count}} <- Taxonomy.delete_label(label) do
      json(conn, %{status: "ok", detached_meetings: count})
    end
  end
end
