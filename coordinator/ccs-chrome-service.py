#!/usr/bin/env python3
"""ccs-chrome-service — tiny HTTP service to open/close a Chrome profile with CDP.

Runs on the gass server (as root, so it can kill Chrome regardless of owner).

  POST /open   profile=<name>   -> kill whatever holds the CDP port, start
                                   non-headless Chrome on DISPLAY with
                                   --user-data-dir=<PROFILE_BASE>/<name>
  POST /close  profile=<name>   -> kill Chrome using that profile
  GET  /status                  -> JSON: running profile + CDP alive

Body: form-encoded (profile=ciptafile.cv) or JSON ({"profile": "ciptafile.cv"}).
"""
import json
import re
import subprocess
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

LISTEN_PORT = 9334
CDP_PORT = 9333
DISPLAY = ":0"
PROFILE_BASE = "/home/gass/.config/google-chrome"
CHROME_USER = "gass"  # Chrome runs as this user, not root
PROFILE_RE = re.compile(r"^[A-Za-z0-9._-]+$")

CHROME_ARGS = (
    "--remote-debugging-port={port} --remote-allow-origins='*' "
    "--user-data-dir={profile_dir} --no-first-run --no-default-browser-check"
)


def sh(cmd, timeout=15):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)


def cdp_alive():
    try:
        urllib.request.urlopen(f"http://localhost:{CDP_PORT}/json/version", timeout=3)
        return True
    except Exception:
        return False


def running_chrome():
    """Return (profile_dir, headless) of the Chrome holding the CDP port, or (None, False)."""
    r = sh(f"pgrep -af -- '--remote-debugging-port={CDP_PORT}'")
    m = re.search(r"--user-data-dir=(\S+)", r.stdout)
    return (m.group(1) if m else None), "--headless" in r.stdout


def running_profile():
    return running_chrome()[0]


def kill_chrome():
    sh(f"pkill -f -- '--remote-debugging-port={CDP_PORT}'")
    for _ in range(10):
        if not cdp_alive():
            return True
        time.sleep(1)
    sh(f"pkill -9 -f -- '--remote-debugging-port={CDP_PORT}'")
    time.sleep(1)
    return not cdp_alive()


def mark_clean_exit(profile_dir):
    """Clear the crashed-exit flag so Chrome doesn't show 'Profile error occurred'
    after we killed the previous instance."""
    for rel, keys in (
        ("Default/Preferences", ("profile",)),
        ("Local State", ("profile", "info_cache")),
    ):
        path = f"{profile_dir}/{rel}"
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, json.JSONDecodeError):
            continue
        if rel == "Default/Preferences":
            prof = data.setdefault("profile", {})
            prof["exit_type"] = "Normal"
            prof["exited_cleanly"] = True
        else:
            for info in data.get("profile", {}).get("info_cache", {}).values():
                info["exited_cleanly"] = True
        try:
            with open(path, "w") as f:
                json.dump(data, f)
        except OSError:
            pass


def start_chrome(profile):
    profile_dir = f"{PROFILE_BASE}/{profile}"
    mark_clean_exit(profile_dir)
    # Profile files may be root-owned (service writes, or an old root Chrome).
    # Chrome runs as CHROME_USER and must own its profile or it errors out.
    sh(f"chown -R {CHROME_USER}:{CHROME_USER} '{profile_dir}'", timeout=60)
    args = CHROME_ARGS.format(port=CDP_PORT, profile_dir=profile_dir)
    # Run as CHROME_USER on the VNC display; root-owned Chrome broke profile perms before.
    sh(
        f"runuser -u {CHROME_USER} -- bash -c "
        f"\"DISPLAY={DISPLAY} nohup google-chrome {args} >/dev/null 2>&1 & disown\""
    )
    for _ in range(15):
        if cdp_alive():
            return True
        time.sleep(1)
    return False


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _profile_param(self):
        # Accept profile from: URL query string, form body, or JSON body —
        # regardless of Content-Type (proxies/clients get this wrong).
        qs = urllib.parse.urlparse(self.path).query
        profile = urllib.parse.parse_qs(qs).get("profile", [""])[0]
        if not profile:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length).decode(errors="replace") if length else ""
            profile = urllib.parse.parse_qs(raw).get("profile", [""])[0]
            if not profile and raw.lstrip().startswith("{"):
                try:
                    profile = json.loads(raw).get("profile", "")
                except json.JSONDecodeError:
                    pass
        if not PROFILE_RE.match(profile or ""):
            return None
        return profile

    def do_GET(self):
        if urllib.parse.urlparse(self.path).path != "/status":
            return self._reply(404, {"error": "not found"})
        self._reply(200, {"profile": running_profile(), "cdp_alive": cdp_alive()})

    def do_POST(self):
        route = urllib.parse.urlparse(self.path).path
        if route not in ("/open", "/close"):
            return self._reply(404, {"error": "not found"})
        profile = self._profile_param()
        if not profile:
            return self._reply(400, {"error": "missing/invalid profile (allowed: A-Za-z0-9._-)"})

        if route == "/close":
            current = running_profile()
            if current and not current.endswith("/" + profile):
                return self._reply(409, {"error": "different profile running", "running": current})
            ok = kill_chrome()
            return self._reply(200 if ok else 500, {"closed": ok, "profile": profile})

        # /open
        current, headless = running_chrome()
        target = f"{PROFILE_BASE}/{profile}"
        if current == target and not headless and cdp_alive():
            return self._reply(200, {"started": True, "already_running": True, "profile": profile})
        if current and not kill_chrome():
            return self._reply(500, {"error": "could not kill existing chrome", "running": current})
        ok = start_chrome(profile)
        self._reply(200 if ok else 500, {"started": ok, "profile": profile, "cdp_port": CDP_PORT})

    def log_message(self, fmt, *args):
        print(f"{self.address_string()} {fmt % args}", flush=True)


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
