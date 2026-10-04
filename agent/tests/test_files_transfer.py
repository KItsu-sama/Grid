import base64
import hashlib
import os
import threading
from pathlib import Path

import pytest

from grid_agent.client import RemoteError
from grid_agent.fs import GridRoots, LocalFS
from grid_agent.protocol import Role, ValidationError
from grid_agent.sync import Action, diff3, snapshot
from grid_agent.transfer.client import Cancelled, TransferControl, download, upload
from grid_agent.transfer.limiter import TokenBucket
from grid_agent.transfer.queue import CANCELLED, DONE, OFFLINE, Job, TransferQueue

CS = 64 * 1024


def blob(n, seed=1):
    return bytes((i * seed) % 251 for i in range(n))


@pytest.fixture
def main_phone(pc, phone):
    phone.approve(Role.MAIN)
    return phone.client()


def shared(pc):
    return pc.tmp / "grid" / "shared"


# ---------- Grid roots: no whole-filesystem exposure
@pytest.mark.parametrize("bad", ["../x", "shared/../../x", "/etc/passwd", "C:/Windows", "shared\\a", "shared/a:stream",
                                 "shared/CON", "shared/nul.txt", "shared/.grid/x", "shared/a.", "other/x", "",
                                 "shared/x.gridpart"])
def test_paths_outside_roots_rejected(tmp_path, bad):
    fs = LocalFS(GridRoots({"shared": tmp_path / "s"}))
    with pytest.raises(ValidationError):
        fs.stat(bad)


def test_symlink_escape_blocked(tmp_path):
    outside = tmp_path / "outside"; outside.mkdir(); (outside / "s.txt").write_text("x")
    root = tmp_path / "s"; root.mkdir()
    try:
        os.symlink(outside, root / "link")
    except (OSError, NotImplementedError):
        pytest.skip("symlinks unavailable")
    fs = LocalFS(GridRoots({"shared": root}))
    with pytest.raises(ValidationError):
        fs.read_range("shared/link/s.txt", 0, 10)


def test_cannot_delete_root_and_listing_hides_internal(pc, main_phone):
    with pytest.raises(RemoteError):
        main_phone.call("files.delete", path="shared")
    names = [e["name"] for e in main_phone.call("files.list", path="")]
    assert names == ["inbox", "shared"]                         # only configured roots are visible


def test_basic_file_operations(pc, main_phone):
    main_phone.call("files.mkdir", path="shared/docs")
    r = main_phone.call("files.write", path="shared/docs/a.txt", data=base64.b64encode(b"hello").decode())
    assert r["sha256"] == hashlib.sha256(b"hello").hexdigest()
    main_phone.call("files.copy", src="shared/docs/a.txt", dst="shared/docs/b.txt")
    main_phone.call("files.move", src="shared/docs/b.txt", dst="inbox/c.txt")
    assert (pc.tmp / "grid" / "inbox" / "c.txt").read_bytes() == b"hello"
    st = main_phone.call("files.stat", path="shared/docs/a.txt")
    assert st["size"] == 5 and st["sha256"] == r["sha256"]
    main_phone.call("files.delete", path="shared/docs/a.txt", base_sha256=r["sha256"])
    assert main_phone.call("files.stat", path="shared/docs/a.txt") is None


