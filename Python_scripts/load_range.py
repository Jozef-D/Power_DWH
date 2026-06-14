"""
Orkiestrator ladowania PowerDWH z audytem i trybem przyrostowym.

TRYBY:
  python load_range.py                      # 'range'      : 2 miesiace wstecz .. wczoraj
  python load_range.py --incremental        # 'incremental': ostatnie INCREMENTAL_DAYS dni .. wczoraj
  python load_range.py 2026-01-01 2026-03-31  # 'backfill'  : wlasny zakres (historia)
  python load_range.py --no-ssis            # tylko ekstrakty do staging, bez SSIS

DLACZEGO OKNO KROCZACE, A NIE CZYSTY WATERMARK:
  Meteostat publikuje dane stacji z kilkudniowym opoznieniem. Pakiety faktow laduja
  metoda DELETE-okno + INSERT (idempotentnie dla okna ze staging), wiec ponowne
  wciagniecie ostatnich INCREMENTAL_DAYS dni przy kazdym biegu automatycznie uzupelnia
  spoznione dane pogodowe i ewentualne korekty PSE - bez duplikatow. INCREMENTAL_DAYS
  musi byc WIEKSZE niz spodziewane opoznienie zrodla.

ODPORNOSC:
  Pakiet SSIS danego faktu uruchamia sie TYLKO gdy jego ekstrakt sie powiodl. Dzieki
  temu nieudany/spozniony ekstrakt (typowo pogoda) nie nadpisuje faktu pustym staging.
  Bieg konczy sie statusem SUCCESS / PARTIAL (cos opcjonalnego padlo) / FAILED (krytyczne).

Kazdy bieg i krok jest logowany do audit.EtlRun / audit.EtlStep (patrz Audit_setup.sql).
"""

import os
import sys
import time
import socket
import subprocess
import traceback
import pyodbc
import pandas as pd

# ----------------- KONFIG -----------------
MONTHS_BACK     = 2        # tryb 'range'
INCREMENTAL_DAYS = 14      # tryb 'incremental' - MUSI byc > opoznienia Meteostatu
RUN_SSIS        = True

SQL_SERVER   = os.environ.get("POWERDWH_SERVER", "localhost")
SQL_DATABASE = os.environ.get("POWERDWH_DATABASE", "PowerDWH")
SQL_CONN = (f"Driver={{ODBC Driver 17 for SQL Server}};"
            f"Server={SQL_SERVER};Database={SQL_DATABASE};Trusted_Connection=yes;")

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
SSIS_DIR    = os.path.normpath(os.path.join(SCRIPTS_DIR, "..", "Power_DWH"))

DTEXEC_CANDIDATES = [
    r"C:\Program Files\Microsoft SQL Server\160\DTS\Binn\dtexec.exe",
    r"C:\Program Files\Microsoft SQL Server\150\DTS\Binn\dtexec.exe",
    r"C:\Program Files\Microsoft SQL Server\140\DTS\Binn\dtexec.exe",
    r"C:\Program Files\Microsoft SQL Server\130\DTS\Binn\dtexec.exe",
    "dtexec",
]

# ekstrakt -> tabela staging (do liczenia wierszy w audycie)
STG_TABLE = {
    "extract_powerplant":    "stg.PowerPlant",
    "extract_poland_energy": "stg.PolandEnergy",
    "extract_power_output":  "stg.PowerPlantOutput",
    "extract_weather":       "stg.Weather",
}
# pakiet SSIS -> tabela docelowa (do liczenia wierszy w audycie)
PKG_TABLE = {
    "Load_DimPowerPlant.dtsx":       "dbo.DimPowerPlant",
    "Load_FactPolandEnergy.dtsx":    "dbo.FactPolandEnergy",
    "Load_FactPowerPlantOutput.dtsx":"dbo.FactPowerPlantOutput",
    "Load_FactWeather.dtsx":         "dbo.FactWeather",
}
# ------------------------------------------


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def get_conn():
    return pyodbc.connect(SQL_CONN, autocommit=True, timeout=15)


def table_count(cur, table):
    try:
        return int(cur.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0])
    except Exception:
        return None


