"""MCP server for nvim-code-assist.

Bridges the nvim plugin (over a unix socket) and a Claude/Gemini agent (over
stdio MCP). Two tools are exposed to the agent:

  - get_request(nonce)         -> {file, row, col, language}
  - deliver_completion(nonce, text) -> {ok}

The plugin connects to a unix socket and speaks newline-delimited JSON:

  plugin -> server: {"type":"submit", "nonce", "file", "row", "col", "language"}
  plugin -> server: {"type":"cancel", "nonce"}
  server -> plugin: {"type":"delivery", "nonce", "text"}
  server -> plugin: {"type":"error", "nonce", "message"}
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any

from mcp.server.lowlevel import NotificationOptions, Server
from mcp.server.models import InitializationOptions
import mcp.server.stdio
import mcp.types as types

log = logging.getLogger("code-assist-mcp")

# ---------------------------------------------------------------------------
# Shared state
# ---------------------------------------------------------------------------

STATE_LOCK = asyncio.Lock()
PENDING: dict[str, dict[str, Any]] = {}                 # nonce -> request payload
WRITERS: dict[str, asyncio.StreamWriter] = {}           # nonce -> plugin writer
CANCELLED: set[str] = set()                             # nonces cancelled by plugin


# ---------------------------------------------------------------------------
# MCP tools (exposed to the agent)
# ---------------------------------------------------------------------------

server = Server("code-assist")


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="get_request",
            description=(
                "Fetch the queued completion request matching `nonce`. Returns "
                "{ok, file, row (0-indexed), col (0-indexed), language}. Call this "
                "first when the code-complete skill activates."
            ),
            inputSchema={
                "type": "object",
                "properties": {"nonce": {"type": "string"}},
                "required": ["nonce"],
            },
        ),
        types.Tool(
            name="deliver_completion",
            description=(
                "Deliver the completion text for `nonce` back to the editor. "
                "`text` should be the new code only, with full leading whitespace "
                "as if written at column 0 (the editor handles cursor alignment). "
                "Empty `text` means no useful completion."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "nonce": {"type": "string"},
                    "text": {"type": "string"},
                },
                "required": ["nonce", "text"],
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any] | None) -> list[types.TextContent]:
    arguments = arguments or {}
    if name == "get_request":
        result = await tool_get_request(str(arguments.get("nonce", "")))
    elif name == "deliver_completion":
        result = await tool_deliver_completion(
            str(arguments.get("nonce", "")),
            str(arguments.get("text", "")),
        )
    else:
        result = {"ok": False, "error": f"unknown tool: {name}"}
    return [types.TextContent(type="text", text=json.dumps(result))]


async def tool_get_request(nonce: str) -> dict[str, Any]:
    if not nonce:
        return {"ok": False, "error": "missing nonce"}
    async with STATE_LOCK:
        req = PENDING.pop(nonce, None)
    if req is None:
        return {"ok": False, "error": "no pending request for nonce"}
    return {"ok": True, **req}


async def tool_deliver_completion(nonce: str, text: str) -> dict[str, Any]:
    if not nonce:
        return {"ok": False, "error": "missing nonce"}
    async with STATE_LOCK:
        if nonce in CANCELLED:
            CANCELLED.discard(nonce)
            WRITERS.pop(nonce, None)
            return {"ok": False, "reason": "cancelled"}
        writer = WRITERS.pop(nonce, None)
    if writer is None or writer.is_closing():
        return {"ok": False, "reason": "no client connected"}
    line = json.dumps({"type": "delivery", "nonce": nonce, "text": text}) + "\n"
    try:
        writer.write(line.encode())
        await writer.drain()
    except (ConnectionError, BrokenPipeError, OSError) as exc:
        return {"ok": False, "reason": f"client write failed: {exc}"}
    return {"ok": True}


# ---------------------------------------------------------------------------
# Unix socket server (talks to the nvim plugin)
# ---------------------------------------------------------------------------


async def handle_plugin_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    owned: set[str] = set()
    peer = writer.get_extra_info("peername")
    log.debug("plugin connected: %s", peer)
    try:
        while True:
            line = await reader.readline()
            if not line:
                break
            try:
                msg = json.loads(line.decode())
            except json.JSONDecodeError:
                log.warning("dropping malformed plugin line: %r", line)
                continue
            t = msg.get("type")
            if t == "submit":
                nonce = str(msg.get("nonce", ""))
                if not nonce:
                    continue
                payload = {
                    "file": str(msg.get("file", "")),
                    "row": int(msg.get("row", 0)),
                    "col": int(msg.get("col", 0)),
                    "language": str(msg.get("language", "text")),
                }
                async with STATE_LOCK:
                    PENDING[nonce] = payload
                    WRITERS[nonce] = writer
                    owned.add(nonce)
                log.debug("submit nonce=%s payload=%s", nonce, payload)
            elif t == "cancel":
                nonce = str(msg.get("nonce", ""))
                if not nonce:
                    continue
                async with STATE_LOCK:
                    PENDING.pop(nonce, None)
                    WRITERS.pop(nonce, None)
                    CANCELLED.add(nonce)
                    owned.discard(nonce)
                log.debug("cancel nonce=%s", nonce)
            else:
                log.warning("unknown plugin message type: %r", t)
    except (asyncio.CancelledError, ConnectionError):
        pass
    finally:
        async with STATE_LOCK:
            for nonce in owned:
                PENDING.pop(nonce, None)
                WRITERS.pop(nonce, None)
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass
        log.debug("plugin disconnected: %s", peer)


async def is_socket_alive(path: Path) -> bool:
    if not path.exists():
        return False
    try:
        _, writer = await asyncio.open_unix_connection(str(path))
    except (ConnectionRefusedError, FileNotFoundError, OSError):
        return False
    writer.close()
    try:
        await writer.wait_closed()
    except Exception:
        pass
    return True


async def run_socket_server(path: Path) -> None:
    if await is_socket_alive(path):
        log.warning(
            "socket %s is already in use by another code-assist server; "
            "this instance will not accept editor connections",
            path,
        )
        return
    if path.exists():
        try:
            path.unlink()
        except OSError as exc:
            log.error("could not remove stale socket %s: %s", path, exc)
            return
    path.parent.mkdir(parents=True, exist_ok=True)
    server_obj = await asyncio.start_unix_server(handle_plugin_client, path=str(path))
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    log.info("listening for editor on %s", path)
    try:
        async with server_obj:
            await server_obj.serve_forever()
    finally:
        try:
            path.unlink()
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------


async def run_stdio_mcp() -> None:
    async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="code-assist",
                server_version="0.1.0",
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={},
                ),
            ),
        )


async def amain(socket_path: Path) -> None:
    socket_task = asyncio.create_task(run_socket_server(socket_path), name="socket")
    try:
        await run_stdio_mcp()
    finally:
        socket_task.cancel()
        try:
            await socket_task
        except (asyncio.CancelledError, Exception):
            pass


def _socket_path_default() -> Path:
    base = os.environ.get("XDG_RUNTIME_DIR") or os.environ.get("TMPDIR") or "/tmp"
    return Path(base) / f"code-assist-{os.getuid()}.sock"


def main_cli() -> None:
    parser = argparse.ArgumentParser(description="code-assist MCP server")
    parser.add_argument(
        "--socket",
        default=os.environ.get("CODE_ASSIST_SOCKET") or str(_socket_path_default()),
        help="Path to the unix socket the nvim plugin connects to.",
    )
    parser.add_argument(
        "--log-level",
        default=os.environ.get("CODE_ASSIST_LOG", "WARNING"),
        help="Python logging level (default: WARNING). Logs go to stderr.",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.WARNING),
        stream=sys.stderr,
        format="%(asctime)s code-assist-mcp %(levelname)s %(message)s",
    )

    try:
        asyncio.run(amain(Path(args.socket)))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main_cli()
