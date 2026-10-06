# tools/test/test-linux-updater-archive-snapshot.py
"""Genuine private Git snapshot witnesses; source-only until the existing phase owner runs it.

No second reaper, outer hard timeout, original repository changes, fixture pruning,
or runtime capability substitutions. Every namespace is retained on either verdict.
"""

from pathlib import Path
import hashlib
import json
import os
import stat
import subprocess
import sys
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean_environment():
    result = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    result["GIT_CONFIG_GLOBAL"] = "/dev/null"
    result["GIT_CONFIG_NOSYSTEM"] = "1"
    result["GIT_OPTIONAL_LOCKS"] = (
        "0"  # The independent receipt itself must not refresh its original index.
    )
    result["PYTHONDONTWRITEBYTECODE"] = "1"
    return result


def git(root, *arguments):
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        env=clean_environment(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError("Private actual Git fixture construction refused")
    return result.stdout


def fixture():
    work = Path(tempfile.mkdtemp(prefix="ergopti-archive-snapshot-controls-"))
    work.chmod(0o700)
    repository = work / "original"
    repository.mkdir(mode=0o700)
    git(repository, "init", "-q")
    (repository / "tracked.txt").write_bytes(b"original committed bytes\n")
    git(repository, "add", "--", "tracked.txt")
    git(
        repository,
        "-c",
        "user.name=Snapshot fixture",
        "-c",
        "user.email=snapshot@example.invalid",
        "commit",
        "-qm",
        "actual fixture baseline",
    )
    head = git(repository, "rev-parse", "HEAD").decode("ascii").strip()
    clone = work / "clone"
    git(work, "clone", "-q", "--no-local", "--no-hardlinks", str(repository), str(clone))
    return work, repository, clone, head


def original_receipt(repository):
    return (
        digest(repository / ".git/index"),
        git(repository, "status", "--porcelain=v1", "-z"),
        git(repository, "ls-files", "--stage", "-z"),
        git(repository, "rev-parse", "HEAD"),
    )


def invoke(helper, work, repository, clone, head, environment):
    return subprocess.run(
        [
            sys.executable,
            "-B",
            str(helper),
            "--repository",
            str(repository),
            "--clone",
            str(clone),
            "--output",
            str(work / "snapshot"),
            "--expected-head",
            head,
        ],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def require_original(before, repository):
    assert original_receipt(repository) == before, "original actual index/status/HEAD changed"


def main():
    helper = Path(sys.argv[1])
    assert helper.is_absolute() and stat.S_ISREG(helper.lstat().st_mode)
    assert digest(helper) == sys.argv[2], "actual helper source hash changed"
    count = 0
    for poisoned in (False, True):
        work, repository, clone, head = fixture()
        (repository / "tracked.txt").write_bytes(b"actual unstaged working bytes\n")
        (repository / "added.txt").write_bytes(b"actual staged new bytes\n")
        git(repository, "add", "--", "added.txt")
        before = original_receipt(repository)
        environment = clean_environment()
        if poisoned:
            # Each redirect points at the real old private original, not a dummy port.
            environment.update(
                {
                    "GIT_DIR": str(repository / ".git"),
                    "GIT_WORK_TREE": str(repository),
                    "GIT_INDEX_FILE": str(repository / ".git/index"),
                    "GIT_COMMON_DIR": str(repository / ".git"),
                    "GIT_CONFIG_COUNT": "1",
                    "GIT_CONFIG_KEY_0": "core.worktree",
                    "GIT_CONFIG_VALUE_0": str(repository),
                    "GIT_CONFIG_PARAMETERS": "'core.worktree=" + str(repository) + "'",
                }
            )
        result = invoke(helper, work, repository, clone, head, environment)
        require_original(before, repository)
        assert result.returncode == 0 and result.stdout == b"" and result.stderr == b"", (
            "snapshot admission refused"
        )
        assert (clone / "tracked.txt").read_bytes() == b"actual unstaged working bytes\n"
        assert (clone / "added.txt").read_bytes() == b"actual staged new bytes\n"
        assert git(clone, "rev-parse", "HEAD").decode("ascii").strip() == head
        assert set(git(clone, "ls-files", "-z").split(b"\0")) == {b"tracked.txt", b"added.txt", b""}
        receipt = json.loads((work / "snapshot/ADMISSION.json").read_bytes())
        assert receipt["phase"] == "working-tree-snapshot" and receipt["source_head"] == head
        assert receipt["files"] == 2 and receipt["original_mutated"] is False
        assert receipt["inventory_sha256"] == digest(work / "snapshot/SOURCE-FILES.json")
        count += 1
    for refusal in ("symlink", "staged-deletion"):
        work, repository, clone, head = fixture()
        if refusal == "symlink":
            (repository / "tracked.txt").unlink()
            (repository / "tracked.txt").symlink_to(".git/index")
        else:
            git(repository, "rm", "-q", "--", "tracked.txt")
        before = original_receipt(repository)
        result = invoke(helper, work, repository, clone, head, clean_environment())
        require_original(before, repository)
        assert result.returncode != 0, "unsupported source authority was admitted"
        assert git(clone, "rev-parse", "HEAD").decode("ascii").strip() == head
        count += 1
    # Actual stage-zero index membership is independent of ignored working neighbors.
    # Admit the .gitkeep before installing its ignored-parent rule; no broad add is used.
    work, repository, clone, head = fixture()
    ignored = repository / "ignored"
    ignored.mkdir(mode=0o700)
    (ignored / ".gitkeep").write_bytes(b"actual index-admitted ignored bytes\n")
    git(repository, "add", "--", "ignored/.gitkeep")
    (repository / ".gitignore").write_bytes(b"ignored/\n")
    git(repository, "add", "--", ".gitignore")
    (ignored / "neighbor.tmp").write_bytes(b"original ignored neighbor must remain private\n")
    # A real ignored neighbor also exists in the clone: --force must not widen the NUL list.
    clone_ignored = clone / "ignored"
    clone_ignored.mkdir(mode=0o700)
    (clone_ignored / "neighbor.tmp").write_bytes(b"clone ignored neighbor must remain untracked\n")
    before = original_receipt(repository)
    assert set(git(repository, "ls-files", "-z").split(b"\0")) == {
        b"tracked.txt",
        b".gitignore",
        b"ignored/.gitkeep",
        b"",
    }
    result = invoke(helper, work, repository, clone, head, clean_environment())
    require_original(before, repository)
    assert result.returncode == 0 and result.stdout == b"" and result.stderr == b"", (
        "tracked ignored-parent snapshot refused"
    )
    assert (clone_ignored / ".gitkeep").read_bytes() == b"actual index-admitted ignored bytes\n"
    assert (clone / ".gitignore").read_bytes() == b"ignored/\n"
    assert (clone / "tracked.txt").read_bytes() == b"original committed bytes\n"
    assert (
        ignored / "neighbor.tmp"
    ).read_bytes() == b"original ignored neighbor must remain private\n"
    assert (
        clone_ignored / "neighbor.tmp"
    ).read_bytes() == b"clone ignored neighbor must remain untracked\n"
    assert git(clone, "rev-parse", "HEAD").decode("ascii").strip() == head
    assert set(git(clone, "ls-files", "-z").split(b"\0")) == {
        b"tracked.txt",
        b".gitignore",
        b"ignored/.gitkeep",
        b"",
    }
    inventory = json.loads((work / "snapshot/SOURCE-FILES.json").read_bytes())
    assert {row["path"] for row in inventory} == {"tracked.txt", ".gitignore", "ignored/.gitkeep"}
    assert not (work / "snapshot/files/ignored/neighbor.tmp").exists()
    receipt = json.loads((work / "snapshot/ADMISSION.json").read_bytes())
    assert receipt["phase"] == "working-tree-snapshot" and receipt["source_head"] == head
    assert receipt["files"] == 3 and receipt["original_mutated"] is False
    assert receipt["inventory_sha256"] == digest(work / "snapshot/SOURCE-FILES.json")
    count += 1
    assert count == 5
    print("Archive snapshot controls: 5 passed; 0 skipped.")


if __name__ == "__main__":
    main()
