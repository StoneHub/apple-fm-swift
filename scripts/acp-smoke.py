#!/usr/bin/env python3
"""Drive an ACP agent over stdio the way Xcode does: initialize, open a session, send one prompt, print the reply.

Usage: scripts/acp-smoke.py [AGENT] [PROMPT]
AGENT defaults to .build/release/apple-fm-acp. The session's folder is this repository, and the client offers
fs/read_text_file, answering from disk. Exits non-zero if the agent breaks the protocol or the turn doesn't end.
"""
import json
import os
import subprocess
import sys
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
agent = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(ROOT, ".build/release/apple-fm-acp")
question = sys.argv[2] if len(sys.argv) > 2 else "In one sentence, what does Package.swift in this project build? Read it first."

proc = subprocess.Popen([agent], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, cwd="/")
timer = threading.Timer(120, proc.kill)
timer.start()


def send(message):
    proc.stdin.write((json.dumps(message) + "\n").encode())
    proc.stdin.flush()


def receive():
    line = proc.stdout.readline()
    if not line:
        sys.exit("FAIL: agent closed stdout")
    try:
        return json.loads(line)
    except ValueError:
        sys.exit(f"FAIL: stdout line is not JSON: {line[:200]!r}")


def wait_for(request_id):
    while True:
        message = receive()
        if message.get("id") == request_id and "method" not in message:
            if "error" in message:
                sys.exit(f"FAIL: {message['error']}")
            return message["result"]
        handle(message)


def handle(message):
    method = message.get("method")
    if method == "session/update":
        update = message["params"]["update"]
        kind = update["sessionUpdate"]
        if kind == "agent_message_chunk":
            print(update["content"].get("text", ""), end="", flush=True)
        elif kind in ("tool_call", "tool_call_update"):
            print(f"\n[{kind}: {update.get('title', '')} {update.get('status', '')}]", flush=True)
    elif method == "fs/read_text_file":
        params = message["params"]
        try:
            with open(params["path"], encoding="utf-8") as handle_:
                lines = handle_.read().splitlines(keepends=True)
            content = "".join(lines[: params.get("limit") or len(lines)])
            send({"jsonrpc": "2.0", "id": message["id"], "result": {"content": content}})
        except OSError as error:
            send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32002, "message": str(error)}})
    elif "id" in message and method:
        send({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "not supported"}})


send({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
    "protocolVersion": 1,
    "clientCapabilities": {"fs": {"readTextFile": True, "writeTextFile": False}, "terminal": False},
    "clientInfo": {"name": "acp-smoke", "version": "1"}}})
info = wait_for(0)
assert info["protocolVersion"] == 1, info
print(f"agent: {info['agentInfo']['title']} {info['agentInfo']['version']}")

send({"jsonrpc": "2.0", "id": 1, "method": "session/new", "params": {"cwd": ROOT, "mcpServers": []}})
session = wait_for(1)["sessionId"]

send({"jsonrpc": "2.0", "id": 2, "method": "session/prompt", "params": {
    "sessionId": session, "prompt": [{"type": "text", "text": question}]}})
stop = wait_for(2)["stopReason"]
print(f"\nstopReason: {stop}")

proc.stdin.close()
proc.wait(timeout=10)
timer.cancel()
sys.exit(0 if stop in ("end_turn", "max_tokens", "refusal") else 1)