# ---------- conflicts: never silently overwrite
def test_write_conflict_returns_conflict_object_and_keeps_data(pc, main_phone):
    b64 = lambda b: base64.b64encode(b).decode()
    first = main_phone.call("files.write", path="shared/n.txt", data=b64(b"v1"))
    (shared(pc) / "n.txt").write_bytes(b"edited on the PC")                    # PC changes it locally
    with pytest.raises(RemoteError) as e:
        main_phone.call("files.write", path="shared/n.txt", data=b64(b"phone edit"), base_sha256=first["sha256"])
    c = e.value.conflict
    assert e.value.code == "conflict"
    assert c["path"] == "shared/n.txt" and c["target_device"] == pc.agent.device_id
    assert c["hashes"]["local"] == hashlib.sha256(b"phone edit").hexdigest()
    assert c["hashes"]["remote"] == hashlib.sha256(b"edited on the PC").hexdigest()
    assert c["sizes"] == {"local": 10, "remote": 16} and set(c["timestamps"]) == {"local", "remote"}
    assert len(c["available_versions"]) == 2
    assert {"keep_local", "keep_remote", "keep_both", "inspect", "manual"} <= set(c["options"])
    assert (shared(pc) / "n.txt").read_bytes() == b"edited on the PC"          # untouched
    # blind overwrite (no base) of an existing, different file is also a conflict
    with pytest.raises(RemoteError):
        main_phone.call("files.write", path="shared/n.txt", data=b64(b"blind"))
    # "keep local": re-send with the remote hash as base
    main_phone.call("files.write", path="shared/n.txt", data=b64(b"phone edit"), base_sha256=c["hashes"]["remote"])
    assert (shared(pc) / "n.txt").read_bytes() == b"phone edit"
    # delete with a stale base is a conflict too
    with pytest.raises(RemoteError) as e:
        main_phone.call("files.delete", path="shared/n.txt", base_sha256=first["sha256"])
    assert e.value.code == "conflict"


# ---------- chunked / resumable transfer
def test_upload_chunked_verified(pc, main_phone, tmp_path):
    src = tmp_path / "big.bin"; src.write_bytes(blob(CS * 3 + 123))
    seen = []
    r = upload(main_phone, src, "shared/big.bin", chunk_size=CS, progress=lambda d, t: seen.append((d, t)))
    assert (shared(pc) / "big.bin").read_bytes() == src.read_bytes()
    assert r["sha256"] == hashlib.sha256(src.read_bytes()).hexdigest()
    assert seen[-1] == (src.stat().st_size, src.stat().st_size) and len(seen) == 4
    assert not list(shared(pc).glob("*.gridpart")) and not list((pc.cfg.state_dir / "transfers").glob("*.json"))


def test_empty_file_upload(pc, main_phone, tmp_path):
    src = tmp_path / "e.bin"; src.write_bytes(b"")
    upload(main_phone, src, "shared/e.bin", chunk_size=CS)
    assert (shared(pc) / "e.bin").read_bytes() == b""


def test_upload_resumes_after_cancel_and_after_restart(pc, main_phone, tmp_path):
    src = tmp_path / "big.bin"; src.write_bytes(blob(CS * 5))
    ctl, count = TransferControl(), []
    def progress(d, t):
        count.append(d)
        if len(count) == 2:
            ctl.cancel()
    with pytest.raises(Cancelled):
        upload(main_phone, src, "shared/big.bin", chunk_size=CS, progress=progress, control=ctl)
    assert not (shared(pc) / "big.bin").exists()                               # nothing half-written is visible
    sent = []
    r = upload(main_phone, src, "shared/big.bin", chunk_size=CS, progress=lambda d, t: sent.append(d))
    assert len(sent) == 3                                                       # only the 3 missing chunks were sent
    assert (shared(pc) / "big.bin").read_bytes() == src.read_bytes()