class Audit:
    """Logowanie biegu i krokow do audit.EtlRun / audit.EtlStep."""
    def __init__(self, mode, date_from, date_to, run_ssis):
        self.cn = get_conn()
        self.cur = self.cn.cursor()
        self.run_id = self.cur.execute(
            "INSERT INTO audit.EtlRun (Mode, DateFrom, DateTo, RunSsis, Host) "
            "OUTPUT INSERTED.RunId VALUES (?,?,?,?,?)",
            mode, date_from, date_to, 1 if run_ssis else 0, socket.gethostname()
        ).fetchone()[0]
        self.t0 = time.time()
        log(f"audit RunId = {self.run_id} ({mode}, {date_from}..{date_to})")

    def step(self, name, step_type, count_table=None):
        return _Step(self, name, step_type, count_table)

    def finish(self, status, error=None):
        self.cur.execute(
            "UPDATE audit.EtlRun SET FinishedAt=SYSDATETIME(), Status=?, "
            "DurationSec=?, ErrorMessage=? WHERE RunId=?",
            status, int(time.time() - self.t0), (error or None), self.run_id)
        self.cn.close()


class _Step:
    def __init__(self, audit, name, step_type, count_table):
        self.a = audit; self.name = name; self.type = step_type
        self.count_table = count_table; self.skipped = False
    def __enter__(self):
        self.t0 = time.time()
        self.step_id = self.a.cur.execute(
            "INSERT INTO audit.EtlStep (RunId, StepName, StepType) "
            "OUTPUT INSERTED.StepId VALUES (?,?,?)",
            self.a.run_id, self.name, self.type).fetchone()[0]
        return self
    def skip(self, detail):
        self.skipped = True
        self.a.cur.execute(
            "UPDATE audit.EtlStep SET FinishedAt=SYSDATETIME(), Status='SKIPPED', "
            "DurationSec=0, Detail=? WHERE StepId=?", detail[:2000], self.step_id)
        log(f"POMINIETO {self.name}: {detail}")
    def __exit__(self, exc_type, exc, tb):
        if self.skipped:
            return False
        rows = table_count(self.a.cur, self.count_table) if self.count_table else None
        if exc is None:
            self.a.cur.execute(
                "UPDATE audit.EtlStep SET FinishedAt=SYSDATETIME(), Status='SUCCESS', "
                "[Rows]=?, DurationSec=?, Detail=? WHERE StepId=?",
                rows, int(time.time() - self.t0),
                (f"{self.count_table}={rows}" if rows is not None else None), self.step_id)
            log(f"OK {self.name}" + (f" ({self.count_table}={rows})" if rows is not None else ""))
        else:
            self.a.cur.execute(
                "UPDATE audit.EtlStep SET FinishedAt=SYSDATETIME(), Status='FAILED', "
                "[Rows]=?, DurationSec=?, Detail=? WHERE StepId=?",
                rows, int(time.time() - self.t0),
                (str(exc)[:2000]), self.step_id)
            log(f"BLAD {self.name}: {exc}")
        return True   # bledy obslugujemy na poziomie orkiestracji (gating), nie propagujemy


def compute_range(argv):
    pos = [a for a in argv if not a.startswith("-")]
    today = pd.Timestamp.today().normalize()
    if len(pos) >= 2:
        df = pd.Timestamp(pos[0]).normalize(); dt = pd.Timestamp(pos[1]).normalize()
        mode = "backfill"
    elif "--incremental" in argv:
        dt = today - pd.Timedelta(days=1)
        df = today - pd.Timedelta(days=INCREMENTAL_DAYS)
        mode = "incremental"
    else:
        dt = today - pd.Timedelta(days=1)
        df = today - pd.DateOffset(months=MONTHS_BACK)
        mode = "range"
    if df > dt:
        raise SystemExit(f"Bledny zakres: {df.date()} > {dt.date()}")
    return df.strftime("%Y-%m-%d"), dt.strftime("%Y-%m-%d"), mode


def find_dtexec():
    for p in DTEXEC_CANDIDATES:
        if p == "dtexec" or os.path.isfile(p):
            return p
    raise SystemExit("Nie znaleziono dtexec.exe - ustaw DTEXEC_CANDIDATES lub --no-ssis.")


