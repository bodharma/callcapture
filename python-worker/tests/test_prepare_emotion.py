from app.analyze import emotion as emo


def test_prepare_idempotent_when_ready(tmp_path, monkeypatch):
    monkeypatch.setattr(emo, "emotion_model_dir", lambda: str(tmp_path))
    monkeypatch.setattr(emo, "is_emotion_model_ready", lambda: True)
    called = {"download": 0}
    monkeypatch.setattr(emo, "_download_and_extract", lambda d: called.__setitem__("download", called["download"] + 1))
    emo.prepare_emotion_model()
    assert called["download"] == 0  # already present -> no download


def test_prepare_downloads_when_absent(tmp_path, monkeypatch):
    monkeypatch.setattr(emo, "emotion_model_dir", lambda: str(tmp_path))
    monkeypatch.setattr(emo, "is_emotion_model_ready", lambda: False)
    called = {"download": 0}
    monkeypatch.setattr(emo, "_download_and_extract", lambda d: called.__setitem__("download", called["download"] + 1))
    emo.prepare_emotion_model()
    assert called["download"] == 1