def test_corrupt_chunk_and_wrong_final_hash_rejected(pc, main_phone, tmp_path):
    data = blob(CS * 2)
    sid = main_phone.call("transfer.begin", path="shared/x.bin", size=len(data), sha256=hashlib.sha256(data).hexdigest(),
                          chunk_size=CS)["session"]
    good = data[:CS]
    with pytest.raises(RemoteError):                                            # data does not match declared hash
        main_phone.call("transfer.put_chunk", session=sid, index=0, data=base64.b64encode(b"x" * CS).decode(),
                        sha256=hashlib.sha256(good).hexdigest())
    with pytest.raises(RemoteError):                                            # wrong length
        main_phone.call("transfer.put_chunk", session=sid, index=0, data=base64.b64encode(good[:-1]).decode(),
                        sha256=hashlib.sha256(good[:-1]).hexdigest())
    with pytest.raises(RemoteError) as e:                                       # commit with missing chunks
        main_phone.call("transfer.commit", session=sid)
    assert "missing" in str(e.value)
    # internally consistent chunks that don't add up to the declared whole-file hash
    bad = b"y" * CS
    for i, ch in enumerate([bad, bad]):
        main_phone.call("transfer.put_chunk", session=sid, index=i, data=base64.b64encode(ch).decode(),
                        sha256=hashlib.sha256(ch).hexdigest())
    with pytest.raises(RemoteError):
        main_phone.call("transfer.commit", session=sid)
    assert not (shared(pc) / "x.bin").exists()


def test_session_cannot_be_used_by_another_device(pc, phone, laptop, main_phone):
    laptop.approve(Role.MAIN)
    data = blob(CS)
    sid = main_phone.call("transfer.begin", path="shared/a.bin", size=CS, sha256=hashlib.sha256(data).hexdigest(),
                          chunk_size=CS)["session"]
    with pytest.raises(RemoteError):
        laptop.client().call("transfer.abort", session=sid)


def test_upload_conflict_detected_at_begin_and_commit(pc, main_phone, tmp_path):
    (shared(pc) / "doc.bin").write_bytes(b"pc version")
    src = tmp_path / "doc.bin"; src.write_bytes(blob(CS + 5))
    with pytest.raises(RemoteError) as e:
        upload(main_phone, src, "shared/doc.bin", chunk_size=CS)               # no base: would blindly overwrite
    assert e.value.conflict["remote"]["size"] == 10
    base = hashlib.sha256(b"pc version").hexdigest()
    ctl, n = TransferControl(), []
    def sneaky(d, t):                                                          # PC edits file mid-transfer
        if not n:
            (shared(pc) / "doc.bin").write_bytes(b"changed during transfer")
        n.append(d)
    with pytest.raises(RemoteError) as e:
        upload(main_phone, src, "shared/doc.bin", base_sha256=base, chunk_size=CS, progress=sneaky)
    assert e.value.code == "conflict"                                          # TOCTOU caught at commit
    assert (shared(pc) / "doc.bin").read_bytes() == b"changed during transfer"


def test_download_verified_resumable_and_conflict_aware(pc, main_phone, tmp_path):
    data = blob(CS * 3 + 7)
    (shared(pc) / "m.bin").write_bytes(data)
    dst = tmp_path / "dl" / "m.bin"
    ctl, n = TransferControl(), []
    def stop(d, t):
        n.append(d)
        if len(n) == 2:
            ctl.cancel()
    with pytest.raises(Cancelled):
        download(main_phone, "shared/m.bin", dst, chunk_size=CS, control=ctl, progress=stop)
    assert not dst.exists() and dst.with_name("m.bin.gridpart").exists()
    got = []
    download(main_phone, "shared/m.bin", dst, chunk_size=CS, progress=lambda d, t: got.append(d))
    assert dst.read_bytes() == data and got[0] == CS * 2 + CS                   # resumed from the partial file
    assert download(main_phone, "shared/m.bin", dst)["unchanged"] is True
    dst.write_bytes(b"local edits")
    from grid_agent.protocol import ConflictError
    with pytest.raises(ConflictError) as e:
        download(main_phone, "shared/m.bin", dst)
    assert e.value.conflict.local.size == 11 and e.value.conflict.remote.size == len(data)
    assert dst.read_bytes() == b"local edits"


def test_pause_resume_cancel_midflight(pc, main_phone, tmp_path):
    src = tmp_path / "p.bin"; src.write_bytes(blob(CS * 4))
    ctl = TransferControl(); ctl.pause()
    t = threading.Thread(target=lambda: upload(main_phone, src, "shared/p.bin", chunk_size=CS, control=ctl))
    t.start(); t.join(0.3)
    assert t.is_alive() and not (shared(pc) / "p.bin").exists()
    ctl.resume(); t.join(5)
    assert not t.is_alive() and (shared(pc) / "p.bin").read_bytes() == src.read_bytes()


