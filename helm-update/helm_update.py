#!/usr/bin/env python3
"""Check latest helm chart versions and update targetRevision in ArgoCD application.yaml files."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

import requests
import yaml


REPO_SSH_URL = os.environ["GIT_REPO_SSH_URL"]   # e.g. git@github.com:bahn1075/mykubernetes.git
GIT_USER = os.environ.get("GIT_USER", "helm-update-bot")
GIT_EMAIL = os.environ.get("GIT_EMAIL", "helm-update@bot.local")
HELM_PATH = os.environ.get("HELM_SUBPATH", "helm")  # subdirectory inside repo to search


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
    # index.yaml entries are sorted newest-first
    return entries[0]["version"]


def update_file(path: Path, old_rev: str, new_rev: str) -> bool:
    text = path.read_text()
    updated = text.replace(f"targetRevision: {old_rev}", f"targetRevision: {new_rev}")
    if updated == text:
        return False
    path.write_text(updated)
    return True


def main() -> None:
    setup_ssh()

    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["git", "clone", REPO_SSH_URL, tmp], check=True)
        subprocess.run(["git", "config", "user.name", GIT_USER], cwd=tmp, check=True)
        subprocess.run(["git", "config", "user.email", GIT_EMAIL], cwd=tmp, check=True)

        changed: list[str] = []

        for app_file in sorted(Path(tmp, HELM_PATH).rglob("application.yaml")):
            doc = yaml.safe_load(app_file.read_text())
            if not doc or doc.get("kind") != "Application":
                continue

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
                    continue

                if latest == current_rev:
                    print(f"OK   {chart} {current_rev}")
                    continue

                print(f"UP   {chart}: {current_rev} -> {latest}")
                if update_file(app_file, current_rev, latest):
                    rel = str(app_file.relative_to(tmp))
                    changed.append(f"{rel}: {chart} {current_rev} -> {latest}")
                    subprocess.run(["git", "add", str(app_file)], cwd=tmp, check=True)

        if not changed:
            print("All charts up to date.")
            return

        commit_msg = "chore: update helm chart revisions\n\n" + "\n".join(f"- {c}" for c in changed)
        subprocess.run(["git", "commit", "-m", commit_msg], cwd=tmp, check=True)
        subprocess.run(["git", "push"], cwd=tmp, check=True)
        print(f"Pushed {len(changed)} update(s).")


if __name__ == "__main__":
    main()
