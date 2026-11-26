from app.analyze.attribution import attribute_segments
from app.schemas.models import DiarizationTurn, TranscriptSegment


def seg(start, end, text="x"):
    return TranscriptSegment(start=start, end=end, text=text)


def test_mic_segments_are_self():
    mic = [seg(0, 2), seg(3, 4)]
    out = attribute_segments(mic_segments=mic, system_segments=[], turns=None, self_label="You")
    assert all(s.speaker == "You" for s in out)
    assert [s.start for s in out] == [0, 3]


def test_system_without_turns_is_single_speaker():
    syss = [seg(0, 2), seg(2, 4)]
    out = attribute_segments(mic_segments=[], system_segments=syss, turns=None, self_label="You")
    assert all(s.speaker == "Speaker 1" for s in out)


def test_system_attributed_by_max_overlap():
    syss = [seg(0.0, 1.0), seg(1.5, 3.0)]
    turns = [
        DiarizationTurn(speaker="Speaker 1", start=0.0, end=1.2),
        DiarizationTurn(speaker="Speaker 2", start=1.2, end=3.5),
    ]
    out = attribute_segments(mic_segments=[], system_segments=syss, turns=turns, self_label="You")
    assert out[0].speaker == "Speaker 1"
    assert out[1].speaker == "Speaker 2"


def test_merged_output_sorted_by_start():
    mic = [seg(0.0, 1.0, "me")]
    syss = [seg(0.5, 2.0, "them")]
    out = attribute_segments(mic_segments=mic, system_segments=syss, turns=None, self_label="You")
    assert [s.start for s in out] == [0.0, 0.5]
    assert out[0].speaker == "You" and out[1].speaker == "Speaker 1"


def test_native_provider_speakers_survive_absent_or_empty_sidecar():
    remote = [TranscriptSegment(start=0, end=1, text="one", speaker="Speaker A"),
              TranscriptSegment(start=1, end=2, text="two", speaker="Speaker B")]
    for turns in (None, []):
        result = attribute_segments([], remote, turns)
        assert [s.speaker for s in result] == ["Speaker A", "Speaker B"]


def test_local_sidecar_overrides_native_speaker_when_present():
    remote = [TranscriptSegment(start=0, end=1, text="one", speaker="Provider A")]
    turns = [DiarizationTurn(start=0, end=1, speaker="Named remote")]
    assert attribute_segments([], remote, turns)[0].speaker == "Named remote"
