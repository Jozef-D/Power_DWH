# PowerDWH — uruchomienie na nowym komputerze

Hurtownia danych energii (PSE + pogoda Meteostat) z ETL Python → staging → SSIS → Dim/Fact
i raportem Power BI. Poniżej komplet tego, co trzeba zainstalować i poprawić, żeby projekt
ruszył na innej maszynie.

---

## 1. Wymagane oprogramowanie

| Składnik | Wersja / uwagi |
|---|---|
| **SQL Server** | 2017 lub nowszy (pakiety mają `TargetServerVersion = SQLServer2017`), uwierzytelnianie Windows (SSPI) |
| **ODBC Driver 17 for SQL Server** | dla skryptów Python (`Driver={ODBC Driver 17 for SQL Server}`) |
| **SQL Server Native Client 11.0 (`SQLNCLI11`)** | dla połączeń OLEDB w pakietach SSIS — przestarzały, instaluje się osobno (alternatywa: przepiąć na `MSOLEDBSQL`) |
| **Python 3.11** | pakiety SSIS mają zaszytą ścieżkę do `Python311\python.exe` |
| **dtexec** (runtime SSIS) | do uruchamiania pakietów `.dtsx` i skryptu `load_range.py` |
| **Visual Studio 2022 + rozszerzenie SSIS (SSDT)** | tylko jeśli chcesz edytować/budować projekt `.dtproj` (`ProductVersion 17.0`) |
| **Power BI Desktop** | do otwarcia / odświeżenia `business.pbix` |

---

## 2. Baza danych

1. Uruchom [`sql_help/00_Create_PowerDWH_empty.sql`](sql_help/00_Create_PowerDWH_empty.sql)
   — tworzy bazę `PowerDWH`, schematy `etl` / `stg`, wszystkie tabele Dim/Fact/stg
   oraz procedurę `etl.usp_Load_DimPowerPlant`.
2. Zastosuj aktualną wersję procedury z [`sql_help/SCD_2_DimPowerPlant.sql`](sql_help/SCD_2_DimPowerPlant.sql).
3. Upewnij się, że konto Windows uruchamiające ETL ma uprawnienia do bazy `PowerDWH`.

---

## 3. Python

```powershell
pip install -r requirements.txt
```

Biblioteki: `pandas`, `pyodbc`, `requests`, `tzdata`
(`tzdata` jest konieczne — `DimTimeloader.py` używa `zoneinfo`, a Windows nie ma systemowej bazy stref).

---

## 4. Zmienne środowiskowe

```powershell
setx RAPIDAPI_KEY "twoj_klucz_rapidapi"
# opcjonalnie, jeśli SQL NIE jest na localhost / baza ma inną nazwę:
setx POWERDWH_SERVER "NAZWA_SERWERA\INSTANCJA"
setx POWERDWH_DATABASE "PowerDWH"
```

- `RAPIDAPI_KEY` — wymagane; bez niego `extract_weather.py` przerywa start. Klucz z RapidAPI (Meteostat).
- `POWERDWH_SERVER` / `POWERDWH_DATABASE` — opcjonalne; skrypty Python czytają z nich serwer i bazę
  (fallback: `localhost` / `PowerDWH`). Ustaw je **na te same wartości co parametry projektu SSIS**
  (`ServerName` / `DatabaseName` w `Project.params` — patrz sekcja 6), żeby Python i SSIS pisały do tej samej bazy.

> Po `setx` zrestartuj Visual Studio / terminal, żeby procesy złapały nowe zmienne.

---

## 5. Dostęp sieciowy (API)

- `https://api.raporty.pse.pl` — dane PSE (bez klucza)
- `https://meteostat.p.rapidapi.com` — pogoda (przez RapidAPI, wymaga `RAPIDAPI_KEY`)

---

## 6. Konfiguracja maszynowo-zależna (sparametryzowana)

Ścieżki i serwer **nie są już zaszyte w pakietach** — SSIS używa **parametrów projektu**,
a skrypty Python **zmiennych środowiskowych** (sekcja 4). Przenosiny sprowadzają się do trzech miejsc:

**a) Parametry projektu SSIS** — w VS dwuklik na `Project.params`, ustaw kolumnę **Value**:

| Parametr | Co ustawić |
|---|---|
| `ServerName` | nazwa instancji SQL nowej maszyny (np. `localhost`) |
| `DatabaseName` | `PowerDWH` |
| `PythonExe` | pełna ścieżka do `python.exe` (np. `C:\Users\<user>\AppData\Local\Programs\Python\Python311\python.exe`) |
| `ScriptsDir` | pełna ścieżka do katalogu `Python_scripts` |

Pakiety podpinają je wyrażeniami (`ServerName`/`InitialCatalog` na połączeniu OLEDB,
`Executable`/`WorkingDirectory`/`Arguments` na Execute Process Task, `ConnectionString` na flat file
`DimTime.csv`). Po zmianie wartości: **Build → Build Power_DWH**.