def run_package(dtexec, dtsx_name):
    path = os.path.join(SSIS_DIR, dtsx_name)
    if not os.path.isfile(path):
        raise SystemExit(f"Brak pakietu SSIS: {path}")
    log(f"SSIS -> {dtsx_name}")
    rc = subprocess.call([dtexec, "/FILE", path, "/CHECKPOINTING", "OFF", "/REPORTING", "EW"])
    if rc != 0:
        raise RuntimeError(f"dtexec rc={rc} dla {dtsx_name}")


def run_extract(module_name, date_from=None, date_to=None):
    log(f"Python -> {module_name}.main()  ({date_from or '-'} .. {date_to or '-'})")
    mod = __import__(module_name)
    if date_from is not None and hasattr(mod, "DATE_FROM"):
        mod.DATE_FROM = date_from
        mod.DATE_TO = date_to
    mod.main()


def main():
    argv = sys.argv[1:]
    no_ssis = "--no-ssis" in argv
    date_from, date_to, mode = compute_range(argv)

    os.chdir(SCRIPTS_DIR)
    if SCRIPTS_DIR not in sys.path:
        sys.path.insert(0, SCRIPTS_DIR)

    log(f"=== PowerDWH load: {mode} {date_from}..{date_to} | SSIS={'OFF' if no_ssis else RUN_SSIS} ===")
    dtexec = None if (no_ssis or not RUN_SSIS) else find_dtexec()
    audit = Audit(mode, date_from, date_to, not (no_ssis or not RUN_SSIS))
    final = "SUCCESS"

    try:
        # 1. wymiar elektrowni -> staging (krytyczny)
        with audit.step("extract_powerplant", "python", STG_TABLE["extract_powerplant"]) as st:
            run_extract("extract_powerplant")
        if st.skipped is False and _failed(audit, st):
            raise RuntimeError("Krytyczny krok extract_powerplant nie powiodl sie")

        # 2. DimPowerPlant (krytyczny - pogoda i fakty go potrzebuja)
        if dtexec:
            with audit.step("Load_DimPowerPlant", "ssis", PKG_TABLE["Load_DimPowerPlant.dtsx"]) as st:
                run_package(dtexec, "Load_DimPowerPlant.dtsx")
            if _failed(audit, st):
                raise RuntimeError("Krytyczny krok Load_DimPowerPlant nie powiodl sie")
        else:
            with audit.step("Load_DimPowerPlant", "ssis") as st:
                st.skip("SSIS wylaczony")

        # 3. ekstrakty faktow (niezalezne; sledzimy sukces kazdego)
        ok = {}
        for m in ("extract_poland_energy", "extract_power_output", "extract_weather"):
            with audit.step(m, "python", STG_TABLE[m]) as st:
                run_extract(m, date_from, date_to)
            ok[m] = not _failed(audit, st)

        # 4. fakty - pakiet uruchamiany TYLKO gdy jego ekstrakt sie powiodl
        fact_pkg = {
            "extract_poland_energy": "Load_FactPolandEnergy.dtsx",
            "extract_power_output":  "Load_FactPowerPlantOutput.dtsx",
            "extract_weather":       "Load_FactWeather.dtsx",
        }
        for m, pkg in fact_pkg.items():
            step_name = pkg.replace(".dtsx", "")
            if not dtexec:
                with audit.step(step_name, "ssis") as st:
                    st.skip("SSIS wylaczony")
                continue
            if not ok[m]:
                with audit.step(step_name, "ssis") as st:
                    st.skip(f"pominieto - ekstrakt {m} nie powiodl sie (np. opoznienie zrodla)")
                final = "PARTIAL"
                continue
            with audit.step(step_name, "ssis", PKG_TABLE[pkg]) as st:
                run_package(dtexec, pkg)
            if _failed(audit, st):
                final = "PARTIAL"

        audit.finish(final)
        log(f"=== GOTOWE: status={final} ===")
    except Exception as e:
        audit.finish("FAILED", traceback.format_exc())
        log(f"=== PRZERWANO (FAILED): {e} ===")
        raise


def _failed(audit, step):
    """Czy ostatnio domkniety krok ma status FAILED."""
    row = audit.cur.execute(
        "SELECT Status FROM audit.EtlStep WHERE StepId=?", step.step_id).fetchone()
    return row is not None and row[0] == "FAILED"


if __name__ == "__main__":
    main()
