defmodule VR.AdminAudit.Event do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @actions ~w(admin.promote admin.demote account.delete)
  @outcomes ~w(succeeded denied)
  @reasons ~w(
    completed unauthorized recent_mfa_required account_deleted already_admin not_admin
    cannot_demote_self cannot_delete_self last_admin already_deleted audit_write_failed
  )

  @primary_key {:event_id, :binary_id, autogenerate: true}
  @derive {Jason.Encoder,
           only: [
             :event_id,
             :occurred_at,
             :action,
             :outcome,
             :reason,
             :actor_account_id,
             :target_account_id,
             :actor_email_masked,
             :target_email_masked,
             :request_id
           ]}

  schema "admin_audit_events" do
    field :occurred_at, :utc_datetime
    field :action, :string
    field :outcome, :string
    field :reason, :string
    field :actor_account_id, :string
    field :target_account_id, :string
    field :actor_email_masked, :string
    field :target_email_masked, :string
    field :request_id, :string
  end

  def actions, do: @actions
  def outcomes, do: @outcomes
  def reasons, do: @reasons

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :event_id,
      :occurred_at,
      :action,
      :outcome,
      :reason,
      :actor_account_id,
      :target_account_id,
      :actor_email_masked,
      :target_email_masked,
      :request_id
    ])
    |> validate_required([
      :occurred_at,
      :action,
      :outcome,
      :reason,
      :actor_account_id,
      :target_account_id,
      :actor_email_masked,
      :target_email_masked,
      :request_id
    ])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_inclusion(:reason, @reasons)
    |> validate_length(:actor_email_masked, max: 255)
    |> validate_length(:target_email_masked, max: 255)
    |> validate_length(:request_id, max: 255)
  end
end
