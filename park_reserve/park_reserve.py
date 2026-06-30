#!/usr/bin/env python3
"""Reserve LG CNS short-term employee parking through Edge on the Mac host.

This script is intended to run from this Linux host, then execute Playwright on
the Tailscale-reachable Mac via SSH because the target site is verified there.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo


def _load_env_file() -> None:
    """Load key=value pairs from .env in the script directory into os.environ."""
    env_path = Path(__file__).parent / ".env"
    try:
        with env_path.open(encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                os.environ[key] = val
    except FileNotFoundError:
        pass


DEFAULT_TIMEZONE = "Asia/Seoul"


REMOTE_SCRIPT = r"""
import json
import os
import re
import sys
import time
import base64
from datetime import datetime, timezone, timedelta

from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
from playwright.sync_api import sync_playwright


EDGE = "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
KST = timezone(timedelta(hours=9))


def log(message):
    ts = datetime.now(KST).strftime("%H:%M:%S")
    print(f"[{ts}] {message}", file=sys.stderr, flush=True)


def find_frame(page, selector, timeout_ms=60000):
    deadline = time.time() + timeout_ms / 1000
    while time.time() < deadline:
        for frame in page.frames:
            try:
                if frame.locator(selector).count() > 0:
                    return frame
            except Exception:
                pass
        page.wait_for_timeout(500)
    urls = [frame.url for frame in page.frames]
    raise RuntimeError(f"Could not find selector {selector!r} in frames: {urls}")


def safe_body_text(frame, limit=2000):
    try:
        return frame.locator("body").inner_text(timeout=3000)[:limit]
    except Exception as exc:
        return f"<body unavailable: {type(exc).__name__}>"


def capture_screenshot(page, result, name):
    path = f"/tmp/{name}.png"
    page.screenshot(path=path, full_page=True)
    with open(path, "rb") as file:
        result["screenshot_base64"] = base64.b64encode(file.read()).decode("ascii")
    result["screenshot_name"] = f"{name}.png"


def click_visible_text(page, text, timeout_ms=10000):
    deadline = time.time() + timeout_ms / 1000
    selectors = [
        f"button:has-text('{text}')",
        f"a:has-text('{text}')",
        f"input[value='{text}']",
    ]
    while time.time() < deadline:
        for frame in page.frames:
            for selector in selectors:
                try:
                    locator = frame.locator(selector).first
                    if locator.count() and locator.is_visible():
                        locator.click(force=True, timeout=3000)
                        return True
                except Exception:
                    pass
        page.wait_for_timeout(500)
    return False


def parse_ymd(value):
    match = re.search(r"(\d{4})[.\-/](\d{1,2})[.\-/](\d{1,2})", value or "")
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def month_delta(from_ymd, to_ymd):
    return (to_ymd[0] - from_ymd[0]) * 12 + (to_ymd[1] - from_ymd[1])


def click_datepicker_nav(page, direction, timeout_ms=5000):
    selectors = [
        f"th.{direction}",
        f".datepicker-days th.{direction}",
        f".datepicker .{direction}",
        f"[class*='datepicker'] th.{direction}",
    ]
    deadline = time.time() + timeout_ms / 1000
    while time.time() < deadline:
        for frame in page.frames:
            for selector in selectors:
                try:
                    locator = frame.locator(selector).first
                    if locator.count() and locator.is_visible():
                        locator.click(force=True, timeout=1000)
                        return True
                except Exception:
                    pass
        page.wait_for_timeout(200)
    return False


