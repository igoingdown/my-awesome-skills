#!/usr/bin/env python3
"""Generic Grafana dashboard push — ships with the grafana-as-code skill.

Works for ANY service repo: point it at one or more dashboard JSON files, give
it a folder, done. Idempotent: folder is created if missing (stable uid derived
from the folder title), dashboards are upserted by their JSON `uid`, so re-runs
update in place and never duplicate.

Usage:
    source ~/github/my_dot_files/secrets.sh    # injects GRAFANA_URL / GRAFANA_TOKEN
    python3 push_dashboard.py --folder memory-service path/to/dashboard.json [more.json ...]
    python3 push_dashboard.py --folder memory-service --datasource efflgyrdjhyiof dash.json
    python3 push_dashboard.py --dry-run --folder x dash.json     # validate + plan, no network

Datasource pinning (--datasource NAME_OR_UID, or env GRAFANA_DATASOURCE):
    unset  -> auto: exactly one Prometheus datasource on the instance = use it;
              several = leave panels as-authored and print the candidates.
    set    -> pin every panel/target to it; unknown value fails listing options.

Known pitfalls this script absorbs (see references/dashboards.md for detail):
- folder-scoped service-account tokens: creating a folder grants the SA admin on
  it, but NOT within the same run — a first run may 403 on the dashboard write
  right after creating the folder. Just re-run; second run succeeds.
- folderId (numeric) is deprecated; this script only uses folderUid.
- after push it reads the dashboard back and asserts it landed in the target
  folder — "success" from the write API alone does not prove placement.

Token permissions: folders:read/create, dashboards:read/write; datasources:read
only needed for auto-pin (absence degrades gracefully).
Requires: python3 + httpx (uv run / pipx / venv all fine).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

import httpx


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def folder_uid_for(title: str) -> str:
    """Stable, readable folder uid derived from the title (Grafana uid charset)."""
    uid = re.sub(r"[^a-zA-Z0-9_-]", "-", title.strip().lower())
    return uid[:40] or "general"


def client() -> httpx.Client:
    url = os.environ.get("GRAFANA_URL", "").rstrip("/")
    token = os.environ.get("GRAFANA_TOKEN", "")
    if not url or not token:
        die("GRAFANA_URL / GRAFANA_TOKEN not set — source secrets.sh first (see SKILL.md §0)")
    return httpx.Client(base_url=url, headers={"Authorization": f"Bearer {token}"}, timeout=30)


def ensure_folder(api: httpx.Client, title: str) -> str:
    uid = folder_uid_for(title)
    r = api.get("/api/folders")
    r.raise_for_status()
    for folder in r.json():
        if folder["title"] == title or folder["uid"] == uid:
            print(f"folder exists: {folder['title']} (uid={folder['uid']})")
            return folder["uid"]
    r = api.post("/api/folders", json={"title": title, "uid": uid})
    r.raise_for_status()
    print(f"folder created: {title} (uid={uid})")
    return uid


def resolve_datasource(api: httpx.Client, want: str) -> dict | None:
    r = api.get("/api/datasources")
    if r.status_code == 403:
        print("warn: token lacks datasources:read, leaving panels as-authored")
        return None
    r.raise_for_status()
    proms = [ds for ds in r.json() if ds.get("type") == "prometheus"]
    if want:
        for ds in proms:
            if want in (ds.get("name"), ds.get("uid")):
                return {"type": "prometheus", "uid": ds["uid"]}
        die(f"datasource {want!r} not found; prometheus datasources: "
            + ", ".join(f"{d['name']} (uid={d['uid']})" for d in proms))
    if len(proms) == 1:
        print(f"auto-pinning datasource: {proms[0]['name']} (uid={proms[0]['uid']})")
        return {"type": "prometheus", "uid": proms[0]["uid"]}
    if proms:
        print(f"note: {len(proms)} prometheus datasources, leaving panels as-authored. "
              "Pass --datasource to pin one:")
        for d in proms:
            print(f"  - {d['name']} (uid={d['uid']})")
    return None


def pin_datasource(dashboard: dict, ds: dict) -> None:
    for panel in dashboard.get("panels", []):
        if panel.get("type") == "row":
            continue
        panel["datasource"] = ds
        for target in panel.get("targets", []):
            target["datasource"] = ds


def lint(dashboard: dict, path: Path) -> list[str]:
    """Non-fatal convention checks from references/dashboards.md."""
    warnings = []
    if not dashboard.get("uid"):
        warnings.append(f"{path.name}: missing dashboard uid — upsert will not be idempotent")
    for panel in dashboard.get("panels", []):
        title = panel.get("title", "?")
        if panel.get("type") == "timeseries":
            leg = panel.get("options", {}).get("legend", {})
            if leg.get("calcs") != ["mean", "max"] or leg.get("sortBy") != "Mean" or not leg.get("sortDesc"):
                warnings.append(f"{path.name} / {title}: timeseries legend should be "
                                'table with calcs ["mean","max"], sortBy "Mean" desc')
        if panel.get("type") in ("stat", "gauge", "bargauge"):
            calcs = panel.get("options", {}).get("reduceOptions", {}).get("calcs")
            if calcs and calcs != ["mean"]:
                warnings.append(f"{path.name} / {title}: reducer should be [\"mean\"], got {calcs}")
    return warnings


def push_one(api: httpx.Client, path: Path, folder_uid: str, ds: dict | None) -> None:
    dashboard = json.loads(path.read_text())
    dashboard.pop("__inputs", None)
    dashboard["id"] = None  # match by uid, never numeric id
    if ds:
        pin_datasource(dashboard, ds)
    r = api.post("/api/dashboards/db", json={
        "dashboard": dashboard,
        "folderUid": folder_uid,
        "overwrite": True,
        "message": f"push_dashboard.py ({path.name})",
    })
    if r.status_code == 403:
        die(f"{path.name}: 403 on dashboard write. If the folder was just created by this "
            "run, this is the known folder-SA-grant race — simply re-run the command.")
    if r.status_code != 200:
        die(f"{path.name}: push failed HTTP {r.status_code}: {r.text[:400]}")
    result = r.json()
    print(f"pushed {path.name}: {result['status']} version={result.get('version')}")
    print(f"  url: {os.environ['GRAFANA_URL'].rstrip('/')}{result['url']}")
    check = api.get(f"/api/dashboards/uid/{dashboard['uid']}")
    check.raise_for_status()
    meta = check.json()["meta"]
    if meta.get("folderUid") != folder_uid:
        die(f"{path.name}: landed in folder {meta.get('folderUid')!r}, expected {folder_uid!r}")
    print(f"  verified in folder: {meta.get('folderTitle')}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dashboards", nargs="+", type=Path, help="dashboard JSON file(s)")
    ap.add_argument("--folder", required=True, help="target Grafana folder title")
    ap.add_argument("--datasource", default=os.environ.get("GRAFANA_DATASOURCE", ""),
                    help="Prometheus datasource name or uid to pin (default: auto)")
    ap.add_argument("--dry-run", action="store_true", help="validate + lint only, no network")
    args = ap.parse_args()

    for path in args.dashboards:
        if not path.exists():
            die(f"not found: {path}")
        for w in lint(json.loads(path.read_text()), path):
            print(f"lint: {w}")

    if args.dry_run:
        print(f"dry-run OK: would push {len(args.dashboards)} dashboard(s) to folder "
              f"'{args.folder}' (uid={folder_uid_for(args.folder)})")
        return

    api = client()
    folder_uid = ensure_folder(api, args.folder)
    ds = resolve_datasource(api, args.datasource.strip())
    for path in args.dashboards:
        push_one(api, path, folder_uid, ds)


if __name__ == "__main__":
    main()
