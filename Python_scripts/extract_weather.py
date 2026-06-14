import os, time, requests, pandas as pd, pyodbc


SQL_SERVER   = os.environ.get("POWERDWH_SERVER", "localhost")
SQL_DATABASE = os.environ.get("POWERDWH_DATABASE", "PowerDWH")
SQL_CONN = (f"Driver={{ODBC Driver 17 for SQL Server}};"
            f"Server={SQL_SERVER};Database={SQL_DATABASE};Trusted_Connection=yes;")
RAPIDAPI_KEY = os.environ.get("RAPIDAPI_KEY")
if not RAPIDAPI_KEY:
    raise SystemExit("Brak zmiennej srodowiskowej RAPIDAPI_KEY - ustaw ja przed uruchomieniem.")
MET_URL     = "https://meteostat.p.rapidapi.com/point/hourly"
MET_HEADERS = {"x-rapidapi-host": "meteostat.p.rapidapi.com",
               "x-rapidapi-key": RAPIDAPI_KEY}
TZ = "Europe/Warsaw"
DATE_FROM = None
DATE_TO   = None
LOOKBACK_DAYS = 7

def fetch_weather(lat, lon, start, end):
    params = {"lat": lat, "lon": lon, "start": start, "end": end, "tz": TZ}
    r = requests.get(MET_URL, headers=MET_HEADERS, params=params, timeout=60)
    if not r.ok:
        raise RuntimeError(f"Meteostat {r.status_code}: {r.text[:300]}")
    return r.json().get("data", [])

def main():
    today = pd.Timestamp.today().normalize()
    date_to   = pd.Timestamp(DATE_TO)   if DATE_TO   else today - pd.Timedelta(days=1)
    date_from = pd.Timestamp(DATE_FROM) if DATE_FROM else date_to - pd.Timedelta(days=LOOKBACK_DAYS - 1)
    windows, ws = [], date_from
    while ws <= date_to:
        we = min(ws + pd.Timedelta(days=29), date_to)
        windows.append((ws.strftime("%Y-%m-%d"), we.strftime("%Y-%m-%d")))
        ws = we + pd.Timedelta(days=1)

    cn = pyodbc.connect(SQL_CONN)
    plants = pd.read_sql(
        "SELECT PowerPlantId, latitude, longitude FROM DimPowerPlant "
        "WHERE isValid = 1 AND latitude <> 0 AND longitude <> 0", cn)

    rows = []
    for _, p in plants.iterrows():
        data = []
        for (ws_, we_) in windows:
            data.extend(fetch_weather(float(p.latitude), float(p.longitude), ws_, we_))
            time.sleep(0.3)
        for d in data:
            rows.append((int(p.PowerPlantId), d["time"],
                d.get("temp"), d.get("dwpt"), d.get("rhum"), d.get("prcp"),
                d.get("wdir"), d.get("wspd"),
                d.get("pres"), d.get("coco")))
        print(f"  PP {int(p.PowerPlantId)}: {len(data)} godzin")
        time.sleep(0.5)

    cur = cn.cursor()
    cur.execute("TRUNCATE TABLE stg.Weather;")
    cur.fast_executemany = True
    cur.executemany(
        "INSERT INTO stg.Weather (PowerPlantId,[time],temp,dew_point,relative_humidity_pct,"
        "precipitation,wind_direction,wind_speed,pressure,"
        "weather_code) VALUES (?,?,?,?,?,?,?,?,?,?)", rows)
    cn.commit(); cn.close()

if __name__ == "__main__":
    main()
