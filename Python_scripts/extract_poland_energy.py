import os, requests, pandas as pd, pyodbc
from urllib.parse import quote

SQL_SERVER   = os.environ.get("POWERDWH_SERVER", "localhost")
SQL_DATABASE = os.environ.get("POWERDWH_DATABASE", "PowerDWH")
SQL_CONN = (f"Driver={{ODBC Driver 17 for SQL Server}};"
            f"Server={SQL_SERVER};Database={SQL_DATABASE};Trusted_Connection=yes;")
PSE_BASE = "https://api.raporty.pse.pl/api"
DATE_FROM = None
DATE_TO   = None
LOOKBACK_DAYS = 7


F_PRICES = {
    "cen_cost":      "cen_cost",
    "cor_cost":      "cor_cost",
    "ceb_sr_cost":   "ceb_sr_cost",
    "sk_cost_power": "sk_cost_power",
    "cdsac_cost":    "csdac_pln",
    "balance_power": "balance_power",
}
F_RCE  = {"rce_cost": "rce_pln"}
F_LOAD = {"load_fcst": "load_fcst", "load_actual": "load_actual"}
SUM_FIELDS = {"balance_power"}

def fetch_day(endpoint, business_date):
    filt = quote(f"business_date eq '{business_date}'", safe="")
    url = f"{PSE_BASE}/{endpoint}?$filter={filt}&$first=5000"
    out = []
    while url:
        r = requests.get(url, timeout=120)
        if not r.ok:
            raise RuntimeError(f"PSE {endpoint} {r.status_code}: {r.text[:200]}")
        data = r.json(); out.extend(data.get("value", [])); url = data.get("nextLink")
    return out

def parse_pse_dtime(raw):
    s = raw.astype(str).str.strip()
    is_extra = s.str.lower().str.endswith("a").astype(int)
    cleaned = s.where(is_extra == 0, s.str[:-1].str.strip())
    return pd.to_datetime(cleaned), is_extra

def to_15min(endpoint, days, field_map):
    rows = []
    for d in days:
        rows.extend(fetch_day(endpoint, d))
    df = pd.DataFrame(rows)
    df["dtime"], df["isExtraHour"] = parse_pse_dtime(df["dtime"])
    df["slot_start"] = df["dtime"] - pd.Timedelta(minutes=15)
    cols = {"slot_start": df["slot_start"], "isExtraHour": df["isExtraHour"]}
    for tgt, src in field_map.items():
        cols[tgt] = pd.to_numeric(df[src], errors="coerce")
    out = pd.DataFrame(cols)

    return out.groupby(["slot_start", "isExtraHour"], as_index=False).mean()

def main():
    today = pd.Timestamp.today().normalize()
    date_to   = pd.Timestamp(DATE_TO)   if DATE_TO   else today - pd.Timedelta(days=1)
    date_from = pd.Timestamp(DATE_FROM) if DATE_FROM else date_to - pd.Timedelta(days=LOOKBACK_DAYS-1)
    days = pd.date_range(date_from, date_to, freq="D").strftime("%Y-%m-%d")
    print(f"Zakres: {days[0]} .. {days[-1]}")

    prices = to_15min("energy-prices", days, F_PRICES)
    rce    = to_15min("rce-pln",       days, F_RCE)
    load   = to_15min("kse-load",      days, F_LOAD)
    keys = ["slot_start", "isExtraHour"]
    merged = prices.merge(rce, on=keys).merge(load, on=keys)

    nn = lambda x: None if pd.isna(x) else float(x)
    rows = [(r.slot_start.strftime("%Y-%m-%d %H:%M:%S"), int(r.isExtraHour),
             nn(r.cen_cost), nn(r.cor_cost), nn(r.ceb_sr_cost), nn(r.sk_cost_power),
             nn(r.cdsac_cost), nn(r.balance_power), nn(r.rce_cost),
             nn(r.load_fcst), nn(r.load_actual)) for r in merged.itertuples()]

    cn = pyodbc.connect(SQL_CONN); cur = cn.cursor()
    cur.execute("TRUNCATE TABLE stg.PolandEnergy;")
    cur.fast_executemany = True
    cur.executemany(
        "INSERT INTO stg.PolandEnergy ([time],isExtraHour,cen_cost,cor_cost,ceb_sr_cost,sk_cost_power,"
        "cdsac_cost,balance_power,rce_cost,load_fcst,load_actual) VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)
    cn.commit(); cn.close()
    print(f"Zapisano {len(rows)} wierszy do stg.PolandEnergy")

if __name__ == "__main__":
    main()
