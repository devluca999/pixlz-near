from pixl_memory.store import Store


def test_same_passage_twice_keeps_one(tmp_path):
    s = Store(tmp_path)
    a = s.add_highlight("The skin is clear.", url="https://x.test/frogs", title="Frogs")
    b = s.add_highlight("The skin is clear.", url="https://x.test/frogs", title="Frogs")
    assert a.id == b.id
    assert len(s.list_highlights()) == 1


def test_other_page_or_folder_saves_again(tmp_path):
    s = Store(tmp_path)
    s.add_highlight("The skin is clear.", url="https://x.test/frogs")
    s.add_highlight("The skin is clear.", url="https://x.test/other")
    s.add_highlight("The skin is clear.", url="https://x.test/frogs", folder="Research")
    assert len(s.list_highlights()) == 3
