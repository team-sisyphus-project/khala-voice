defmodule VR.SharingTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.{Meetings, Sharing}
  alias VR.Sharing.SharedLink

  setup do
    owner = account_fixture()
    {:ok, meeting} = Meetings.create_meeting(owner, %{title: "공유할 회의"})

    {:ok, meeting} =
      Meetings.update_permissions(meeting, %{guest_link_enabled: true})

    %{owner: owner, meeting: meeting}
  end

  defp issue(ctx, attrs \\ %{}) do
    {:ok, link, token, pin} = Sharing.issue_link(ctx.meeting, ctx.owner, attrs)
    %{link: link, token: token, pin: pin}
  end

  describe "발급" do
    test "id 와 토큰에 접두사가 붙는다", ctx do
      %{link: link, token: token} = issue(ctx)

      assert String.starts_with?(link.id, "slnk_")
      assert String.starts_with?(token, "slt_")
    end

    test "평문 토큰이 DB 어디에도 없다", ctx do
      %{token: token} = issue(ctx)

      # 토큰은 추가 인증 없이 통하는 자격증명이다. DB 를 본 사람이 곧 방문자가 되면 안 된다.
      raw = String.replace_prefix(token, "slt_", "")

      dumped =
        Repo.all(SharedLink)
        |> Enum.map(&inspect(&1, limit: :infinity, printable_limit: :infinity))
        |> Enum.join("\n")

      refute String.contains?(dumped, raw)
      refute String.contains?(dumped, token)
    end

    test "PIN 을 켜면 평문은 발급 응답에만 있다", ctx do
      %{link: link, pin: pin} = issue(ctx, %{"with_pincode" => true})

      assert String.match?(pin, ~r/^\d{6}$/)
      assert link.pin_hash
      refute String.contains?(link.pin_hash, pin)
    end

    test "PIN 없이 발급하면 pin_hash 가 없다", ctx do
      %{link: link, pin: pin} = issue(ctx)

      assert is_nil(pin)
      assert is_nil(link.pin_hash)
    end

    test "reviewer 역할은 줄 수 없다", ctx do
      # 링크 하나로 삭제 권한까지 넘어가지 않는다
      assert {:error, changeset} =
               Sharing.issue_link(ctx.meeting, ctx.owner, %{"granted_role" => "reviewer"})

      assert %{granted_role: _} = errors_on(changeset)
    end

    test "요청 본문으로 사용 횟수나 토큰을 정할 수 없다", ctx do
      {:ok, link, _token, _pin} =
        Sharing.issue_link(ctx.meeting, ctx.owner, %{
          "use_count" => 99,
          "token_hash" => "가짜",
          "id" => "slnk_내가정한id",
          "meeting_id" => "meet_남의회의"
        })

      assert link.use_count == 0
      assert link.id != "slnk_내가정한id"
      assert link.meeting_id == ctx.meeting.id
    end

    test "지난 만료 시각은 거부한다", ctx do
      past = DateTime.add(DateTime.utc_now(:second), -60, :second)

      assert {:error, _} =
               Sharing.issue_link(ctx.meeting, ctx.owner, %{"expires_at" => past})
    end
  end

  describe "역할은 나중에 올릴 수 없다" do
    test "update_link 로 granted_role 을 바꿔도 무시된다", ctx do
      # 이미 배포된 viewer 링크를 contributor 로 올리면
      # 그 링크를 받은 모두의 권한이 소급 상승한다
      %{link: link} = issue(ctx, %{"granted_role" => "viewer"})

      {:ok, updated} = Sharing.update_link(link, %{"granted_role" => "contributor"})

      assert updated.granted_role == "viewer"
    end
  end

  describe "사용 횟수" do
    test "동시에 들어와도 max_uses 를 넘지 않는다", ctx do
      %{link: link} = issue(ctx, %{"max_uses" => 1})

      # ⚠ 샌드박스 소유자는 **테스트 프로세스**다. 태스크 안에서 `self()` 를 소유자로
      # 넘기면 그 연결이 샌드박스 밖으로 나가 테스트 DB 에 실제로 커밋된다.
      owner = self()

      results =
        1..8
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(VR.Repo, owner, self())
            Sharing.consume_use(link)
          end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # 검사와 증가가 한 문장이라 경합에서도 정확히 하나만 통과한다
      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :gone}, &1)) == 7
    end

    test "소진되면 더 못 들어온다", ctx do
      %{link: link} = issue(ctx, %{"max_uses" => 1})

      assert {:ok, _} = Sharing.consume_use(link)
      assert {:error, :gone} = Sharing.consume_use(link)
    end
  end

  describe "입장" do
    test "게스트 토큰을 받고 그 회의에만 묶인다", ctx do
      %{token: token} = issue(ctx, %{"granted_role" => "contributor"})

      assert {:ok, result} = Sharing.enter(token, %{"display_name" => "손님"})
      assert result.mode == :guest
      assert String.starts_with?(result.guest_token, "gst_")
      assert result.meeting_id == ctx.meeting.id

      {:ok, session} = Sharing.fetch_live_guest(result.guest_token)
      assert session.meeting_id == ctx.meeting.id
      assert session.granted_role == "contributor"
    end

    test "이름이 필요하면 없이는 못 들어온다", ctx do
      %{token: token} = issue(ctx, %{"require_name" => true})

      assert {:error, changeset} = Sharing.enter(token, %{})
      assert %{display_name: _} = errors_on(changeset)
    end

    test "이름을 안 받는 링크는 그냥 들어온다", ctx do
      %{token: token} = issue(ctx, %{"require_name" => false})
      assert {:ok, %{mode: :guest}} = Sharing.enter(token, %{})
    end

    test "회의 스위치가 꺼져 있으면 404 (410 이 아니다)", ctx do
      {:ok, _} = Meetings.update_permissions(ctx.meeting, %{guest_link_enabled: false})
      %{token: token} = issue(ctx, %{"require_name" => false})

      # 링크가 유효했다는 사실도 노출하지 않는다
      assert {:error, :not_found} = Sharing.enter(token, %{})
    end

    test "없는 토큰은 404", ctx do
      _ = ctx
      assert {:error, :not_found} = Sharing.enter("slt_없는토큰", %{})
      assert {:error, :not_found} = Sharing.enter("형식도아님", %{})
    end

    test "폐기된 링크는 410", ctx do
      %{link: link, token: token} = issue(ctx, %{"require_name" => false})
      {:ok, _} = Sharing.revoke_link(link)

      assert {:error, :gone} = Sharing.enter(token, %{})
    end

    test "세션 생성이 실패하면 사용 횟수가 타지 않는다", ctx do
      # 1회성 링크가 이름 누락 한 번으로 죽어버리면 안 된다
      %{link: link, token: token} = issue(ctx, %{"max_uses" => 1, "require_name" => true})

      assert {:error, _} = Sharing.enter(token, %{})
      assert Sharing.get_link(link.id).use_count == 0

      assert {:ok, %{mode: :guest}} = Sharing.enter(token, %{"display_name" => "손님"})
      assert Sharing.get_link(link.id).use_count == 1
    end

    test "로그인한 계정은 게스트 세션을 만들지 않는다", ctx do
      %{token: token} = issue(ctx, %{"require_name" => false})

      assert {:ok, result} = Sharing.enter(token, %{}, account: ctx.owner)
      assert result.mode == :account
      assert is_nil(result.guest_token)
      # 사용 횟수도 타지 않는다
      assert Sharing.fetch_by_token(token) |> elem(1) |> Map.get(:use_count) == 0
    end
  end

  describe "PIN" do
    test "맞으면 통과한다", ctx do
      %{link: link, pin: pin} = issue(ctx, %{"with_pincode" => true})
      assert :ok = Sharing.verify_pincode(link, pin, "1.2.3.4")
    end

    test "틀리면 거부한다", ctx do
      %{link: link} = issue(ctx, %{"with_pincode" => true})
      assert {:error, :invalid_pincode} = Sharing.verify_pincode(link, "000000", "1.2.3.4")
    end

    test "PIN 을 안 내도 거부한다", ctx do
      %{link: link} = issue(ctx, %{"with_pincode" => true})
      assert {:error, :invalid_pincode} = Sharing.verify_pincode(link, nil, "1.2.3.4")
    end

    test "5회 틀리면 잠기고 정답도 안 통한다", ctx do
      %{link: link, pin: pin} = issue(ctx, %{"with_pincode" => true})

      for _ <- 1..5 do
        assert {:error, :invalid_pincode} =
                 Sharing.verify_pincode(Sharing.get_link(link.id), "000000", "9.9.9.9")
      end

      locked = Sharing.get_link(link.id)
      assert {:error, :locked} = Sharing.verify_pincode(locked, pin, "9.9.9.9")
    end

    test "PIN 없는 링크는 무엇을 내도 통과한다", ctx do
      %{link: link} = issue(ctx)
      assert :ok = Sharing.verify_pincode(link, nil, "1.2.3.4")
      assert :ok = Sharing.verify_pincode(link, "아무거나", "1.2.3.4")
    end

    test "PIN 을 다시 켜면 값이 바뀌고 잠금이 풀린다", ctx do
      %{link: link} = issue(ctx, %{"with_pincode" => true})

      {:ok, link, first} = Sharing.set_pincode(link, :on)
      {:ok, link, second} = Sharing.set_pincode(link, :on)

      assert first != second
      assert link.failed_pin_attempts == 0
      assert is_nil(link.pin_locked_until)
    end

    test "PIN 을 끄면 해시가 사라진다", ctx do
      %{link: link} = issue(ctx, %{"with_pincode" => true})

      {:ok, updated, pin} = Sharing.set_pincode(link, :off)
      assert is_nil(pin)
      assert is_nil(updated.pin_hash)
    end
  end

  describe "폐기와 소진의 차이" do
    test "폐기하면 이미 들어온 게스트도 끊긴다", ctx do
      %{link: link, token: token} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})

      assert {:ok, _} = Sharing.fetch_live_guest(guest_token)

      {:ok, _} = Sharing.revoke_link(link)

      assert :error = Sharing.fetch_live_guest(guest_token)
    end

    test "소진돼도 이미 들어온 게스트는 남는다", ctx do
      # "더 못 들어온다"와 "들어온 사람을 내보낸다"는 다르다.
      # 1회성 링크로 회의록을 받은 사람이 두 번째 요청에서 쫓겨나면 링크가 쓸모없다.
      %{token: token} = issue(ctx, %{"max_uses" => 1, "require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})

      assert {:error, :gone} = Sharing.enter(token, %{})
      assert {:ok, _} = Sharing.fetch_live_guest(guest_token)
    end
  end

  describe "재발급" do
    test "옛 토큰은 죽고 게스트는 살아 있다", ctx do
      %{link: link, token: old} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(old, %{})

      {:ok, _updated, new} = Sharing.rotate_token(link)

      assert {:error, :not_found} = Sharing.fetch_by_token(old)
      assert {:ok, _} = Sharing.fetch_by_token(new)
      # 재발급은 "주소를 잃어버렸다"는 뜻이지 "쫓아낸다"가 아니다
      assert {:ok, _} = Sharing.fetch_live_guest(guest_token)
    end

    test "설정과 사용 횟수는 유지된다", ctx do
      %{link: link} = issue(ctx, %{"max_uses" => 5, "granted_role" => "contributor"})
      {:ok, link} = Sharing.consume_use(link)

      {:ok, updated, _} = Sharing.rotate_token(link)

      assert updated.use_count == 1
      assert updated.max_uses == 5
      assert updated.granted_role == "contributor"
    end
  end

  describe "게스트 권한 판정" do
    test "묶인 회의만 열린다", ctx do
      %{token: token} = issue(ctx, %{"granted_role" => "viewer", "require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})
      {:ok, session} = Sharing.fetch_live_guest(guest_token)

      assert {:ok, meeting, :lv2} = Sharing.guest_authorize(session, :lv2)
      assert meeting.id == ctx.meeting.id

      # Viewer 게스트가 Contributor 권한을 요구하면 404 (403 이 아니다)
      assert {:error, :not_found} = Sharing.guest_authorize(session, :lv1)
    end

    test "다른 회의 id 를 세션에 심어도 통하지 않는다", ctx do
      %{token: token} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})
      {:ok, session} = Sharing.fetch_live_guest(guest_token)

      other_owner = account_fixture()
      {:ok, other} = Meetings.create_meeting(other_owner, %{title: "남의 회의"})

      tampered = %{session | meeting_id: other.id}

      # 세션이 다른 회의를 가리켜도 그 회의의 게스트 스위치가 꺼져 있으면 못 연다
      assert {:error, :not_found} = Sharing.guest_authorize(tampered, :lv2)
    end

    test "회의 스위치를 끄면 이미 들어온 게스트도 막힌다", ctx do
      %{token: token} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})
      {:ok, session} = Sharing.fetch_live_guest(guest_token)

      assert {:ok, _, _} = Sharing.guest_authorize(session, :lv2)

      {:ok, _} = Meetings.update_permissions(ctx.meeting, %{guest_link_enabled: false})

      assert {:error, :not_found} = Sharing.guest_authorize(session, :lv2)
    end
  end

  describe "PIN 생성" do
    test "000000 도 나올 수 있고 늘 6자리다" do
      pins = for _ <- 1..300, do: SharedLink.generate_pincode()

      assert Enum.all?(pins, &String.match?(&1, ~r/^\d{6}$/))
      # sisyphus 는 100_001~999_999 라 앞자리 0 이 절대 안 나왔다
      assert Enum.uniq(pins) |> length() > 200
    end
  end

  describe "적대적 검증에서 나온 것들" do
    test "로그인만 하면 게스트 차단 스위치를 넘을 수 없다", ctx do
      # 스위치는 "이 회의는 게스트를 받지 않는다"는 뜻이다.
      # 로그인을 면제 조건으로 두면 아무나 가입해 우회하고, 1회성 링크를 대신 태워
      # 정당한 수신자가 못 들어오게 만들 수 있다.
      {:ok, _} = Meetings.update_permissions(ctx.meeting, %{guest_link_enabled: false})
      %{link: link, token: token} = issue(ctx, %{"max_uses" => 1, "require_name" => false})

      stranger = account_fixture()

      assert {:error, :not_found} = Sharing.enter(token, %{}, account: stranger)
      # 사용 횟수도 타지 않는다
      assert Sharing.get_link(link.id).use_count == 0
    end

    test "권한 없는 계정도 PIN 을 통과해야 한다", ctx do
      # 이전에는 계정 진입 경로가 요청 본문을 통째로 버려서
      # (a) 로그인한 사람은 PIN 링크에 영원히 못 들어가고
      # (b) 그 실패가 잠금 카운터를 태워 정당한 손님까지 막았다
      %{token: token, pin: pin} =
        issue(ctx, %{"with_pincode" => true, "require_name" => false})

      stranger = account_fixture()

      assert {:error, :invalid_pincode} =
               Sharing.enter(token, %{"pincode" => "000000"}, account: stranger)

      assert {:ok, %{mode: :guest}} =
               Sharing.enter(token, %{"pincode" => pin}, account: stranger)
    end

    test "권한 없는 계정도 이름을 낼 수 있다", ctx do
      %{token: token} = issue(ctx, %{"require_name" => true})
      stranger = account_fixture()

      assert {:ok, %{mode: :guest}} =
               Sharing.enter(token, %{"display_name" => "손님"}, account: stranger)
    end

    test "PIN 잠금이 동시 요청에 무너지지 않는다", ctx do
      # 읽어서 +1 하면 동시 요청들이 서로의 증가를 덮어써(lost update) 잠금이 안 걸린다.
      # 6자리 PIN 은 그 순간 대입 가능해진다.
      %{link: link, pin: pin} = issue(ctx, %{"with_pincode" => true})
      owner = self()

      1..10
      |> Task.async_stream(
        fn _ ->
          Ecto.Adapters.SQL.Sandbox.allow(VR.Repo, owner, self())
          Sharing.verify_pincode(Sharing.get_link(link.id), "000000", nil)
        end,
        max_concurrency: 10
      )
      |> Stream.run()

      locked = Sharing.get_link(link.id)
      assert locked.failed_pin_attempts >= SharedLink.pin_max_failures()
      assert SharedLink.pin_locked?(locked)
      # 잠긴 뒤에는 정답도 통하지 않는다
      assert {:error, :locked} = Sharing.verify_pincode(locked, pin, nil)
    end

    test "링크를 비활성화하면 이미 들어온 게스트도 끊긴다", ctx do
      # Reviewer 가 "껐다"고 믿는 조작이 아무 일도 안 하면 안 된다
      %{link: link, token: token} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})

      assert {:ok, _} = Sharing.fetch_live_guest(guest_token)

      {:ok, _} = Sharing.update_link(link, %{"is_active" => false})

      assert :error = Sharing.fetch_live_guest(guest_token)
    end

    test "링크 만료를 앞당기면 이미 들어온 게스트도 끊긴다", ctx do
      %{link: link, token: token} = issue(ctx, %{"require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})

      # 이미 지난 시각은 changeset 이 막으므로 DB 를 직접 바꾼다 (운영자가 짧게 잡은 뒤 시간이 지난 상황)
      past = DateTime.add(DateTime.utc_now(:second), -60, :second)
      link |> Ecto.Changeset.change(%{expires_at: past}) |> Repo.update!()

      assert :error = Sharing.fetch_live_guest(guest_token)
    end

    test "소진은 여전히 이미 들어온 게스트를 내보내지 않는다", ctx do
      # 위 두 개를 고치면서 이 구분이 무너지면 1회성 링크가 쓸모없어진다
      %{token: token} = issue(ctx, %{"max_uses" => 1, "require_name" => false})
      {:ok, %{guest_token: guest_token}} = Sharing.enter(token, %{})

      assert {:error, :gone} = Sharing.enter(token, %{})
      assert {:ok, _} = Sharing.fetch_live_guest(guest_token)
    end
  end
end
