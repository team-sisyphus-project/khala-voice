defmodule VR.FriendsTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.Friends

  setup do
    %{alice: account_fixture(name: "Alice"), bob: account_fixture(name: "Bob")}
  end

  describe "친구 관계" do
    test "정렬된 쌍 한 행으로 저장된다", %{alice: alice, bob: bob} do
      {:ok, f} = Friends.create_friendship(alice.id, bob.id)
      assert f.account_a_id < f.account_b_id
    end

    test "순서를 바꿔 만들어도 같은 관계다", %{alice: alice, bob: bob} do
      {:ok, first} = Friends.create_friendship(alice.id, bob.id)
      {:ok, second} = Friends.create_friendship(bob.id, alice.id)
      assert first.id == second.id
    end

    test "양쪽 모두에서 친구로 보인다", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      assert Friends.friends?(alice.id, bob.id)
      assert Friends.friends?(bob.id, alice.id)
    end

    test "자기 자신과는 친구가 될 수 없다", %{alice: alice} do
      assert {:error, changeset} = Friends.create_friendship(alice.id, alice.id)
      assert errors_on(changeset).account_b_id
      refute Friends.friends?(alice.id, alice.id)
    end

    test "친구 목록에 서로가 나온다", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      assert [%{id: id}] = Friends.list_friends(alice.id)
      assert id == bob.id
      assert [%{id: id}] = Friends.list_friends(bob.id)
      assert id == alice.id
    end

    test "차단하면 친구가 아니게 된다", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      {:ok, _} = Friends.block(alice.id, bob.id)

      refute Friends.friends?(alice.id, bob.id)
      assert Friends.list_friends(alice.id) == []
      assert Friends.list_friends(bob.id) == []
    end

    test "차단을 건 쪽만 풀 수 있다", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      {:ok, _} = Friends.block(alice.id, bob.id)

      assert {:error, :not_blocker} = Friends.unblock(bob.id, alice.id)
      assert {:ok, _} = Friends.unblock(alice.id, bob.id)
      assert Friends.friends?(alice.id, bob.id)
    end

    test "친구를 끊을 수 있다", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      {:ok, _} = Friends.remove_friend(alice.id, bob.id)
      refute Friends.friends?(alice.id, bob.id)
    end
  end

  describe "초대 생성" do
    test "이메일 초대를 만든다", %{alice: alice} do
      assert {:ok, invitation, token} =
               Friends.create_invitation(alice, %{email: "new@example.test"})

      assert invitation.status == "pending"
      assert invitation.email == "new@example.test"
      assert is_binary(token)
    end

    test "링크 초대는 이메일이 없다", %{alice: alice} do
      assert {:ok, invitation, _token} = Friends.create_invitation(alice)
      assert is_nil(invitation.email)
    end

    test "원본 토큰을 DB에 저장하지 않는다", %{alice: alice} do
      {:ok, invitation, token} = Friends.create_invitation(alice)

      %{rows: [[stored]]} =
        VR.Repo.query!("SELECT token_hash FROM friend_invitations WHERE id = $1", [invitation.id])

      refute stored == token
      assert stored == :crypto.hash(:sha256, Base.url_decode64!(token, padding: false))
    end

    test "자기 자신은 초대할 수 없다", %{alice: alice} do
      assert {:error, :cannot_invite_self} =
               Friends.create_invitation(alice, %{email: alice.email})
    end

    test "이미 친구면 초대할 수 없다", %{alice: alice, bob: bob} do
      {:ok, _} = Friends.create_friendship(alice.id, bob.id)
      assert {:error, :already_friends} = Friends.create_invitation(alice, %{email: bob.email})
    end

    test "같은 사람에게 중복 초대할 수 없다", %{alice: alice, bob: bob} do
      {:ok, _, _} = Friends.create_invitation(alice, %{email: bob.email})
      assert {:error, :already_invited} = Friends.create_invitation(alice, %{email: bob.email})
    end
  end

  describe "초대 수락" do
    test "수락하면 친구가 된다", %{alice: alice, bob: bob} do
      {:ok, _invitation, token} = Friends.create_invitation(alice, %{email: bob.email})

      assert {:ok, _friendship} = Friends.accept_invitation(token, bob)
      assert Friends.friends?(alice.id, bob.id)
    end

    test "링크 초대는 누구든 수락할 수 있다", %{alice: alice, bob: bob} do
      {:ok, _invitation, token} = Friends.create_invitation(alice)
      assert {:ok, _} = Friends.accept_invitation(token, bob)
      assert Friends.friends?(alice.id, bob.id)
    end

    test "같은 토큰을 두 번 쓸 수 없다", %{alice: alice, bob: bob} do
      {:ok, _, token} = Friends.create_invitation(alice)
      assert {:ok, _} = Friends.accept_invitation(token, bob)
      assert {:error, :not_pending} = Friends.accept_invitation(token, bob)
    end

    test "초대자가 자기 초대를 수락할 수 없다", %{alice: alice} do
      {:ok, _, token} = Friends.create_invitation(alice)
      assert {:error, :cannot_accept_own} = Friends.accept_invitation(token, alice)
    end

    test "잘못된 토큰은 거부한다", %{bob: bob} do
      assert {:error, :not_found} = Friends.accept_invitation("garbage", bob)
    end

    test "거절하면 친구가 되지 않는다", %{alice: alice, bob: bob} do
      {:ok, _, token} = Friends.create_invitation(alice, %{email: bob.email})
      assert {:ok, _} = Friends.decline_invitation(token, bob)
      refute Friends.friends?(alice.id, bob.id)
    end

    test "취소한 초대는 수락할 수 없다", %{alice: alice, bob: bob} do
      {:ok, invitation, token} = Friends.create_invitation(alice, %{email: bob.email})
      {:ok, _} = Friends.cancel_invitation(invitation.id, alice)
      assert {:error, :not_pending} = Friends.accept_invitation(token, bob)
    end

    test "남의 초대를 취소할 수 없다", %{alice: alice, bob: bob} do
      {:ok, invitation, _} = Friends.create_invitation(alice)
      assert {:error, :not_owner} = Friends.cancel_invitation(invitation.id, bob)
    end
  end

  describe "초대 목록" do
    test "보낸 초대를 본다", %{alice: alice} do
      {:ok, _, _} = Friends.create_invitation(alice, %{email: "a@example.test"})
      {:ok, _, _} = Friends.create_invitation(alice, %{email: "b@example.test"})
      assert length(Friends.list_sent_invitations(alice.id)) == 2
    end

    test "내 이메일로 온 초대를 본다", %{alice: alice, bob: bob} do
      {:ok, _, _} = Friends.create_invitation(alice, %{email: bob.email})
      assert [invitation] = Friends.list_received_invitations(bob)
      assert invitation.invited_by_id == alice.id
    end
  end
end
