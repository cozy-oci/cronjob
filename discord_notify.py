#!/usr/bin/env python3
"""Send a message to a Discord channel using DISCORD_TOKEN."""

import argparse
import json
import os
import sys
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--channel", default=os.environ.get("CHANNEL_UPDATE", ""))
    parser.add_argument("message")
    args = parser.parse_args()

    token = os.environ.get("DISCORD_TOKEN", "").strip()
    if not token.isascii() or not token.isprintable():
        parser.error("set a valid DISCORD_TOKEN")
    if not args.channel.isascii() or not args.channel.isdecimal():
        parser.error("set a numeric CHANNEL_UPDATE or --channel")
    if not args.message.strip():
        parser.error("message must not be empty")

    url = f"https://discord.com/api/v10/channels/{args.channel}/messages"
    try:
        for start in range(0, len(args.message), 1900):
            payload = {
                "content": args.message[start:start + 1900],
                "allowed_mentions": {"parse": []},
            }
            request = Request(
                url,
                json.dumps(payload).encode("utf-8"),
                {
                    "Content-Type": "application/json",
                    "User-Agent": "DiscordBot (https://github.com/cozy-oci/cronjob, 1.0)",
                },
            )
            request.add_unredirected_header("Authorization", f"Bot {token}")
            with urlopen(request, timeout=10):
                pass
    except HTTPError as error:
        print(f"[Discord] HTTP {error.code}", file=sys.stderr)
        return 1
    except OSError:
        print("[Discord] Could not reach the Discord API", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