def main():
    cfg = json.loads(PAYLOAD_JSON)
    password = cfg.get("password")
    if not password:
        raise RuntimeError("password is empty")

    result = {
        "target_url": cfg["target_url"],
        "target_date": cfg["target_date"],
        "dry_run": cfg["dry_run"],
        "dialogs": [],
        "steps": [],
        "business_success": False,
        "submitted": False,
    }

    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path=EDGE,
            headless=True,
            args=["--disable-gpu", "--no-first-run"],
        )
        context = browser.new_context(
            ignore_https_errors=True,
            viewport={"width": 1440, "height": 1000},
        )
        page = context.new_page()

        def on_dialog(dialog):
            message = dialog.message
            result["dialogs"].append(message)
            log(f"dialog: {message}")
            dialog.accept()

        page.on("dialog", on_dialog)

        log("opening target page")
        page.goto(cfg["target_url"], wait_until="domcontentloaded", timeout=60000)
        page.wait_for_timeout(1000)

        if "lil.lgcns.com/Account/Login" in page.url:
            result["steps"].append("login_page")
            log("logging in")
            page.locator('input[name="ID"]').fill(cfg["employee_id"], timeout=30000)
            page.locator('input[name="Password"]').fill(password, timeout=30000)
            submit = page.locator('button[type="submit"], input[type="submit"]').first
            submit.click(timeout=30000)

        deadline = time.time() + 90
        while time.time() < deadline:
            if "uservice.lgcns.com/LGCNS.SV.MAIN/Frame/MainFrame.aspx" in page.url:
                break
            page.wait_for_timeout(1000)

        result["after_login_url"] = page.url
        result["after_login_title"] = page.title()
        result["returned_to_target"] = (
            "uservice.lgcns.com/LGCNS.SV.MAIN/Frame/MainFrame.aspx" in page.url
            and "menuId=SVREQ1801" in page.url
        )
        if not result["returned_to_target"]:
            raise RuntimeError(f"Login did not return to target page: {page.url}")

        list_frame = find_frame(page, "#RequestParking", timeout_ms=90000)
        result["list_frame_url"] = list_frame.url
        result["list_text"] = safe_body_text(list_frame)
        if "임직원 단기주차 신청 내역" not in result["list_text"]:
            raise RuntimeError("Target list page text was not found")

        log("opening request form")
        list_frame.locator("#RequestParking").click(force=True, timeout=30000)
        form_frame = find_frame(page, "#EMP_CAR_NO", timeout_ms=60000)
        result["form_frame_url"] = form_frame.url
        result["form_text_before"] = safe_body_text(form_frame)
        if "임직원 단기주차 신청" not in result["form_text_before"]:
            raise RuntimeError("Parking request form text was not found")

        log("filling request form")
        form_frame.locator("#EMP_CAR_NO").fill(cfg["car_no"], timeout=30000)

        # The date input is controlled by a calendar widget that overrides fill().
        # Move the visible picker month first, then click the target day cell.
        target_ymd = parse_ymd(cfg["target_date"])
        if not target_ymd:
            raise RuntimeError(f"Invalid target date: {cfg['target_date']}")
        target_day = str(target_ymd[2])  # "2026.06.22" -> "22"
        log(f"opening date picker (target date: {cfg['target_date']})")
        form_frame.locator("#REQ_DATE").click(force=True, timeout=10000)
        page.wait_for_timeout(600)

        current_req_date = form_frame.locator("#REQ_DATE").input_value(timeout=3000)
        current_ymd = parse_ymd(current_req_date)
        if current_ymd:
            diff = month_delta(current_ymd, target_ymd)
            direction = "next" if diff > 0 else "prev"
            for _ in range(abs(diff)):
                if not click_datepicker_nav(page, direction):
                    raise RuntimeError(
                        f"Could not move date picker {direction} from {current_req_date} to {cfg['target_date']}"
                    )
                page.wait_for_timeout(300)
            if diff:
                log(f"date picker moved {diff:+d} month(s)")
        else:
            log(f"WARNING: could not parse current request date: {current_req_date!r}")

        date_selected = False
        deadline = time.time() + 10
        while not date_selected and time.time() < deadline:
            for frame in page.frames:
                try:
                    for sel in [
                        "td.day:not(.disabled):not(.old):not(.new)",
                        "td.day:not(.disabled)",
                        "td:not(.disabled):not(.old):not(.new)",
                    ]:
                        cells = frame.locator(sel)
                        count = cells.count()
                        for i in range(count):
                            try:
                                cell = cells.nth(i)
                                if cell.inner_text(timeout=300).strip() == target_day:
                                    cell.click(timeout=3000)
                                    date_selected = True
                                    log(f"date cell clicked (selector: {sel})")
                                    break
                            except Exception:
                                pass
                        if date_selected:
                            break
                except Exception:
                    pass
            if not date_selected:
                page.wait_for_timeout(300)

        if not date_selected:
            log("WARNING: calendar cell not found, falling back to fill")
            form_frame.locator("#REQ_DATE").fill(cfg["target_date"], timeout=10000)
            form_frame.locator("#REQ_DATE").evaluate(
                '''el => {
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                    el.dispatchEvent(new Event('blur', { bubbles: true }));
                }'''
            )

        page.wait_for_timeout(300)
        selected_req_date = form_frame.locator("#REQ_DATE").input_value(timeout=3000)
        if selected_req_date != cfg["target_date"]:
            result["date_mismatch"] = {
                "expected": cfg["target_date"],
                "actual": selected_req_date,
            }
            capture_screenshot(page, result, "park_reserve_date_mismatch")
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return

        form_frame.locator("#selFuelTypeCd").select_option(value=cfg["fuel_value"], timeout=30000)
        form_frame.locator("#REASON").fill(cfg["reason"], timeout=30000)

        result["filled_values"] = form_frame.evaluate(
            '''() => ({
                car_no: document.querySelector('#EMP_CAR_NO')?.value,
                req_date: document.querySelector('#REQ_DATE')?.value,
                fuel_value: document.querySelector('#selFuelTypeCd')?.value,
                fuel_text: document.querySelector('#selFuelTypeCd option:checked')?.textContent?.trim(),
                reason: document.querySelector('#REASON')?.value
            })'''
        )
        result["date_selected_via_calendar"] = date_selected

        if cfg["dry_run"]:
            result["steps"].append("dry_run_skip_submit")
            log("dry-run: skipping self approval")
            capture_screenshot(page, result, "park_reserve_dry_run")
        else:
            log("clicking self approval")
            result["submitted"] = True
            try:
                form_frame.locator("#Req").click(force=True, timeout=30000)
                page.wait_for_timeout(1000)
                capture_screenshot(page, result, "park_reserve_result")
                result["confirm_clicked"] = click_visible_text(page, "확인", timeout_ms=10000)
                page.wait_for_timeout(8000)
            except PlaywrightTimeoutError as exc:
                result["submit_timeout"] = str(exc)
            result["after_submit_url"] = page.url
            result["after_submit_frame_url"] = form_frame.url
            result["form_text_after"] = safe_body_text(form_frame)
            # Extract the site's actual result message (the text appended after the
            # last "목록" nav button — the only place the server response appears).
            _form_after = result["form_text_after"]
            if "목록" in _form_after:
                _tail = _form_after.rsplit("목록", 1)[-1]
                _tail = _tail.replace("확인", "").replace("취소", "").strip()
            else:
                _tail = ""
            result["site_message"] = _tail

            # Match only against the server-injected tail, NOT the static page instructions.
            # "불가합니다" / "신청 가능한 날짜" both appear in the static help text and
            # must not be used as failure signals.
            failure_signals = (
                "신청에 실패했습니다",
                "최대 주차 가능 대수를 초과",
                "오류가 발생",
            )
            success_signals = (
                "승인완료",
                "신청되었습니다",
                "저장되었습니다",
                "정상적으로 처리",
                "자가승인 되었습니다",
            )
            has_failure = any(signal in _tail for signal in failure_signals) or any(
                any(signal in msg for signal in failure_signals) for msg in result["dialogs"]
            )
            has_success = any(signal in _tail for signal in success_signals) or any(
                any(signal in msg for signal in success_signals) for msg in result["dialogs"]
            )
            result["business_success"] = has_success and not has_failure
            result["business_failure"] = has_failure

        print(json.dumps(result, ensure_ascii=False, indent=2))
        context.close()
        browser.close()


