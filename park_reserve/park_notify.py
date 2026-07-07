#!/usr/bin/env python3
"""Announce the actual parking day on Discord.

Runs daily at 07:30 KST as the park-notify CronJob. Reads the parking dates
that park_reserve.py recorded in the park-reserve-dates ConfigMap; if today
is one of them, sends the notice to Discord and removes the entry. Stale
past dates are cleaned up silently.
"""

from __future__ import annotations

import os
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

import park_dates
from park_reserve import send_discord_report

DEFAULT_MESSAGE = "오늘은 자차 출근일 입니다"


def log(message: str) -> None:
    print(f"[notify] {message}", file=sys.stderr, flush=True)


def main() -> int:
    tz = ZoneInfo(os.environ.get("PARK_TIMEZONE", "Asia/Seoul"))
    today = datetime.now(tz).strftime("%Y.%m.%d")
    channel = os.environ.get("PARK_NOTIFY_DISCORD_CHANNEL") or os.environ.get(
        "PARK_DISCORD_CHANNEL", ""
    )
    message = os.environ.get("PARK_NOTIFY_MESSAGE", DEFAULT_MESSAGE)

    dates = park_dates.get_dates()
    log(f"today={today} recorded={sorted(dates)}")

    # Zero-padded YYYY.MM.DD sorts lexicographically, so < works as date compare.
    stale = [d for d in dates if d < today]
    if stale:
        park_dates.remove_dates(stale)
        log(f"removed stale dates: {stale}")

    if today not in dates:
        log("no parking today; nothing to send")
        return 0

    if not send_discord_report(channel, message):
        log("Discord send failed; keeping the date for retry")
        return 1

    park_dates.remove_dates([today])
    log("notice sent and date cleaned up")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
