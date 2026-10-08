#!/usr/bin/env python3
import fcntl
import json
import os
from pathlib import Path
import sys
import time


root = Path(os.environ["FAKE_HERDR_DIR"])
kind, operation, *args = sys.argv[1:]
collection = kind + "s"
field = kind + "_id"
status = 0
output = None

if os.environ.get("FAKE_HERDR_READ_STDIN"):
    sys.stdin.read()

with (root / "state.json").open("r+") as state_file:
    fcntl.flock(state_file, fcntl.LOCK_EX)
    state = json.load(state_file)
    with (root / "calls.jsonl").open("a") as log:
        log.write(json.dumps(sys.argv[1:]) + "\n")
    if operation == "list":
        error = state.get("list_errors", {}).get(kind)
        if error == "malformed":
            output = "not json"
        elif error:
            status = 7
        else:
            output = json.dumps({"result": {collection: state[collection]}})
    else:
        target_id = args[0]
        failure = state.get("failures", {}).get(kind, {}).get(target_id)
        if failure:
            if failure == "gone":
                state[collection] = [row for row in state[collection] if row[field] != target_id]
            if state.get("verification_error"):
                state.setdefault("list_errors", {})[kind] = state["verification_error"]
            status = 7
        else:
            target = next((row for row in state[collection] if row[field] == target_id), None)
            if target is None:
                status = 7
            elif operation == "rename":
                target["label"] = args[1]
            elif operation == "report-metadata":
                token = args[args.index("--token") + 1]
                key, value = token.split("=", 1)
                target.setdefault("tokens", {})[key] = value
            else:
                status = 8
        state_file.seek(0)
        json.dump(state, state_file)
        state_file.truncate()

gate = os.environ.get("FAKE_HERDR_GATE")
if gate and kind == "tab" and operation == "list":
    entered = Path(gate) / "entered"
    try:
        entered.touch(exist_ok=False)
    except FileExistsError:
        pass
    else:
        deadline = time.monotonic() + 10
        while not (Path(gate) / "release").exists():
            if time.monotonic() >= deadline:
                sys.exit(9)
            time.sleep(0.01)

if output is not None:
    print(output)
if status:
    print("fake herdr: request failed", file=sys.stderr)
sys.exit(status)
