import os, requests, pandas as pd, pyodbc
from urllib.parse import quote

SQL_SERVER   = os.environ.get("POWERDWH_SERVER", "localhost")
SQL_DATABASE = os.environ.get("POWERDWH_DATABASE", "PowerDWH")
SQL_CONN = (f"Driver={{ODBC Driver 17 for SQL Server}};"
            f"Server={SQL_SERVER};Database={SQL_DATABASE};Trusted_Connection=yes;")
PSE_BASE  = "https://api.raporty.pse.pl/api"
DATE_FROM = None
DATE_TO   = None
LOOKBACK_DAYS = 7

def parse_pse_dtime(raw):
    s = str(raw).strip()
    if s[-1:].lower() == "a":
        return s[:-1].strip(), 1
    return s, 0

def fetch_gen_jw_day(business_date):
    filt = quote(f"business_date eq '{business_date}'", safe="")
    url = f"{PSE_BASE}/gen-jw?$filter={filt}&$first=5000"
    out = []
    while url:
        r = requests.get(url, timeout=120)
        if not r.ok:
            raise RuntimeError(f"PSE {r.status_code} dla {r.url}\n{r.text[:300]}")
        data = r.json()
        for row in data.get("value", []):
            pp, dt, val = row.get("power_plant"), row.get("dtime"), row.get("value")
            if pp and dt and val is not None:
                dt_clean, is_extra = parse_pse_dtime(dt)
                out.append((pp.strip(), dt_clean, float(val), is_extra))
        url = data.get("nextLink")
    return out

def main():
    today = pd.Timestamp.today().normalize()
    date_to   = pd.Timestamp(DATE_TO)   if DATE_TO   else today - pd.Timedelta(days=1)              # wczoraj
    date_from = pd.Timestamp(DATE_FROM) if DATE_FROM else date_to - pd.Timedelta(days=LOOKBACK_DAYS - 1)
    days = pd.date_range(date_from, date_to, freq="D").strftime("%Y-%m-%d")
    print(f"Zakres: {days[0]} .. {days[-1]} ({len(days)} dni)")

    rows = []
    for d in days:
        day_rows = fetch_gen_jw_day(d)
        print(f"{d}: {len(day_rows)} wierszy")
        rows.extend(day_rows)
    print(f"Razem: {len(rows)} wierszy")

    cn = pyodbc.connect(SQL_CONN); cur = cn.cursor()
    cur.execute("TRUNCATE TABLE stg.PowerPlantOutput;")
    cur.fast_executemany = True

    cur.executemany(
        "INSERT INTO stg.PowerPlantOutput (power_plant, dtime, [value], isExtraHour) VALUES (?,?,?,?)", rows)
    cn.commit();

    cur.execute("SELECT @@SERVERNAME, DB_NAME(), COUNT(*) FROM stg.PowerPlantOutput")
    cn.close()


if __name__ == "__main__":
    main()
