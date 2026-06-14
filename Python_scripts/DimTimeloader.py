import csv
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from collections import Counter

WARSAW = ZoneInfo("Europe/Warsaw")

START = datetime(2024, 1, 1, 0, 0, tzinfo=WARSAW)
END   = datetime(2027, 1, 1, 0, 0, tzinfo=WARSAW)

OUTPUT = "DimTime.csv"

step = timedelta(minutes=15)
local_times = []
t = START.astimezone(timezone.utc)
end_utc = END.astimezone(timezone.utc)
while t < end_utc:
    local_times.append(t.astimezone(WARSAW))
    t += step


seen = set()
extra_flag = []
for loc in local_times:
    key = (loc.year, loc.month, loc.day, loc.hour, loc.minute)
    extra_flag.append(key in seen)
    seen.add(key)

per_day = Counter((l.year, l.month, l.day) for l in local_times)
extra_days   = {d for d, c in per_day.items() if c == 100}
missing_days = {d for d, c in per_day.items() if c == 92}

with open(OUTPUT, "w", newline="", encoding="utf-8") as f:
    w = csv.writer(f)
    w.writerow([
        "TimeId", "timestamp", "year", "quarter_year", "month", "week",
        "day", "hour", "quarter_hour", "dayOfWeek", "isWeekend",
        "isExtraHourDay", "isExtraHour", "isMissingHourDay", "isMissingHour",
    ])
    for loc, is_extra in zip(local_times, extra_flag):
        date_key = (loc.year, loc.month, loc.day)
        x = 1 if is_extra else 0
        time_id = int(
            f"{loc.year:04d}{loc.month:02d}{loc.day:02d}"
            f"{loc.hour:02d}{loc.minute:02d}{x}"
        )
        iso_year, iso_week, iso_dow = loc.isocalendar()
        w.writerow([
            time_id,
            loc.strftime("%Y-%m-%d %H:%M:%S"),
            loc.year,
            (loc.month - 1) // 3 + 1,
            loc.month,
            iso_week,
            loc.day,
            loc.hour,
            loc.minute,
            iso_dow,
            1 if iso_dow in (6, 7) else 0,
            1 if date_key in extra_days else 0,
            x,
            1 if date_key in missing_days else 0,
            0,
        ])