# ---------- bandwidth limiter / queue
def test_token_bucket_throttles():
    now, slept = [0.0], []
    tb = TokenBucket(1000, clock=lambda: now[0], sleep=lambda s: (slept.append(s), now.__setitem__(0, now[0] + s)))
    tb.consume(1000); assert slept == []                                        # burst of one second is free
    tb.consume(500); assert slept == [pytest.approx(0.5)]
    TokenBucket(0).consume(10 ** 9)                                             # unlimited


def test_queue_priority_offline_hold_and_cancel(tmp_path):
    ran, online = [], {"phone": False, "laptop": True}
    def runner(job, ctl, progress):
        ran.append(job.id)
    q = TransferQueue(runner, lambda p: online[p], store=tmp_path / "q.json")
    lo = q.add(Job("upload", "laptop", "a", "r", priority=9, id="lo"))
    hi = q.add(Job("upload", "laptop", "b", "r", priority=1, id="hi"))
    off = q.add(Job("upload", "phone", "c", "r", priority=0, id="off"))
    gone = q.add(Job("upload", "laptop", "d", "r", priority=2, id="gone"))
    q.cancel(gone)
    q.run_until_idle()
    assert ran == ["hi", "lo"] and q.jobs["off"].state == OFFLINE and q.jobs["gone"].state == CANCELLED
    q2 = TransferQueue(runner, lambda p: True, store=tmp_path / "q.json")      # restart + reconnect
    q2.run_until_idle()
    assert ran[-1] == "off" and q2.jobs["off"].state == DONE


def test_queue_pause_resume_cancel_running_job(tmp_path):
    started, release = threading.Event(), threading.Event()
    def runner(job, ctl, progress):
        started.set(); ctl.checkpoint(); release.wait(2); ctl.checkpoint()
    q = TransferQueue(runner, lambda p: True)
    q.add(Job("upload", "x", "a", "b", id="j"))
    t = threading.Thread(target=q.run_once); t.start(); started.wait(2)
    q.pause("j"); assert q.jobs["j"].state == "paused"
    q.resume("j"); assert q.jobs["j"].state == "running"
    q.cancel("j"); release.set(); t.join(2)
    assert q.jobs["j"].state == CANCELLED


# ---------- sync: change detection / deletions / conflicts
def test_snapshot_and_diff3(tmp_path):
    fs = LocalFS(GridRoots({"shared": tmp_path / "s"}))
    fs.write_atomic("shared/a.txt", b"1"); fs.mkdir("shared/d"); fs.write_atomic("shared/d/b.txt", b"2")
    assert snapshot(fs, "shared") == {"a.txt": hashlib.sha256(b"1").hexdigest(), "d/b.txt": hashlib.sha256(b"2").hexdigest()}
    base = {"same": "1", "edit_l": "1", "edit_r": "1", "del_l": "1", "del_r": "1", "both": "1", "edit_vs_del": "1"}
    local = {"same": "1", "edit_l": "2", "edit_r": "1", "del_r": "1", "both": "2", "edit_vs_del": "2", "new_l": "9"}
    remote = {"same": "1", "edit_l": "1", "edit_r": "2", "del_l": "1", "both": "3", "new_r": "8"}
    got = {(a.kind, a.path) for a in diff3(base, local, remote)}
    assert got == {("upload", "edit_l"), ("download", "edit_r"), ("delete_remote", "del_l"),
                   ("delete_local", "del_r"), ("conflict", "both"), ("conflict", "edit_vs_del"),
                   ("upload", "new_l"), ("download", "new_r")}
    assert diff3({}, {"x": "1"}, {"x": "1"}) == []                              # converged independently
