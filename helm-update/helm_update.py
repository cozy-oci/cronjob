#!/usr/bin/env python3
"""Check latest helm chart versions and update targetRevision in ArgoCD application.yaml files."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path

import requests
import yaml


REPO_SSH_URL = os.environ["GIT_REPO_SSH_URL"]
GIT_USER = os.environ.get("GIT_USER", "helm-update-bot")
GIT_EMAIL = os.environ.get("GIT_EMAIL", "helm-update@bot.local")
HELM_PATH = os.environ.get("HELM_SUBPATH", "helm")
DISCORD_TOKEN = os.environ.get("DISCORD_TOKEN", "")
DISCORD_CHANNEL = os.environ.get("DISCORD_CHANNEL", "")
ALLOW_PRERELEASE = os.environ.get("ALLOW_PRERELEASE", "").lower() in {"1", "true", "yes"}


def setup_ssh() -> None:
    ssh_key = os.environ.get("GIT_SSH_KEY", "")
    known_hosts = os.environ.get("GIT_SSH_KNOWN_HOSTS", "")
    if not ssh_key:
        return
    ssh_dir = Path.home() / ".ssh"
    ssh_dir.mkdir(mode=0o700, exist_ok=True)
    key_path = ssh_dir / "id_ed25519"
    key_path.write_text(ssh_key.strip() + "\n")
    key_path.chmod(0o600)
    if known_hosts:
        (ssh_dir / "known_hosts").write_text(known_hosts)


def latest_chart_version(repo_url: str, chart: str) -> str:
    index_url = repo_url.rstrip("/") + "/index.yaml"
    resp = requests.get(index_url, timeout=30)
    resp.raise_for_status()
    index = yaml.safe_load(resp.text)
    entries = index.get("entries", {}).get(chart, [])
    if not entries:
        raise ValueError(f"chart '{chart}' not found in {index_url}")
    for entry in entries:
        version = entry.get("version", "")
        if version and (ALLOW_PRERELEASE or "-" not in version):
            return version
    raise ValueError(f"stable chart version for '{chart}' not found in {index_url}")


def update_file(path: Path, old_rev: str, new_rev: str) -> bool:
    text = path.read_text()
    updated = text.replace(f"targetRevision: {old_rev}", f"targetRevision: {new_rev}")
    if updated == text:
        return False
    path.write_text(updated)
    return True


def send_discord(message: str) -> None:
    if not DISCORD_TOKEN or not DISCORD_CHANNEL:
        print("[Discord] 토큰 또는 채널 ID 없음 — 전송 건너뜀")
        return
    if len(message) > 1900:
        message = message[:1850] + "\n... (truncated)"
    url = f"https://discord.com/api/v10/channels/{DISCORD_CHANNEL}/messages"
    payload = json.dumps({"content": message}, ensure_ascii=False)
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as f:
        f.write(payload)
        payload_path = f.name
    result = subprocess.run(
        ["curl", "-fsS", "-X", "POST", url,
         "-H", f"Authorization: Bot {DISCORD_TOKEN}",
         "-H", "Content-Type: application/json",
         "-d", f"@{payload_path}"],
        capture_output=True, text=True,
    )
    os.unlink(payload_path)
    if result.returncode == 0:
        print("[Discord] 리포트 전송 완료")
    else:
        print(f"[Discord] 전송 실패: {(result.stderr or result.stdout).strip()}")


def main() -> None:
    setup_ssh()
    started_at = datetime.now().strftime("%Y-%m-%d %H:%M")

    report_lines: list[str] = []
    updated_count = 0
    ok_count = 0
    fail_count = 0
    pushed = False

    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["git", "clone", REPO_SSH_URL, tmp], check=True)
        subprocess.run(["git", "config", "user.name", GIT_USER], cwd=tmp, check=True)
        subprocess.run(["git", "config", "user.email", GIT_EMAIL], cwd=tmp, check=True)

        changed: list[str] = []

        for app_file in sorted(Path(tmp, HELM_PATH).rglob("application.yaml")):
            doc = yaml.safe_load(app_file.read_text())
            if not doc or doc.get("kind") != "Application":
                continue

            app_name = app_file.parent.name

            sources = doc.get("spec", {}).get("sources", [])
            for source in sources:
                chart = source.get("chart")
                repo_url = source.get("repoURL", "")
                current_rev = source.get("targetRevision", "")
                if not chart or not current_rev or current_rev == "main":
                    continue
                try:
                    latest = latest_chart_version(repo_url, chart)
                except Exception as exc:
                    print(f"WARN {chart}: {exc}")
                    report_lines.append(f"❌ **{app_name}**: 최신 버전 조회 실패 (현재: `{current_rev}`)")
                    fail_count += 1
                    continue

                if latest == current_rev:
                    print(f"OK   {chart} {current_rev}")
                    report_lines.append(f"✅ **{app_name}**: `{current_rev}` (최신)")
                    ok_count += 1
                    continue

                print(f"UP   {chart}: {current_rev} -> {latest}")
                if update_file(app_file, current_rev, latest):
                    report_lines.append(f"⬆️ **{app_name}**: `{current_rev}` → `{latest}`")
                    changed.append(f"{app_name}: {current_rev} → {latest}")
                    updated_count += 1
                    subprocess.run(["git", "add", str(app_file)], cwd=tmp, check=True)

        if changed:
            commit_msg = "chore: update helm chart revisions\n\n" + "\n".join(f"- {c}" for c in changed)
            subprocess.run(["git", "commit", "-m", commit_msg], cwd=tmp, check=True)
            result = subprocess.run(["git", "push"], cwd=tmp, capture_output=True, text=True)
            if result.returncode == 0:
                pushed = True
                print(f"Pushed {len(changed)} update(s).")
            else:
                fail_count += 1
                report_lines.append(f"❌ Git push 실패: {result.stderr.strip()}")
        else:
            print("All charts up to date.")

    # Discord 보고서 전송
    body = "\n".join(report_lines)
    push_line = "\n🚀 Git push 완료 — ArgoCD 자동 배포 진행 중" if pushed else ""
    message = (
        f"🔄 **주간 Helm Chart 업데이트** ({started_at})\n\n"
        f"{body}\n\n"
        f"📊 업데이트: {updated_count} | 최신: {ok_count} | 실패: {fail_count}"
        f"{push_line}"
    )
    send_discord(message)


if __name__ == "__main__":
    main()