if __name__ == "__main__":
    main()
"""


@dataclass(frozen=True)
class Config:
    ssh_target: str
    target_url: str
    employee_id: str
    password: str
    car_no: str
    target_date: str
    fuel_value: str
    reason: str
    dry_run: bool
    discord_channel: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply for LG CNS short-term employee parking through the Mac Edge browser."
    )
    parser.add_argument("--ssh-target", default=os.environ.get("PARK_RESERVE_SSH_TARGET"))
    parser.add_argument("--target-url", default=os.environ.get("PARK_TARGET_URL"))
    parser.add_argument("--employee-id", default=os.environ.get("CNS_ID"))
    parser.add_argument("--car-no", default=os.environ.get("PARK_CAR_NO"))
    parser.add_argument("--reason", default=os.environ.get("PARK_REASON"))
    parser.add_argument("--fuel-value", default=os.environ.get("PARK_FUEL_VALUE"))
    parser.add_argument("--timezone", default=os.environ.get("PARK_TIMEZONE", DEFAULT_TIMEZONE))
    parser.add_argument("--date", help="Override request date. Expected format: YYYY.MM.DD")
    _days_env = os.environ.get("PARK_DAYS_AHEAD")
    parser.add_argument("--days-ahead", type=int, default=int(_days_env) if _days_env else None)
    parser.add_argument("--dry-run", action="store_true", help="Fill the form but do not click 자가승인.")
    parser.add_argument(
        "--discord-channel",
        default=os.environ.get("PARK_DISCORD_CHANNEL"),
        help="Discord channel ID for the final report.",
    )
    parser.add_argument("--no-discord", action="store_true", help="Do not send a Discord report.")
    return parser.parse_args()


def compute_target_date(timezone: str, days_ahead: int) -> str:
    today = datetime.now(ZoneInfo(timezone)).date()
    return (today + timedelta(days=days_ahead)).strftime("%Y.%m.%d")


def require_password() -> str:
    password = os.environ.get("CNS_PW", "")
    if not password:
        raise SystemExit("CNS_PW environment variable is required")
    return password


def load_discord_token() -> str:
    token = os.environ.get("DISCORD_TOKEN", "")
    if token:
        return token

    zshrc = "/home/opc/.zshrc"
    try:
        with open(zshrc, "r", encoding="utf-8") as file:
            for line in file:
                match = re.match(r"^export\s+DISCORD_TOKEN=(.*)\s*$", line)
                if not match:
                    continue
                value = match.group(1).strip()
                if (value.startswith('"') and value.endswith('"')) or (
                    value.startswith("'") and value.endswith("'")
                ):
                    value = value[1:-1]
                return value
    except OSError:
        return ""
    return ""


def extract_screenshot(result: dict) -> tuple[str | None, bytes | None]:
    encoded = result.pop("screenshot_base64", "")
    if not encoded:
        return None, None
    filename = result.get("screenshot_name") or "park_reserve_result.png"
    return filename, base64.b64decode(encoded)


def trim_text(value: str, limit: int = 240) -> str:
    text = "\n".join(line.strip() for line in value.splitlines())
    text = re.sub(r"\n{3,}", "\n\n", text).strip()
    if len(text) <= limit:
        return text
    return text[: limit - 18] + " ... (truncated)"


_KO_WEEKDAY = ["월", "화", "수", "목", "금", "토", "일"]


def _format_target_date(target_date: str) -> str:
    """'2026.06.22' → '2026년 06월 22일 (월)'"""
    try:
        dt = datetime.strptime(target_date, "%Y.%m.%d")
        wd = _KO_WEEKDAY[dt.weekday()]
        return f"{target_date} ({wd})"
    except Exception:
        return target_date


def build_discord_message(result: dict, exit_code: int, started_at: datetime, ended_at: datetime) -> str:
    if result.get("dry_run"):
        status = "DRY-RUN"
    elif result.get("business_success"):
        status = "신청 성공"
    elif result.get("business_failure"):
        status = "신청 실패"
    elif result.get("submitted"):
        status = "결과 불명"
    else:
        status = "자동화 실패"

    fmt = "%H:%M:%S"
    lines = [
        f"[주차 신청] {status}",
        f"시작: {started_at.strftime(fmt)} KST",
        f"종료: {ended_at.strftime(fmt)} KST",
        f"대상일: {_format_target_date(result.get('target_date', '-'))}",
    ]
    site_msg = result.get("site_message", "").strip()
    if not result.get("business_success") and site_msg:
        lines.append(f"사유: {site_msg}")
    return "\n".join(lines)


def build_error_discord_message(stderr: str, stdout: str, exit_code: int, started_at: datetime, ended_at: datetime) -> str:
    fmt = "%H:%M:%S"
    detail = trim_text(stderr or stdout or "no output", limit=300)
    return "\n".join([
        "[주차 신청] 자동화 실패",
        f"시작: {started_at.strftime(fmt)} KST",
        f"종료: {ended_at.strftime(fmt)} KST",
        f"오류: {detail}",
    ])


def send_discord_report(channel: str, message: str, filename: str | None = None, file_bytes: bytes | None = None) -> None:
    token = load_discord_token()
    if not token or not channel:
        print("[Discord] DISCORD_TOKEN 또는 채널 ID가 없어 전송을 건너뜀", file=sys.stderr)
        return

    if len(message) > 1900:
        message = message[:1850] + "\n... (truncated)"

    url = f"https://discord.com/api/v10/channels/{channel}/messages"
    payload = json.dumps({"content": message}, ensure_ascii=False)

    with tempfile.TemporaryDirectory() as tmpdir:
        payload_path = os.path.join(tmpdir, "payload.json")
        with open(payload_path, "w", encoding="utf-8") as file:
            file.write(payload)

        command = [
            "curl",
            "-fsS",
            "-X",
            "POST",
            url,
            "-H",
            f"Authorization: Bot {token}",
        ]

        if filename and file_bytes:
            screenshot_path = os.path.join(tmpdir, filename)
            with open(screenshot_path, "wb") as file:
                file.write(file_bytes)
            command.extend(
                [
                    "-F",
                    f"payload_json={payload}",
                    "-F",
                    f"files[0]=@{screenshot_path};type=image/png",
                ]
            )
        else:
            command.extend(["-H", "Content-Type: application/json", "-d", f"@{payload_path}"])

        completed = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if completed.returncode == 0:
            print("[Discord] 리포트 전송 완료", file=sys.stderr)
        else:
            detail = (completed.stderr or completed.stdout).strip()
            print(f"[Discord] 리포트 전송 실패: {detail}", file=sys.stderr)


def ensure_remote_playwright(ssh_target: str) -> None:
    check_cmd = [
        "ssh",
        ssh_target,
        "python3 - <<'PY'\nimport playwright\nPY",
    ]
    completed = subprocess.run(check_cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode == 0:
        return

    print("remote playwright is missing; installing with pip --user", file=sys.stderr)
    install_cmd = ["ssh", ssh_target, "python3 -m pip install --user playwright"]
    subprocess.run(install_cmd, check=True)


def run_remote(config: Config) -> subprocess.CompletedProcess[str]:
    payload = asdict(config)
    payload.pop("ssh_target")

    remote_code = "PAYLOAD_JSON = " + repr(json.dumps(payload, ensure_ascii=False)) + "\n" + REMOTE_SCRIPT
    remote_command = "python3 -"
    ssh = subprocess.run(
        ["ssh", config.ssh_target, remote_command],
        input=remote_code,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return ssh


def host_log(message: str) -> None:
    ts = datetime.now(ZoneInfo(DEFAULT_TIMEZONE)).strftime("%H:%M:%S")
    print(f"[{ts}] {message}", file=sys.stderr, flush=True)


def main() -> int:
    _load_env_file()
    args = parse_args()
    target_date = args.date or compute_target_date(args.timezone, args.days_ahead)
    config = Config(
        ssh_target=args.ssh_target,
        target_url=args.target_url,
        employee_id=args.employee_id,
        password=require_password(),
        car_no=args.car_no,
        target_date=target_date,
        fuel_value=args.fuel_value,
        reason=args.reason,
        dry_run=args.dry_run,
        discord_channel=args.discord_channel,
    )

    tz = ZoneInfo(DEFAULT_TIMEZONE)
    started_at = datetime.now(tz)
    host_log(f"start  target={target_date} dry_run={config.dry_run}")
    ensure_remote_playwright(config.ssh_target)
    host_log("ssh ok, launching remote playwright")
    completed = run_remote(config)
    ended_at = datetime.now(tz)
    host_log(f"remote done  rc={completed.returncode}")

    try:
        result = json.loads(completed.stdout)
    except json.JSONDecodeError:
        if completed.stderr:
            print(completed.stderr, file=sys.stderr, end="")
        if completed.stdout:
            print(completed.stdout, end="")
        if not args.no_discord:
            send_discord_report(
                config.discord_channel,
                build_error_discord_message(completed.stderr, completed.stdout, completed.returncode or 1, started_at, ended_at),
            )
        return completed.returncode or 1

    screenshot_name, screenshot_bytes = extract_screenshot(result)

    if completed.stderr:
        print(completed.stderr, file=sys.stderr, end="")
    print(json.dumps(result, ensure_ascii=False, indent=2))

    if not args.no_discord:
        send_discord_report(
            config.discord_channel,
            build_discord_message(result, completed.returncode, started_at, ended_at),
            screenshot_name,
            screenshot_bytes,
        )

    if completed.returncode != 0:
        return completed.returncode

    if result.get("dry_run"):
        return 0
    if result.get("business_success"):
        return 0

    # If the site explicitly returned a failure signal, propagate that as an error.
    if result.get("business_failure"):
        return 1

    # Manual test runs outside the allowed application time can reach this path.
    # Treat it as an automation success if the click was attempted and the site
    # returned any business-level response instead of an automation error.
    if result.get("submitted") and (result.get("dialogs") or result.get("form_text_after")):
        print("submitted, but the site did not report approval completion", file=sys.stderr)
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
