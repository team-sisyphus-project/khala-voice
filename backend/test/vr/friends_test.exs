defmodule VR.FriendsTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Friends

  setup do
    %{alice: account_fixture(name: "Alice"), bob: account_fixture(name: "Bob")}
  end

  describe "friendships" do
    test "stored as one row with an ordered pair", %{alice: alice, bob: bob} do
      {:ok, f} = Friends.create_friendship(alice.id, bob.id)
      assert f.account_a_id < f.account_b_id
    end

    test "creating in reverse order yields the same friendship", %{alice: alice, bob: bob} do
      {:ok, first} = Friends.create_friendship(alice.id, bob.id)
      {:ok, second} = Friends.create_friendship(bob.id, alice.id)
      assert first.id == second.id
    end

    test "both sides see each other as friends", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      assert Friends.friends?(alice.id, bob.id)
      assert Friends.friends?(bob.id, alice.id)
    end

    test "cannot befriend yourself", %{alice: alice} do
      assert {:error, changeset} = Friends.create_friendship(alice.id, alice.id)
      assert errors_on(changeset).account_b_id
      refute Friends.friends?(alice.id, alice.id)
    end

    test "each appears in the other's friends list", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      assert [%{id: id}] = Friends.list_friends(alice.id)
      assert id == bob.id
      assert [%{id: id}] = Friends.list_friends(bob.id)
      assert id == alice.id
    end

    test "blocking ends the friendship", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      {:ok, _} = Friends.block(alice.id, bob.id)

      refute Friends.friends?(alice.id, bob.id)
      assert Friends.list_friends(alice.id) == []
      assert Friends.list_friends(bob.id) == []
    end

    test "only the blocker can unblock", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      {:ok, _} = Friends.block(alice.id, bob.id)

      assert {:error, :not_blocker} = Friends.unblock(bob.id, alice.id)
      assert {:ok, _} = Friends.unblock(alice.id, bob.id)
      assert Friends.friends?(alice.id, bob.id)
    end

    test "friends can be removed", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      {:ok, _} = Friends.remove_friend(alice.id, bob.id)
      refute Friends.friends?(alice.id, bob.id)
    end
  end

  describe "creating invitations" do
    test "creates an email invitation", %{alice: alice} do
      assert {:ok, invitation, token} =
               Friends.create_invitation(alice, %{email: "new@example.test"})

      assert invitation.status == "pending"
      assert invitation.email == "new@example.test"
      assert is_binary(token)
    end

    test "link invitations carry no email", %{alice: alice} do
      assert {:ok, invitation, _token} = Friends.create_invitation(alice)
      assert is_nil(invitation.email)
    end

    test "the raw token is not stored in the DB", %{alice: alice} do
      {:ok, invitation, token} = Friends.create_invitation(alice)

      %{rows: [[stored]]} =
        VR.Repo.query!("SELECT token_hash FROM friend_invitations WHERE id = $1", [invitation.id])

      refute stored == token
      assert stored == :crypto.hash(:sha256, Base.url_decode64!(token, padding: false))
    end

    test "cannot invite yourself", %{alice: alice} do
      assert {:error, :cannot_invite_self} =
               Friends.create_invitation(alice, %{email: alice.email})
    end

    test "cannot invite an existing friend", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      assert {:error, :already_friends} = Friends.create_invitation(alice, %{email: bob.email})
    end

    test "cannot invite the same person twice", %{alice: alice, bob: bob} do
      {:ok, _, _} = Friends.create_invitation(alice, %{email: bob.email})
      assert {:error, :already_invited} = Friends.create_invitation(alice, %{email: bob.email})
    end
  end

  describe "accepting invitations" do
    test "accepting creates the friendship", %{alice: alice, bob: bob} do
      {:ok, _invitation, token} = Friends.create_invitation(alice, %{email: bob.email})

      assert {:ok, _friendship} = Friends.accept_invitation(token, bob)
      assert Friends.friends?(alice.id, bob.id)
    end

    test "anyone can accept a link invitation", %{alice: alice, bob: bob} do
      {:ok, _invitation, token} = Friends.create_invitation(alice)
      assert {:ok, _} = Friends.accept_invitation(token, bob)
      assert Friends.friends?(alice.id, bob.id)
    end

    test "the same token cannot be used twice", %{alice: alice, bob: bob} do
      {:ok, _, token} = Friends.create_invitation(alice)
      assert {:ok, _} = Friends.accept_invitation(token, bob)
      assert {:error, :not_pending} = Friends.accept_invitation(token, bob)
    end

    test "the inviter cannot accept their own invitation", %{alice: alice} do
      {:ok, _, token} = Friends.create_invitation(alice)
      assert {:error, :cannot_accept_own} = Friends.accept_invitation(token, alice)
    end

    test "rejects an invalid token", %{bob: bob} do
      assert {:error, :not_found} = Friends.accept_invitation("garbage", bob)
    end

    test "declining does not create the friendship", %{alice: alice, bob: bob} do
      {:ok, _, token} = Friends.create_invitation(alice, %{email: bob.email})
      assert {:ok, _} = Friends.decline_invitation(token, bob)
      refute Friends.friends?(alice.id, bob.id)
    end

    test "a cancelled invitation cannot be accepted", %{alice: alice, bob: bob} do
      {:ok, invitation, token} = Friends.create_invitation(alice, %{email: bob.email})
      {:ok, _} = Friends.cancel_invitation(invitation.id, alice)
      assert {:error, :not_pending} = Friends.accept_invitation(token, bob)
    end

    test "cannot cancel someone else's invitation", %{alice: alice, bob: bob} do
      {:ok, invitation, _} = Friends.create_invitation(alice)
      assert {:error, :not_owner} = Friends.cancel_invitation(invitation.id, bob)
    end
  end

  describe "listing invitations" do
    test "shows invitations I sent", %{alice: alice} do
      {:ok, _, _} = Friends.create_invitation(alice, %{email: "a@example.test"})
      {:ok, _, _} = Friends.create_invitation(alice, %{email: "b@example.test"})
      assert length(Friends.list_sent_invitations(alice.id)) == 2
    end

    test "shows invitations sent to my email", %{alice: alice, bob: bob} do
      {:ok, _, _} = Friends.create_invitation(alice, %{email: bob.email})
      assert [invitation] = Friends.list_received_invitations(bob)
      assert invitation.invited_by_id == alice.id
    end
  end
end
