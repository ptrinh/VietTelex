#!/usr/bin/env python3
"""Generate pronunciation audio for the /learn/lessons typing course.

Reads docs/learn/lessons/lessons.json, collects every speakable word and
sentence, and renders MP3s — far more accurate and consistent than device
speechSynthesis voices. learn.js plays these files first, TTS is fallback.

Engines:
  gtts (default) — Google Translate voice: NỮ, giọng Hà Nội chuẩn
  edge           — Microsoft vi-VN-HoaiMyNeural (nữ, neural)

Usage:
  python3 -m venv .tts-venv && .tts-venv/bin/pip install gTTS edge-tts
  .tts-venv/bin/python Scripts/gen-lesson-audio.py [gtts|edge]

Re-run after changing the curriculum; existing files are skipped, the
manifest is rewritten. Slug logic MUST stay in sync with slug() in learn.js.
"""
import asyncio, json, pathlib, re, sys, time

ROOT = pathlib.Path(__file__).resolve().parent.parent
LESSONS = ROOT / "docs/learn/lessons/lessons.json"
OUTDIR = ROOT / "docs/learn/lessons/audio"
VOICE = "vi-VN-HoaiMyNeural"
RATE = "-15%"   # slightly slow, for learners


def slug(text: str) -> str:
    t = re.sub(r"[^\w\s]", "", text.lower(), flags=re.UNICODE)
    return re.sub(r"\s+", "-", t.strip())


def collect() -> dict:
    data = json.loads(LESSONS.read_text())
    texts = {}
    for ch in data["chapters"]:
        for lesson in ch["lessons"]:
            if lesson["type"] in ("info", "drill"):
                continue   # drills are not Vietnamese sounds
            for item in lesson["items"]:
                texts[slug(item["d"])] = item["d"]
            if lesson.get("speak"):
                texts[slug(lesson["speak"])] = lesson["speak"]
    return texts


def render(texts: dict, engine: str) -> None:
    OUTDIR.mkdir(parents=True, exist_ok=True)
    todo = {s: t for s, t in texts.items() if not (OUTDIR / f"{s}.mp3").exists()}
    print(f"{len(texts)} texts, {len(todo)} to render ({engine})")
    if engine == "edge":
        import edge_tts
        async def go():
            for i, (s, t) in enumerate(sorted(todo.items()), 1):
                await edge_tts.Communicate(t, VOICE, rate=RATE).save(str(OUTDIR / f"{s}.mp3"))
                print(f"  [{i}/{len(todo)}] {t}")
        asyncio.run(go())
    else:
        from gtts import gTTS
        for i, (s, t) in enumerate(sorted(todo.items()), 1):
            gTTS(t, lang="vi", slow=False).save(str(OUTDIR / f"{s}.mp3"))
            print(f"  [{i}/{len(todo)}] {t}")
            time.sleep(0.4)   # be polite to the endpoint
    (OUTDIR / "manifest.json").write_text(
        json.dumps(sorted(texts.keys()), ensure_ascii=False, indent=0))


if __name__ == "__main__":
    render(collect(), sys.argv[1] if len(sys.argv) > 1 else "gtts")
    print("done →", OUTDIR)
