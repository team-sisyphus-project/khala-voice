defmodule VR.TaxonomyTest do
  use VR.DataCase, async: true

  import VR.AccountsFixtures

  alias VR.{Meetings, Taxonomy}

  setup do
    %{account: account_fixture(), other: account_fixture()}
  end

  describe "topic creation" do
    test "sort order keeps appending", %{account: account} do
      {:ok, a} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      {:ok, b} = Taxonomy.create_topic(account, %{"name" => "Engineering"})
      {:ok, c} = Taxonomy.create_topic(account, %{"name" => "Operations"})

      assert [a.sort_order, b.sort_order, c.sort_order] == [0, 1, 2]
    end

    test "ids carry prefixes", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      {:ok, label} = Taxonomy.create_label(account, %{"name" => "Urgent"})

      assert String.starts_with?(topic.id, "topc_")
      assert String.starts_with?(label.id, "labl_")
    end

    test "trims surrounding whitespace from names", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "  Planning  "})
      assert topic.name == "Planning"
    end

    test "the same name cannot be created twice", %{account: account} do
      {:ok, _} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      assert {:error, changeset} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      refute changeset.valid?
    end

    test "someone else may use the same name", %{account: account, other: other} do
      {:ok, _} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      assert {:ok, _} = Taxonomy.create_topic(other, %{"name" => "Planning"})
    end

    test "a deleted name can be created again", %{account: account} do
      # Partial unique index regression. A full unique index would block here.
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      {:ok, _} = Taxonomy.delete_topic(topic)

      assert {:ok, _} = Taxonomy.create_topic(account, %{"name" => "Planning"})
    end

    test "rejects colors outside the palette", %{account: account} do
      assert {:error, changeset} =
               Taxonomy.create_topic(account, %{"name" => "x", "color" => "hotpink"})

      assert %{color: _} = errors_on(changeset)
    end

    test "defaults the color when none is picked", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      assert topic.color == VR.Taxonomy.Color.default()
    end

    test "rejects an empty name", %{account: account} do
      assert {:error, _} = Taxonomy.create_topic(account, %{"name" => "   "})
      assert {:error, _} = Taxonomy.create_topic(account, %{})
    end

    test "label names max out at 20 characters", %{account: account} do
      assert {:ok, _} = Taxonomy.create_label(account, %{"name" => String.duplicate("a", 20)})
      assert {:error, _} = Taxonomy.create_label(account, %{"name" => String.duplicate("a", 21)})
    end
  end

  describe "ownership" do
    test "someone else's topic comes back as nil", %{account: account, other: other} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "Planning"})

      assert Taxonomy.get_topic(account.id, topic.id)
      # Must be indistinguishable from nonexistent — the controller turns this into 404
      refute Taxonomy.get_topic(other.id, topic.id)
    end

    test "the list shows only mine", %{account: account, other: other} do
      {:ok, _} = Taxonomy.create_topic(account, %{"name" => "Mine"})
      {:ok, _} = Taxonomy.create_topic(other, %{"name" => "Theirs"})

      assert [%{name: "Mine"}] = Taxonomy.list_topics(account)
    end
  end

  describe "deletion detaches from meetings" do
    test "deleting a topic clears topic_id on meetings that used it", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      {:ok, m1} = Meetings.create_meeting(account, %{title: "a", topic_id: topic.id})
      {:ok, m2} = Meetings.create_meeting(account, %{title: "b", topic_id: topic.id})
      {:ok, m3} = Meetings.create_meeting(account, %{title: "c"})

      assert {:ok, %{detached_meetings: 2}} = Taxonomy.delete_topic(topic)

      assert is_nil(Meetings.get_meeting(m1.id).topic_id)
      assert is_nil(Meetings.get_meeting(m2.id).topic_id)
      assert is_nil(Meetings.get_meeting(m3.id).topic_id)
      assert Taxonomy.list_topics(account) == []
    end

    test "deleting a label removes only that id, keeping the rest", %{account: account} do
      {:ok, keep} = Taxonomy.create_label(account, %{"name" => "Keep"})
      {:ok, drop} = Taxonomy.create_label(account, %{"name" => "Drop"})

      {:ok, meeting} =
        Meetings.create_meeting(account, %{title: "a", label_ids: [keep.id, drop.id]})

      assert {:ok, %{detached_meetings: 1}} = Taxonomy.delete_label(drop)

      assert Meetings.get_meeting(meeting.id).label_ids == [keep.id]
    end

    test "deleted taxonomy entries still resolve their names", %{account: account} do
      # While meetings still reference it, the UI must not show a mystery chip
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "a", topic_id: topic.id})

      resolved = Taxonomy.resolve_for([meeting])
      assert resolved.topics[topic.id].name == "Planning"
    end
  end

  describe "sorting" do
    setup %{account: account} do
      {:ok, a} = Taxonomy.create_topic(account, %{"name" => "A"})
      {:ok, b} = Taxonomy.create_topic(account, %{"name" => "B"})
      {:ok, c} = Taxonomy.create_topic(account, %{"name" => "C"})
      %{ids: [a.id, b.id, c.id]}
    end

    test "reorders", %{account: account, ids: [a, b, c]} do
      assert {:ok, sorted} = Taxonomy.reorder_topics(account, [c, a, b])
      assert Enum.map(sorted, & &1.id) == [c, a, b]
    end

    test "sending a partial list changes nothing", %{account: account, ids: [a, b, _c]} do
      before = Taxonomy.list_topics(account)

      assert {:error, :unknown_topic} = Taxonomy.reorder_topics(account, [b, a])
      assert Taxonomy.list_topics(account) == before
    end

    test "mixing in someone else's id changes nothing", %{account: account, other: other, ids: [a, b, _c]} do
      {:ok, theirs} = Taxonomy.create_topic(other, %{"name" => "Theirs"})
      before = Taxonomy.list_topics(account)

      assert {:error, :unknown_topic} = Taxonomy.reorder_topics(account, [a, b, theirs.id])
      assert Taxonomy.list_topics(account) == before
    end
  end

  describe "attaching to meetings" do
    test "someone else's topic cannot be attached", %{account: account, other: other} do
      {:ok, theirs} = Taxonomy.create_topic(other, %{"name" => "Theirs"})

      assert {:error, :invalid_topic} =
               Meetings.create_meeting(account, %{title: "a", topic_id: theirs.id})
    end

    test "a nonexistent label cannot be attached", %{account: account} do
      assert {:error, :invalid_label} =
               Meetings.create_meeting(account, %{title: "a", label_ids: ["labl_missing"]})
    end

    test "a deleted label cannot be attached", %{account: account} do
      {:ok, label} = Taxonomy.create_label(account, %{"name" => "Urgent"})
      {:ok, _} = Taxonomy.delete_label(label)

      assert {:error, :invalid_label} =
               Meetings.create_meeting(account, %{title: "a", label_ids: [label.id]})
    end

    test "my own taxonomy attaches", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      {:ok, label} = Taxonomy.create_label(account, %{"name" => "Urgent"})

      assert {:ok, meeting} =
               Meetings.create_meeting(account, %{
                 title: "a",
                 topic_id: topic.id,
                 label_ids: [label.id]
               })

      assert meeting.topic_id == topic.id
      assert meeting.label_ids == [label.id]
    end

    test "no validation when no taxonomy is given", %{account: account} do
      assert {:ok, _} = Meetings.create_meeting(account, %{title: "a"})
    end
  end

  describe "meeting counts" do
    test "counts per topic and label", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      {:ok, label} = Taxonomy.create_label(account, %{"name" => "Urgent"})

      {:ok, _} =
        Meetings.create_meeting(account, %{title: "a", topic_id: topic.id, label_ids: [label.id]})

      {:ok, _} = Meetings.create_meeting(account, %{title: "b", topic_id: topic.id})

      assert [%{topic: %{id: id}, meeting_count: 2}] = Taxonomy.list_topics_with_counts(account)
      assert id == topic.id
      assert [%{label: _, meeting_count: 1}] = Taxonomy.list_labels_with_counts(account)
    end

    test "deleted meetings are not counted", %{account: account} do
      {:ok, topic} = Taxonomy.create_topic(account, %{"name" => "Planning"})
      {:ok, meeting} = Meetings.create_meeting(account, %{title: "a", topic_id: topic.id})
      {:ok, _} = Meetings.delete_meeting(meeting)

      assert [%{meeting_count: 0}] = Taxonomy.list_topics_with_counts(account)
    end
  end
end
