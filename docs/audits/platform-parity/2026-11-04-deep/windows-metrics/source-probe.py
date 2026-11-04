"""Bounded source-evidence probe, not native/runtime or regression validation."""

from pathlib import Path
import re
import subprocess

root = Path("/workspace/ergopti")
base = root / "static/ergopti_plus/windows/modules/keystats"
sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
assert sha == "89b0b774c8c960c7ad458ac3cb98d5c97598e518", sha
source = (base / "keystats.ahk").read_text(encoding="utf-8-sig")
empty = re.search(r"if \(Keystats\.buffer_events\.Length = 0.*?return true", source, re.S).group()
assert "session_clicks" in empty and "session_scrolls" in empty
assert "mouse_distance" not in empty
snapshot = source.split(
    "_KL_PublishBufferSnapshot(Snapshot, AttemptFlushTick, PublishGuard := unset) {", 1
)[1]
snapshot_empty = snapshot.split("return true", 1)[0]
assert "Snapshot.Distance" not in snapshot_empty
print("WM-001: both actual empty predicates omit distance; no native execution claimed")

ingest = (base / "keystats_ingest.ahk").read_text(encoding="utf-8-sig")
assert "line := KL_JsonEncode(e)" in ingest
assert "_KL_JournalAppendDefault(fh, line)" in ingest
journal = (base / "keystats_journal.ahk").read_text(encoding="utf-8-sig")
assert 'EncodeFn := _KL_JournalPortFn(Port, "encode", _KL_JournalEncodeDefault)' in journal
assert "KL_Enc_Encrypt" not in ingest and "KL_Enc_Encrypt" not in journal
codec = (base / "keystats_json.ahk").read_text(encoding="utf-8-sig")
assert "return KL_JsonEncodeMap(v)" in codec and "KL_Enc_Encrypt" not in codec
sql = (base / "keystats_sql.ahk").read_text(encoding="utf-8-sig")
assert "encText := KL_Enc_Encrypt" in sql and "encJson := KL_Enc_Encrypt" in sql
print("WM-002: raw JSON journal publication precedes SQL-only typed-text encryption")

web = (base / "keystats_webview.ahk").read_text(encoding="utf-8-sig")
purge = web.split('case "clear_cache":', 1)[1].split("; COM getters", 1)[0]
assert "KLR_ResetCache()" in purge and "try FileDelete(path)" in purge
assert "KLR_CacheDiscard" not in purge and "KLR_CachePath" not in purge
reader = (base / "keystats_reader_db.ahk").read_text(encoding="utf-8-sig")
assert "KLR_CacheAttach(md, logPath)" in reader
assert 'if (update["tails"].Count = 0)' in reader
print("WM-003: Reset leaves durable reader image and successor build can attach it")
print("SHA=" + sha)
