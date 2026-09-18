#!/usr/bin/env python3
"""Read-only, bounded summaries for the host CLI; never execute receipt contents."""
import json
import os
import re
import stat
import subprocess
import sys
from contextlib import ExitStack


class InspectionError(Exception):
    pass


def read_file(directory, name, limit=8192):
    """Open relative to an already opened directory, refusing links and FIFOs."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise InspectionError("invalid_receipt")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise InspectionError("invalid_receipt")
    return data.decode("utf-8")


def run_result(inbox, run_id, profile, login, container, workspace):
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9]{1,20}", run_id):
        raise InspectionError("invalid_run_id")
    with ExitStack() as stack:
        def directory(path, parent=None):
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                         dir_fd=parent)
            stack.callback(os.close, fd)
            return fd

        try:
            root = directory(os.path.join(inbox, "headless-runs"))
            run = directory(run_id, root)
        except FileNotFoundError:
            raise InspectionError("run_not_found") from None
        meta = {}
        for line in read_file(run, "meta.env").splitlines():
            key, separator, value = line.partition("=")
            if not separator or key in meta:
                raise InspectionError("invalid_receipt")
            meta[key] = value
        expected = dict(run_id=run_id, profile=profile, login=login,
                        container=container, workspace=workspace)
        if any(meta.get(key) != value for key, value in expected.items()):
            raise InspectionError("receipt_scope_mismatch")
        timestamp = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"
        if not re.fullmatch(timestamp, meta.get("start", "")):
            raise InspectionError("invalid_receipt")
        result = dict(run_id=run_id, state="incomplete", exit_code=None,
                      started_at=meta["start"], ended_at=None)
        try:
            code = read_file(run, "exit_code", 16).strip()
        except FileNotFoundError:
            return result
        if not re.fullmatch(r"[0-9]{1,3}", code) or int(code) > 255:
            raise InspectionError("invalid_receipt")
        # The writer creates exit_code before appending end/exit_code to meta.
        # Interrupted or partially written receipts must not imply completion.
        if "end" not in meta or "exit_code" not in meta:
            return result
        if meta["exit_code"] != code or not re.fullmatch(timestamp, meta["end"]):
            raise InspectionError("invalid_receipt")
        result.update(state="succeeded" if int(code) == 0 else "failed",
                      exit_code=int(code), ended_at=meta["end"])
        return result


def container_status(container):
    try:
        probe = subprocess.run(
            ["docker", "container", "ls", "--all", "--filter",
             "name=^/" + re.escape(container) + "$", "--format", "{{.State}}"],
            capture_output=True, text=True, timeout=10, check=True)
    except (OSError, subprocess.SubprocessError):
        raise InspectionError("docker_unavailable") from None
    state = probe.stdout.strip() or "absent"
    if state not in {"absent", "created", "running", "paused", "restarting",
                     "removing", "exited", "dead"}:
        raise InspectionError("invalid_docker_response")
    return dict(container=container, state=state)


def main():
    operation, profile, login, container, workspace, inbox, *args = sys.argv[1:]
    response = dict(schema_version=1, profile=profile or None)
    try:
        if operation == "status" and not args:
            response.update(container_status(container))
        elif operation == "run-result" and len(args) == 1:
            response.update(run_result(inbox, args[0], profile, login, container, workspace))
        else:
            raise InspectionError("invalid_arguments")
    except (InspectionError, OSError, UnicodeError) as error:
        # Filesystem and Docker diagnostics can contain paths or credentials.
        response.update(error=str(error) if isinstance(error, InspectionError)
                        else "invalid_receipt")
        print(json.dumps(response, sort_keys=True))
        return 2
    print(json.dumps(response, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