**b) Zmienne środowiskowe Pythona** — `POWERDWH_SERVER` / `POWERDWH_DATABASE` (sekcja 4),
ustawione na te same wartości co `ServerName` / `DatabaseName`.

**c) Power BI** — `business.pbix` (model importowany) wskazuje na serwer SQL; przepnij w Power BI Desktop (sekcja 9).

> Uwaga: w `ConnectionString` pakietów wciąż widnieje stara nazwa `DESKTOP-23B29RF`, ale przy starcie
> nadpisuje ją wyrażenie z `@[$Project::ServerName]` — to normalne, nie trzeba tego ruszać.

---

## 7. Pliki pomocnicze (muszą podróżować z repo)

`Python_scripts/powerplant_meta.csv`, `Python_scripts/DimTime.csv`, `Python_scripts/geo_cache.json`,
`poland_voivodeships.geojson`, `poland_voivodeships_pl.geojson`.

---

## 8. Uruchomienie ETL

**Oficjalną ścieżką orkiestracji jest `load_range.py`** (a nie ręczne uruchamianie `Master.dtsx`).
Wykonuje w kolejności: `extract_powerplant` → SSIS `Load_DimPowerPlant`
→ `extract_poland_energy` / `extract_power_output` / `extract_weather` → pakiety `Load_Fact*`.
Każdy bieg i krok jest **logowany do `audit.EtlRun` / `audit.EtlStep`** (status, liczby wierszy, błędy).

```powershell
cd Python_scripts
python load_range.py                         # tryb 'range'      : 2 miesiace wstecz .. wczoraj
python load_range.py --incremental           # tryb 'incremental': ostatnie 14 dni .. wczoraj (dzienny)
python load_range.py 2025-06-01 2026-06-13   # tryb 'backfill'   : wlasny zakres (historia)
python load_range.py --no-ssis               # tylko ekstrakty do staging, bez SSIS
```

**Odporność / opóźnienia Meteostatu:** pakiet faktu uruchamia się tylko, gdy jego ekstrakt się
powiódł (nieudany/spóźniony ekstrakt nie nadpisze faktu pustym staging). Tryb `incremental`
przeładowuje **kroczące 14-dniowe okno** — ponieważ fakty ładują się metodą *DELETE-okno + INSERT*,
spóźnione dane pogodowe (Meteostat publikuje z kilkudniowym lagiem) i korekty PSE są
automatycznie uzupełniane przy kolejnych biegach, bez duplikatów. `INCREMENTAL_DAYS` w
`load_range.py` musi pozostać **większe niż spodziewane opóźnienie źródła**.

> `DimTime` to wymiar statyczny (2024–2027) — nie jest przeładowywany cyklicznie.
> W razie potrzeby: `python DimTimeloader.py` + pakiet `Load_DimTime`.

### 8a. Harmonogram (automatyzacja)
Zadanie Harmonogramu zadań Windows **„PowerDWH ETL"** uruchamia codziennie o 06:00
`Python_scripts/run_etl.ps1` (tryb `--incremental`, log do `Python_scripts/logs/etl_RRRRMMDD.log`).
- Podgląd / edycja: `schtasks /Query /TN "PowerDWH ETL" /V /FO LIST`
- Ręczne odpalenie: `schtasks /Run /TN "PowerDWH ETL"`
- Usunięcie: `schtasks /Delete /TN "PowerDWH ETL" /F`
- Zadanie działa w kontekście użytkownika (gdy zalogowany). Przy przenosinach popraw ścieżki w `run_etl.ps1`.

### 8b. Kontrola jakości i audyt
```powershell
sqlcmd -S localhost -d PowerDWH -i ..\sql_help\PostLoad_checks.sql     # szybki smoke test po biegu
sqlcmd -S localhost -d PowerDWH -i ..\sql_help\DataQuality_checks.sql  # pelny framework PASS/FAIL -> dq.CheckResults
-- przeglad ostatniego biegu ETL:  SELECT * FROM audit.vLastRun;
```

---

## 9. Power BI

Otwórz `business.pbix` w Power BI Desktop, przepnij źródło danych na nowy serwer SQL
(Plik → Opcje i ustawienia → Ustawienia źródła danych) i odśwież.

---

## Szybka checklista

- [ ] SQL Server 2017+ zainstalowany, konto ma uprawnienia
- [ ] Uruchomiony DDL `00_Create_PowerDWH_empty.sql` + procedura `SCD_2_DimPowerPlant.sql`
- [ ] ODBC Driver 17 + SQL Server Native Client 11 (SQLNCLI11)
- [ ] Python 3.11 + `pip install -r requirements.txt`
- [ ] `RAPIDAPI_KEY` ustawiony (+ `POWERDWH_SERVER`/`POWERDWH_DATABASE`, jeśli SQL nie na localhost)
- [ ] `Project.params` ustawione (`ServerName`, `DatabaseName`, `PythonExe`, `ScriptsDir`) + Build
- [ ] Pliki pomocnicze obecne
- [ ] `python load_range.py` przechodzi
- [ ] Power BI przepięty na nowy serwer i odświeżony
