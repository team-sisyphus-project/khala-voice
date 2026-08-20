defmodule VR.TaxonomyTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.{Meetings, Taxonomy}

  setup do
    %{account: account_fixture(), other: account_fixture()}
  end

  describe "토픽 생성" do
    test "정렬 순서가 뒤로 이어진다", %{account: account} do
      {:ok, a} = Taxonomy.create_topic(account, %{"name" => "기획"})
      {:ok, b} = Taxonomy.create_topic(account, %{"name" => "개발"})
      {:ok, c} = Taxonomy.create_topic(account, %{"name" => "운영"})

      assert [a.sort_order, b.sort_order, c.sort_order] == [0, 1, 2]
    end

    test "id 에 접두사가 붙는다", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "기획"})
      {:ok, label} = Taxonomy.create_label(account, %{"name" => "긴급"})

      assert String.starts_with?(topic.id, "topc_")
      assert String.starts_with?(label.id, "labl_")
    end

    test "이름 앞뒤 공백을 지운다", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "  기획  "})
      assert topic.name == "기획"
    end

    test "같은 이름은 두 번 만들 수 없다", %{account: account} do
      {:ok, _} = Taxonomy.create_topic(account, %{"name" => "기획"})
      assert {:error, changeset} = Taxonomy.create_topic(account, %{"name" => "기획"})
      refute changeset.valid?
    end

    test "다른 사람은 같은 이름을 쓸 수 있다", %{account: account, other: other} do
      {:ok, _} = Taxonomy.create_topic(account, %{"name" => "기획"})
      assert {:ok, _} = Taxonomy.create_topic(other, %{"name" => "기획"})
    end

    test "지운 이름은 다시 만들 수 있다", %{account: account} do
      # 부분 유니크 인덱스 회귀. 전체 유니크였으면 여기서 막힌다.
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "기획"})
      {:ok, _} = Taxonomy.delete_topic(topic)

      assert {:ok, _} = Taxonomy.create_topic(account, %{"name" => "기획"})
    end

    test "팔레트에 없는 색은 거부한다", %{account: account} do
      assert {:error, changeset} =
               Taxonomy.create_topic(account, %{"name" => "x", "color" => "hotpink"})

      assert %{color: _} = errors_on(changeset)
    end

    test "색을 안 고르면 기본색", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "기획"})
      assert topic.color == VR.Taxonomy.Color.default()
    end

    test "이름이 비면 거부한다", %{account: account} do
      assert {:error, _} = Taxonomy.create_topic(account, %{"name" => "   "})
      assert {:error, _} = Taxonomy.create_topic(account, %{})
    end

    test "라벨 이름은 20자까지", %{account: account} do
      assert {:ok, _} = Taxonomy.create_label(account, %{"name" => String.duplicate("가", 20)})
      assert {:error, _} = Taxonomy.create_label(account, %{"name" => String.duplicate("가", 21)})
    end
  end

  describe "소유권" do
    test "남의 토픽은 nil 로 온다", %{account: account, other: other} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "기획"})

      assert Taxonomy.get_topic(account.id, topic.id)
      # 없는 것과 구별되지 않아야 한다 — 컨트롤러가 이걸 404 로 바꾼다
      refute Taxonomy.get_topic(other.id, topic.id)
    end

    test "목록에는 내 것만 나온다", %{account: account, other: other} do
      {:ok, _} = Taxonomy.create_topic(account, %{"name" => "내것"})
      {:ok, _} = Taxonomy.create_topic(other, %{"name" => "남의것"})

      assert [%{name: "내것"}] = Taxonomy.list_topics(account)
    end
  end

  describe "삭제하면 회의에서 떼어낸다" do
    test "토픽을 지우면 쓰던 회의의 topic_id 가 비워진다", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "기획"})
      {:ok, m1} = Meetings.create_meeting(account, %{title: "a", topic_id: topic.id})
      {:ok, m2} = Meetings.create_meeting(account, %{title: "b", topic_id: topic.id})
      {:ok, m3} = Meetings.create_meeting(account, %{title: "c"})

      assert {:ok, %{detached_meetings: 2}} = Taxonomy.delete_topic(topic)

      assert is_nil(Meetings.get_meeting(m1.id).topic_id)
      assert is_nil(Meetings.get_meeting(m2.id).topic_id)
      assert is_nil(Meetings.get_meeting(m3.id).topic_id)
      assert Taxonomy.list_topics(account) == []
    end

    test "라벨을 지우면 그 id 만 빠지고 나머지는 남는다", %{account: account} do
      {:ok, keep} = Taxonomy.create_label(account, %{"name" => "유지"})
      {:ok, drop} = Taxonomy.create_label(account, %{"name" => "삭제"})

      {:ok, meeting} =
        Meetings.create_meeting(account, %{title: "a", label_ids: [keep.id, drop.id]})

      assert {:ok, %{detached_meetings: 1}} = Taxonomy.delete_label(drop)

      assert Meetings.get_meeting(meeting.id).label_ids == [keep.id]
    end

    test "삭제된 분류도 이름은 해석된다", %{account: account} do
      # 아직 회의에 참조가 남아 있는 동안 화면에 정체불명 칩이 뜨면 안 된다
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "기획"})
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "a", topic_id: topic.id})

      resolved = Taxonomy.resolve_for([meeting])
      assert resolved.topics[topic.id].name == "기획"
    end
  end

  describe "정렬" do
    setup %{account: account} do
      {:ok, a} = Taxonomy.create_topic(account, %{"name" => "A"})
      {:ok, b} = Taxonomy.create_topic(account, %{"name" => "B"})
      {:ok, c} = Taxonomy.create_topic(account, %{"name" => "C"})
      %{ids: [a.id, b.id, c.id]}
    end

    test "순서를 바꾼다", %{account: account, ids: [a, b, c]} do
      assert {:ok, sorted} = Taxonomy.reorder_topics(account, [c, a, b])
      assert Enum.map(sorted, & &1.id) == [c, a, b]
    end

    test "일부만 보내면 아무것도 안 바뀐다", %{account: account, ids: [a, b, _c]} do
      before = Taxonomy.list_topics(account)

      assert {:error, :unknown_topic} = Taxonomy.reorder_topics(account, [b, a])
      assert Taxonomy.list_topics(account) == before
    end

    test "남의 id 가 섞이면 아무것도 안 바뀐다", %{account: account, other: other, ids: [a, b, _c]} do
      {:ok, theirs} = Taxonomy.create_topic(other, %{"name" => "남의것"})
      before = Taxonomy.list_topics(account)

      assert {:error, :unknown_topic} = Taxonomy.reorder_topics(account, [a, b, theirs.id])
      assert Taxonomy.list_topics(account) == before
    end
  end

  describe "회의에 붙일 때" do
    test "남의 토픽은 붙일 수 없다", %{account: account, other: other} do
      {:ok, theirs} = Taxonomy.create_topic(other, %{"name" => "남의것"})

      assert {:error, :invalid_topic} =
               Meetings.create_meeting(account, %{title: "a", topic_id: theirs.id})
    end

    test "없는 라벨은 붙일 수 없다", %{account: account} do
      assert {:error, :invalid_label} =
               Meetings.create_meeting(account, %{title: "a", label_ids: ["labl_없음"]})
    end

    test "삭제된 라벨은 붙일 수 없다", %{account: account} do
      {:ok, label} = Taxonomy.create_label(account, %{"name" => "긴급"})
      {:ok, _} = Taxonomy.delete_label(label)

      assert {:error, :invalid_label} =
               Meetings.create_meeting(account, %{title: "a", label_ids: [label.id]})
    end

    test "내 분류는 붙는다", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "기획"})
      {:ok, label} = Taxonomy.create_label(account, %{"name" => "긴급"})

      assert {:ok, meeting} =
               Meetings.create_meeting(account, %{
                 title: "a",
                 topic_id: topic.id,
                 label_ids: [label.id]
               })

      assert meeting.topic_id == topic.id
      assert meeting.label_ids == [label.id]
    end

    test "분류를 안 주면 검증하지 않는다", %{account: account} do
      assert {:ok, _} = Meetings.create_meeting(account, %{title: "a"})
    end
  end

  describe "회의 수" do
    test "토픽·라벨별로 센다", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "기획"})
      {:ok, label} = Taxonomy.create_label(account, %{"name" => "긴급"})

      {:ok, _} =
        Meetings.create_meeting(account, %{title: "a", topic_id: topic.id, label_ids: [label.id]})

      {:ok, _} = Meetings.create_meeting(account, %{title: "b", topic_id: topic.id})

      assert [%{topic: %{id: id}, meeting_count: 2}] = Taxonomy.list_topics_with_counts(account)
      assert id == topic.id
      assert [%{label: _, meeting_count: 1}] = Taxonomy.list_labels_with_counts(account)
    end

    test "삭제된 회의는 세지 않는다", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "기획"})
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "a", topic_id: topic.id})
      {:ok, _} = Meetings.delete_meeting(meeting)

      assert [%{meeting_count: 0}] = Taxonomy.list_topics_with_counts(account)
    end
  end
end
