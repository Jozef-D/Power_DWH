import os, requests, pandas as pd, pyodbc
from urllib.parse import quote

# ----------------- KONFIG -----------------
SQL_SERVER   = os.environ.get("POWERDWH_SERVER", "localhost")
SQL_DATABASE = os.environ.get("POWERDWH_DATABASE", "PowerDWH")
SQL_CONN = (
    f"Driver={{ODBC Driver 17 for SQL Server}};"
    f"Server={SQL_SERVER};Database={SQL_DATABASE};Trusted_Connection=yes;"
)
PSE_BASE = "https://api.raporty.pse.pl/api"
META_CSV = "powerplant_meta.csv"
PSE_BUSINESS_DATE = None
# ------------------------------------------

def fetch_pse_plants(business_date=None):
    if business_date is None:
        business_date = (pd.Timestamp.today() - pd.Timedelta(days=45)).strftime("%Y-%m-%d")
    filt = quote(f"business_date eq '{business_date}'", safe="")
    url = f"{PSE_BASE}/gen-jw?$filter={filt}&$first=5000"
    plants = set()
    while url:
        r = requests.get(url, timeout=120)
        if not r.ok:
            raise RuntimeError(f"PSE {r.status_code} dla {r.url}\n{r.text[:300]}")
        data = r.json()
        for row in data.get("value", []):
            if row.get("power_plant"):
                plants.add(row["power_plant"].strip())
        url = data.get("nextLink")
    return sorted(plants)

def load_meta(path=META_CSV):
    df = pd.read_csv(path)
    meta = {}
    for _, r in df.iterrows():
        lat  = None if pd.isna(r["latitude"])  else float(r["latitude"])
        lon  = None if pd.isna(r["longitude"]) else float(r["longitude"])
        voiv = "unknown" if pd.isna(r["voivodeship"]) else str(r["voivodeship"]).strip()
        meta[str(r["PowerPlantName"]).strip()] = (
            str(r["category"]).strip(), int(r["installed_power"]), lat, lon, voiv)
    return meta

def main():
    plants = fetch_pse_plants(PSE_BUSINESS_DATE)
    meta = load_meta()

    rows, braki = [], []
    for name in plants:
        if name in meta:
            cat, pw, lat, lon, voiv = meta[name]
        else:
            cat, pw, lat, lon, voiv = "unknown", 0, None, None, "unknown"
            braki.append(name)
        rows.append((name, cat, pw, lat, lon, voiv))
    if braki:
        print(f"Brak w {META_CSV} ({len(braki)}): {', '.join(braki)}")

    cn = pyodbc.connect(SQL_CONN); cur = cn.cursor()
    cur.execute("TRUNCATE TABLE stg.PowerPlant;")
    cur.fast_executemany = True
    cur.executemany(
        "INSERT INTO stg.PowerPlant "
        "(PowerPlantName, category, installed_power, latitude, longitude, voivodeship) "
        "VALUES (?,?,?,?,?,?)", rows)
    cn.commit(); cn.close()

if __name__ == "__main__":
    main()
