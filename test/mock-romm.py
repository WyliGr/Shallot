#!/usr/bin/env python3
"""Mock RomM server for Shallot's test suite.

Implements the subset of the RomM Device Sync Protocol Shallot uses:
  GET  /api/heartbeat
  GET  /api/roms?limit=&offset=
  GET  /api/roms/{id}
  GET  /api/roms/{id}/download
  GET  /api/platforms/{id}
  POST /api/devices
  POST /api/sync/negotiate
  GET  /api/saves/{id}/content
  POST /api/saves            (multipart, conflict guard on overwrite=false)
  POST /api/devices/{id}/installs/claim
  PUT  /api/devices/{id}/installs/{request_id}
  GET  /api/_state           (test-only debug dump)

No deps beyond stdlib. Run: python3 mock-romm.py <port>
"""

import hashlib
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

TOKEN = "rmm_testtoken123"

ROMS = {
    123: {"id": 123, "name": "Zelda (USA).sfc", "fs_name": "Zelda (USA).sfc", "platform_id": 2},
    124: {"id": 124, "name": "Mario.sfc", "fs_name": "Mario.sfc", "platform_id": 2},
    125: {"id": 125, "name": "DK.nes", "fs_name": "DK.nes", "platform_id": 3},
}
PLATFORMS = {2: {"id": 2, "slug": "sfc"}, 3: {"id": 3, "slug": "nes"}}
ROM_FILES = {125: b"NES-ROM-BYTES-0001"}

# saves[(rom_id, slot)] = {save_id, file_name, content_hash, updated_at, content}
SAVES = {}
SAVE_SEQ = [0]

# devices[device_id] = name; baselines[(device_id, rom_id, slot)] = hash
DEVICES = {}
BASELINES = {}

# install requests: {"id", "rom_id", "status": pending|taken|done|failed, "reason"}
INSTALLS = []
INSTALL_SEQ = [0]


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def make_save(rom_id, file_name, content):
    SAVE_SEQ[0] += 1
    return {
        "save_id": SAVE_SEQ[0],
        "file_name": file_name,
        "content_hash": hashlib.md5(content).hexdigest(),
        "updated_at": now_iso(),
        "content": content,
    }


def parse_multipart(body, ctype):
    m = re.search(r'boundary="?([^";]+)"?', ctype)
    if not m:
        return {}
    boundary = ("--" + m.group(1)).encode()
    fields = {}
    for part in body.split(boundary):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        if b"\r\n\r\n" not in part:
            continue
        head, data = part.split(b"\r\n\r\n", 1)
        head = head.decode("utf-8", "replace")
        nm = re.search(r'name="([^"]+)"', head)
        fn = re.search(r'filename="([^"]+)"', head)
        if nm:
            fields[nm.group(1)] = (fn.group(1) if fn else None, data)
    return fields


