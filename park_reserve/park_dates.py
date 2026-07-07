#!/usr/bin/env python3
"""Record/read actual parking dates in a Kubernetes ConfigMap.

park_reserve.py records the parking date (REQ_DATE) here on business success;
park_notify.py reads it every morning and announces on the day itself.
Outside a cluster (no service account token) every call degrades to a no-op
so local/manual runs keep working.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.request

CONFIGMAP_NAME = os.environ.get("PARK_DATES_CONFIGMAP", "park-reserve-dates")
_SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"


def _log(message: str) -> None:
    print(f"[park_dates] {message}", file=sys.stderr, flush=True)


def _cluster_ctx() -> dict | None:
    host = os.environ.get("KUBERNETES_SERVICE_HOST")
    port = os.environ.get("KUBERNETES_SERVICE_PORT", "443")
    if not host:
        return None
    try:
        with open(f"{_SA_DIR}/token", encoding="utf-8") as fh:
            token = fh.read().strip()
        with open(f"{_SA_DIR}/namespace", encoding="utf-8") as fh:
            namespace = fh.read().strip()
    except OSError:
        return None
    return {
        "base": f"https://{host}:{port}/api/v1/namespaces/{namespace}/configmaps",
        "token": token,
        "ssl": ssl.create_default_context(cafile=f"{_SA_DIR}/ca.crt"),
    }


def _request(ctx: dict, method: str, url: str, body: dict | None = None,
             content_type: str = "application/json") -> dict:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {ctx['token']}")
    if data is not None:
        req.add_header("Content-Type", content_type)
    with urllib.request.urlopen(req, context=ctx["ssl"], timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


def record_date(date_str: str, note: str = "reserved") -> bool:
    """Add one parking date ('YYYY.MM.DD') to the ConfigMap, creating it if needed."""
    ctx = _cluster_ctx()
    if not ctx:
        _log("not running in a cluster; skipping parking-date record")
        return False
    patch = {"data": {date_str: note}}
    try:
        _request(ctx, "PATCH", f"{ctx['base']}/{CONFIGMAP_NAME}", patch,
                 "application/merge-patch+json")
        _log(f"recorded parking date {date_str} in {CONFIGMAP_NAME}")
        return True
    except urllib.error.HTTPError as exc:
        if exc.code != 404:
            _log(f"record failed: HTTP {exc.code} {exc.read().decode(errors='replace')[:200]}")
            return False
    except urllib.error.URLError as exc:
        _log(f"record failed: {exc}")
        return False

    body = {
        "apiVersion": "v1",
        "kind": "ConfigMap",
        "metadata": {"name": CONFIGMAP_NAME},
        "data": {date_str: note},
    }
    try:
        _request(ctx, "POST", ctx["base"], body)
        _log(f"created {CONFIGMAP_NAME} with parking date {date_str}")
        return True
    except (urllib.error.HTTPError, urllib.error.URLError) as exc:
        _log(f"configmap create failed: {exc}")
        return False


def get_dates() -> dict[str, str]:
    """Return all recorded parking dates ({'YYYY.MM.DD': note})."""
    ctx = _cluster_ctx()
    if not ctx:
        _log("not running in a cluster; no parking dates")
        return {}
    try:
        obj = _request(ctx, "GET", f"{ctx['base']}/{CONFIGMAP_NAME}")
        return obj.get("data") or {}
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return {}
        raise


def remove_dates(date_strs: list[str]) -> bool:
    """Delete the given date keys from the ConfigMap (merge-patch null)."""
    if not date_strs:
        return True
    ctx = _cluster_ctx()
    if not ctx:
        return False
    patch = {"data": {key: None for key in date_strs}}
    try:
        _request(ctx, "PATCH", f"{ctx['base']}/{CONFIGMAP_NAME}", patch,
                 "application/merge-patch+json")
        return True
    except (urllib.error.HTTPError, urllib.error.URLError) as exc:
        _log(f"remove failed: {exc}")
        return False
