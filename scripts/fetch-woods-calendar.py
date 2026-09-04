#!/usr/bin/env python3
"""Fetch the Woods Campground's public Google Calendar and write a small
JSON file of upcoming weekend themes for the portal to fetch client-side.

Runs on a schedule via .github/workflows/woods-calendar.yml, then the
result is pushed straight to the portal's S3 bucket (not committed to
git -- it's refreshed derived data, not source, same category as a build
artifact). The portal page fetches it same-origin (no CORS needed) at
https://billandjessie.com/woods-events.json.

The calendar ID below is not a secret -- it's the public identifier of a
calendar Bill explicitly shared as public (confirmed live: its ICS feed
serves real data with no auth). Google's ICS feed has no CORS headers
though, which is exactly why this can't just be fetched client-side
directly from the portal -- see docs/roadmap.md Milestone 17.
"""
import datetime
import json
import sys
import urllib.parse
import urllib.request

import icalendar

CALENDAR_ID = "5c33dbce79bde4078c4cbdf934cdf70f789d083b58cb21654bf3cc849aba9987@group.calendar.google.com"
MAX_EVENTS = 8


def main() -> None:
    url = f"https://calendar.google.com/calendar/ical/{urllib.parse.quote(CALENDAR_ID)}/public/basic.ics"
    req = urllib.request.Request(url, headers={"User-Agent": "billandjessie.com portal (bcalaway@gmail.com)"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        raw = resp.read()

    cal = icalendar.Calendar.from_ical(raw)
    today = datetime.date.today()

    events = []
    for component in cal.walk("VEVENT"):
        dtstart = component.get("dtstart").dt
        dtend = component.get("dtend").dt if component.get("dtend") else dtstart
        summary = str(component.get("summary", "")).strip()
        if not isinstance(dtstart, datetime.date) or isinstance(dtstart, datetime.datetime):
            # All-day events only (VALUE=DATE) -- this calendar is exclusively
            # multi-day weekend blocks, skip anything with a real time
            # component rather than guess how to display it.
            continue
        # ICS all-day DTEND is exclusive per RFC 5545 -- the image's own
        # "24th - 27th" style ranges are inclusive, so subtract a day to match.
        last_day = dtend - datetime.timedelta(days=1)
        if last_day < today:
            continue  # fully in the past
        events.append({
            "start": dtstart.isoformat(),
            "end": last_day.isoformat(),
            "summary": summary,
        })

    events.sort(key=lambda e: e["start"])
    events = events[:MAX_EVENTS]

    out = {
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "events": events,
    }
    json.dump(out, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