def negotiate(device_id, payload):
    """Mirror the real protocol's decision table (device-side baseline aware)."""
    saves = payload.get("saves", [])
    rom_ids = payload.get("rom_ids", [])
    restore_unlisted = payload.get("restore_unlisted", False)
    local_by_rom = {}
    for s in saves:
        local_by_rom.setdefault(s["rom_id"], []).append(s)
    consider = set(rom_ids) | set(local_by_rom.keys())
    ops = []
    for rom_id in sorted(consider):
        slot = "autosave"
        key = (rom_id, slot)
        local = local_by_rom.get(rom_id)
        local = local[0] if local else None
        server = SAVES.get(key)
        base = BASELINES.get((device_id, rom_id, slot))
        if server and local:
            if local["content_hash"] == server["content_hash"]:
                ops.append({"action": "no_op", "rom_id": rom_id, "slot": slot})
            elif not base:
                ops.append({
                    "action": "conflict", "rom_id": rom_id, "slot": slot,
                    "save_id": server["save_id"], "file_name": server["file_name"],
                    "server_content_hash": server["content_hash"],
                    "server_updated_at": server["updated_at"],
                    "reason": "no device baseline",
                })
            elif base["hash"] == local["content_hash"] and base["hash"] != server["content_hash"]:
                ops.append({
                    "action": "download", "rom_id": rom_id, "slot": slot,
                    "save_id": server["save_id"], "file_name": server["file_name"],
                    "server_content_hash": server["content_hash"],
                    "server_updated_at": server["updated_at"],
                    "reason": "server save is newer",
                })
            elif base["hash"] == server["content_hash"] and base["hash"] != local["content_hash"]:
                ops.append({"action": "upload", "rom_id": rom_id, "slot": slot})
            else:
                ops.append({
                    "action": "conflict", "rom_id": rom_id, "slot": slot,
                    "save_id": server["save_id"], "file_name": server["file_name"],
                    "server_content_hash": server["content_hash"],
                    "reason": "both sides changed",
                })
        elif server and not local:
            if rom_id in rom_ids or restore_unlisted:
                ops.append({
                    "action": "download", "rom_id": rom_id, "slot": slot,
                    "save_id": server["save_id"], "file_name": server["file_name"],
                    "server_content_hash": server["content_hash"],
                    "server_updated_at": server["updated_at"],
                    "reason": "save not present locally",
                })
        elif local and not server:
            ops.append({"action": "upload", "rom_id": rom_id, "slot": slot})
    return {"session_id": 42, "operations": ops,
            "total_upload": sum(1 for o in ops if o["action"] == "upload"),
            "total_download": sum(1 for o in ops if o["action"] == "download"),
            "total_conflict": sum(1 for o in ops if o["action"] == "conflict"),
            "total_no_op": sum(1 for o in ops if o["action"] == "no_op")}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):  # noqa: A002 - stdlib signature
        pass

    def auth_ok(self):
        hdr = self.headers.get("Authorization", "")
        return hdr == f"Bearer {TOKEN}"

    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_bytes(self, data, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_body(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        return self.rfile.read(length)

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        p = u.path
        if not self.auth_ok():
            return self.send_json({"detail": "unauthorized"}, 401)
        if p == "/api/heartbeat":
            return self.send_json({"status": "ok"})
        if p == "/api/_state":
            return self.send_json({
                "saves": {f"{k[0]}/{k[1]}": {kk: vv for kk, vv in v.items() if kk != "content"}
                          for k, v in SAVES.items()},
                "baselines": {f"{k[0]}/{k[1]}/{k[2]}": v["hash"] for k, v in BASELINES.items()},
                "installs": INSTALLS, "devices": DEVICES,
            })
        if p == "/api/roms":
            limit = int(q.get("limit", ["500"])[0])
            offset = int(q.get("offset", ["0"])[0])
            items = list(ROMS.values())
            return self.send_json(items[offset:offset + limit])
        m = re.match(r"^/api/roms/(\d+)/download$", p)
        if m:
            rom = ROMS.get(int(m.group(1)))
            if rom and rom["id"] in ROM_FILES:
                return self.send_bytes(ROM_FILES[rom["id"]], "application/octet-stream")
            return self.send_json({"detail": "no file"}, 404)
        m = re.match(r"^/api/roms/(\d+)$", p)
        if m:
            rom = ROMS.get(int(m.group(1)))
            return self.send_json(rom, 200) if rom else self.send_json({"detail": "nf"}, 404)
        m = re.match(r"^/api/platforms/(\d+)$", p)
        if m:
            plat = PLATFORMS.get(int(m.group(1)))
            return self.send_json(plat, 200) if plat else self.send_json({"detail": "nf"}, 404)
        m = re.match(r"^/api/saves/(\d+)/content$", p)
        if m:
            sid = int(m.group(1))
            for k, v in SAVES.items():
                if v["save_id"] == sid:
                    dev = q.get("device_id", [None])[0]
                    if dev:
                        BASELINES[(dev, k[0], k[1])] = {"hash": v["content_hash"]}
                    return self.send_bytes(v["content"], "application/octet-stream")
            return self.send_json({"detail": "nf"}, 404)
        return self.send_json({"detail": "nf"}, 404)

    def do_POST(self):
        u = urlparse(self.path)
        p = u.path
        if not self.auth_ok():
            return self.send_json({"detail": "unauthorized"}, 401)
        if p == "/api/devices":
            body = json.loads(self.read_body() or b"{}")
            dev_id = "dev-" + body.get("name", "x").lower().replace(" ", "-")
            DEVICES[dev_id] = body.get("name", "")
            return self.send_json({"id": dev_id, "name": body.get("name")}, 201)
        if p == "/api/sync/negotiate":
            body = json.loads(self.read_body() or b"{}")
            return self.send_json(negotiate(body.get("device_id", ""), body))
        if p == "/api/saves":
            body = self.read_body()
            fields = parse_multipart(body, self.headers.get("Content-Type", ""))
            f = fields.get("saveFile")
            if not f:
                return self.send_json({"detail": "missing saveFile"}, 400)
            rom_id = int(u.query.split("rom_id=")[1].split("&")[0])
            params = dict(kv.split("=", 1) for kv in u.query.split("&") if "=" in kv)
            content_hash = params.get("content_hash", "")
            overwrite = params.get("overwrite", "false") == "true"
            device_id = params.get("device_id", "")
            key = (rom_id, params.get("slot", "autosave"))
            if key in SAVES and not overwrite:
                server = SAVES[key]
                base = BASELINES.get((device_id, rom_id, key[1]))
                if not base or base["hash"] != server["content_hash"]:
                    return self.send_json({"detail": "conflict"}, 409)
            save = make_save(rom_id, f[0] or "save.bin", f[1])
            save["content_hash"] = content_hash or save["content_hash"]
            SAVES[key] = save
            if device_id:
                BASELINES[(device_id, rom_id, key[1])] = {"hash": save["content_hash"]}
            return self.send_json({"id": save["save_id"], "file_name": save["file_name"],
                                   "content_hash": save["content_hash"]}, 201)
        m = re.match(r"^/api/devices/([^/]+)/installs/claim$", p)
        if m:
            was_taken = {r["id"] for r in INSTALLS if r["status"] == "taken"}
            claimed = [r for r in INSTALLS if r["status"] == "pending"]
            for r in claimed:
                r["status"] = "taken"
            held = [r for r in INSTALLS if r["status"] == "taken" and r["id"] not in was_taken]
            return self.send_json(claimed + held, 200)
        return self.send_json({"detail": "nf"}, 404)

    def do_PUT(self):
        u = urlparse(self.path)
        m = re.match(r"^/api/devices/([^/]+)/installs/(\d+)$", u.path)
        if not self.auth_ok():
            return self.send_json({"detail": "unauthorized"}, 401)
        if m:
            body = json.loads(self.read_body() or b"{}")
            for r in INSTALLS:
                if str(r["id"]) == m.group(2):
                    r["status"] = body.get("status", r["status"])
                    return self.send_json(r)
            return self.send_json({"detail": "nf"}, 404)
        return self.send_json({"detail": "nf"}, 404)


def main():
    port = int(sys.argv[1])
    # seed: one server-side save for rom 123, one queued install for rom 125
    SAVES[(123, "autosave")] = make_save(123, "Zelda (USA).srm", b"SERVER-SAVE-V1")
    INSTALLS.append({"id": 1, "rom_id": 125, "status": "pending", "reason": ""})
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
