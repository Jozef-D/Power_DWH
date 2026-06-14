# Power_DWH — ściąga na prezentację: ETL, endpointy, harmonogram, model

Dokument przygotowawczy. Opisuje **dokładnie, zgodnie z kodem**, jak działa rozwiązanie:
źródła i endpointy, skrypty ekstrakcji, transformacje, model hurtowni, cykliczne
uruchamianie, obsługa zmiany czasu, kontrola jakości i audyt.

---

## 1. Architektura w pigułce

```
ŹRÓDŁA                  EKSTRAKCJA/TRANSFORMACJA       STAGING            ŁADOWANIE         HURTOWNIA            RAPORT
(API + CSV)             (Python: requests/pandas)      (schemat stg)      (SSIS + SQL)      (SQL Server)         (Power BI)

PSE API  ───┐
Meteostat ──┼──►  extract_*.py  ──►  TRUNCATE+INSERT ──►  stg.*  ──►  Load_*.dtsx  ──►  DimTime, DimPowerPlant   ──►  business.pbix
csv meta ───┘     (pełne okno dat)   (fast_executemany)         lookup+SCD2     FactWeather/Output/PolandEnergy   (7 stron)
```

**Hybryda Python + SSIS:**
- **Python** robi *Extract* + *Transform* → zapisuje do warstwy **staging** (`stg`).
- **SSIS** robi *Load*: lookup kluczy, SCD2 wymiaru elektrowni, obsługa zdublowanej godziny → tabele faktów/wymiarów `dbo`.
- **Orkiestrator** `load_range.py` spina całość, pilnuje kolejności zależności i loguje audyt.

Warstwy: **Źródła → Python (E/T) → staging `stg` → SSIS (L) → hurtownia `dbo` → Power BI.**

---

## 2. Źródła danych i endpointy

### 2.1 PSE API — `https://api.raporty.pse.pl/api`

REST/JSON, filtrowanie składnią **OData**, paginacja przez pole `nextLink`.

Wzorzec zapytania (jeden dzień, `business_date`):
```
GET /{endpoint}?$filter=business_date eq 'YYYY-MM-DD'&$first=5000
```
- `$filter=business_date eq '...'` — pobieramy **dzień po dniu** (pętla po zakresie dat).
- `$first=5000` — rozmiar strony.
- Pętla: `while url: ... url = data.get("nextLink")` — dopóki PSE zwraca kolejny link, dociągamy następną stronę.
- Timeout 120 s, twardy błąd przy `not r.ok`.

| Endpoint        | Co zwraca                                   | Trafia do (staging)     | Docelowa tabela faktów |
|-----------------|---------------------------------------------|-------------------------|------------------------|
| `gen-jw`        | generacja jednostek wytwórczych **oraz** lista elektrowni (`power_plant`, `dtime`, `value`) | `stg.PowerPlantOutput` / `stg.PowerPlant` | `FactPowerPlantOutput`, `DimPowerPlant` |
| `energy-prices` | ceny i bilans (`cen_cost`, `cor_cost`, `ceb_sr_cost`, `sk_cost_power`, `csdac_pln`, `balance_power`) | `stg.PolandEnergy` | `FactPolandEnergy` |
| `rce-pln`       | rynkowa cena energii (`rce_pln`)            | `stg.PolandEnergy`      | `FactPolandEnergy`     |
| `kse-load`      | zapotrzebowanie KSE (`load_fcst`, `load_actual`) | `stg.PolandEnergy` | `FactPolandEnergy`     |

> **Uwaga nazewnicza (warto znać na obronę):** w PSE pole nazywa się `csdac_pln`, a u nas kolumna to `cdsac_cost` — mapowanie jest w `F_PRICES` w `extract_poland_energy.py`. To celowy alias, nie literówka w danych.

### 2.2 Meteostat — `https://meteostat.p.rapidapi.com/point/hourly`

Dostęp przez RapidAPI; klucz w zmiennej środowiskowej **`RAPIDAPI_KEY`** (skrypt twardo przerywa, jeśli jej brak).

Parametry zapytania:
```
GET /point/hourly?lat={lat}&lon={lon}&start=YYYY-MM-DD&end=YYYY-MM-DD&tz=Europe/Warsaw
```
- Dane **godzinowe** dla punktu = współrzędne elektrowni.
- Pobierane w **oknach do 30 dni** (`min(ws + 29 dni, date_to)`), bo API ma limit zakresu na zapytanie.
- `time.sleep(0.3)` między oknami i `0.5` między elektrowniami — łagodny rate-limiting.
- Mapowane pola: `temp, dwpt, rhum, prcp, wdir, wspd, pres, coco` → kolumny `stg.Weather`.

### 2.3 `powerplant_meta.csv` — referencyjny plik metadanych

- **Lista** jednostek pochodzi z PSE (`gen-jw`). **Atrybuty opisowe** (kategoria/paliwo, moc zainstalowana, współrzędne, województwo) pochodzą z **bazy elektrowni serwisu Instrat**: `https://energy.instrat.pl/system-elektroenergetyczny/baza-elektrowni/` (w razie potrzeby uzupełnione geokodowaniem Nominatim, cache w `geo_cache.json`).
- Plik kuratorowany ręcznie, ~36 elektrowni. **W cyklicznym ETL nie ma już zapytań do Instrat/Nominatim** — dane czerpane są z CSV.
- Elektrownia z PSE, której **nie ma** w CSV, ląduje z wartościami `unknown/0/None` i jest wypisywana na konsolę (`Brak w powerplant_meta.csv (...)`).

---

## 3. Skrypty ETL (Python)

Wspólny szkielet każdego ekstraktu:
- połączenie do bazy z env (`POWERDWH_SERVER`/`POWERDWH_DATABASE`, domyślnie `localhost`/`PowerDWH`),
- parametry zakresu `DATE_FROM`, `DATE_TO`, `LOOKBACK_DAYS` (domyślnie wczoraj wstecz o `LOOKBACK_DAYS-1`),
- `TRUNCATE` tabeli staging + wsadowy `INSERT` z `fast_executemany = True` (pełne, idempotentne odświeżenie okna).

### 3.1 `extract_powerplant.py` → `stg.PowerPlant`
1. `fetch_pse_plants()` — z `gen-jw` zbiera **unikalny zbiór** nazw `power_plant` (domyślnie dla `dziś − 45 dni`, by trafić w dzień z pełnymi danymi).
2. `load_meta()` — wczytuje `powerplant_meta.csv` do słownika `nazwa → (kategoria, moc, lat, lon, województwo)`.
3. Join listy PSE z metadanymi; braki → `unknown`. Zapis do `stg.PowerPlant`.

### 3.2 `extract_poland_energy.py` → `stg.PolandEnergy`
- Pobiera **trzy** endpointy (`energy-prices`, `rce-pln`, `kse-load`) dla całego zakresu dni.
- `parse_pse_dtime()` — rozpoznaje marker DST: `dtime` zakończone literą `a` → `isExtraHour=1`, litera obcinana.
- `slot_start = dtime − 15 min` — PSE znakuje **koniec** kwadransa, my przechowujemy **początek slotu**.
- Agregacja do kwadransa: `groupby([slot_start, isExtraHour]).mean()`; **wyjątek:** `balance_power` jest sumą (`SUM_FIELDS`).
- `merge` trzech ramek po kluczu `[slot_start, isExtraHour]` → jeden wiersz na kwadrans → `stg.PolandEnergy`.

### 3.3 `extract_power_output.py` → `stg.PowerPlantOutput`
- Z `gen-jw` bierze trójki `(power_plant, dtime, value)` + flagę `isExtraHour` (ten sam mechanizm `a`).
- Zapisuje surowe wiersze (bez agregacji w Pythonie — agregacja po elektrowni/kwadransie dzieje się przy ładowaniu faktu).

### 3.4 `extract_weather.py` → `stg.Weather`
- **Czyta współrzędne aktywnych elektrowni z hurtowni**: `SELECT ... FROM DimPowerPlant WHERE isValid=1 AND lat<>0 AND lon<>0`.
  → dlatego **musi biec po** `Load_DimPowerPlant` (zależność kolejności!).
- Dla każdej elektrowni pobiera pogodę w oknach ≤30 dni i zapisuje godzinowe wiersze do `stg.Weather`.

### 3.5 `DimTimeloader.py` → plik `DimTime.csv`
- Generuje kalendarz kwadransowy **2024-01-01 .. 2027-01-01** w strefie `Europe/Warsaw`.
- Uruchamiany **jednorazowo**; wynik ładowany przez `Load_DimTime` (Flat File → `dbo.DimTime`).
- Liczy `TimeId`, flagi weekendu i zmiany czasu (patrz §4.1).

---

## 4. Model hurtowni danych

**Konstelacja faktów** (gwiazdy współdzielące wymiary): 2 wymiary + 3 fakty.

```
            DimTime (1) ──< FactWeather >── (1) DimPowerPlant
            DimTime (1) ──< FactPowerPlantOutput >── (1) DimPowerPlant
            DimTime (1) ──< FactPolandEnergy
```

| Tabela                 | Typ        | Ziarno                      | Klucz |
|------------------------|------------|-----------------------------|-------|
| `DimTime`              | wymiar     | jeden kwadrans              | `TimeId BIGINT` |
| `DimPowerPlant`        | wymiar SCD2| jedna wersja elektrowni     | `PowerPlantId INT IDENTITY` |
| `FactWeather`          | fakt       | godzina × elektrownia       | FK `TimeId`, `PowerPlantId` |
| `FactPowerPlantOutput` | fakt       | kwadrans × elektrownia      | FK `TimeId`, `PowerPlantId` |
| `FactPolandEnergy`     | fakt       | kwadrans (cała Polska)      | FK `TimeId` |

Indeksy nieklastrowane na kluczach obcych faktów (`TimeId`, `PowerPlantId`) — przyspieszają joiny w raportach.

### 4.1 `DimTime` i format `TimeId`

`TimeId` to **13-cyfrowy, deterministyczny** klucz w formacie:
```
YYYYMMDD HH mm X
 │       │  │  └ bit zdublowanej godziny (jesienna zmiana czasu): 0 = normalna, 1 = druga kopia
 │       │  └─── minuta kwadransa: 00 / 15 / 30 / 45
 │       └────── godzina 00–23
 └────────────── data
```
Przykład: `2026 03 29 02 15 0`.

Flagi DST liczone w `DimTimeloader.py`:
- dzień ma **100** kwadransów → `isExtraHourDay=1` (jesień, godzina się dubluje),
- dzień ma **92** kwadransy → `isMissingHourDay=1` (wiosna, godzina znika),
- `isExtraHour` ustawiany, gdy `(rok,m-c,dzień,godz,min)` już wystąpił w danym dniu (druga kopia).

### 4.2 `DimPowerPlant` — SCD typu 2

Procedura `etl.usp_Load_DimPowerPlant` (`00_Create_PowerDWH_empty.sql` / `SCD_2_DimPowerPlant.sql`):
1. `@LoadTimeId` = `TimeId` północy dnia ładowania (`YYYYMMDD00000`). Jeśli brak takiego wiersza w `DimTime` → `THROW` (sygnał: rozszerz zakres `DimTime`).
2. **Zamknięcie wersji**: jeśli dla aktywnego rekordu (`isValid=1`) zmieniła się `category` lub `installed_power` → `validTo=@LoadTimeId`, `isValid=0`. Warunek `validFrom <> @LoadTimeId` chroni przed wersją zerowej długości (dwie zmiany tego samego dnia).
3. **Wstawienie nowych wersji**: dla zmienionych (już zamkniętych) i całkiem nowych elektrowni → nowy rekord `isValid=1`, `validFrom=@LoadTimeId`, `validTo=NULL`.
- Klucz biznesowy = `PowerPlantName`. Współrzędne i województwo nie wyzwalają nowej wersji (tylko kategoria i moc).

---

## 5. Cykliczne uruchamianie (orkiestracja)

### 5.1 `load_range.py` — orkiestrator z audytem i gatingiem

Tryby:
```bash
python load_range.py                       # 'range'       : 2 mies. wstecz .. wczoraj (pełne odświeżenie okna)
python load_range.py --incremental         # 'incremental' : ostatnie 14 dni .. wczoraj (zadanie cykliczne)
python load_range.py 2026-01-01 2026-03-31 # 'backfill'    : własny zakres (historia)
python load_range.py --no-ssis             # tylko ekstrakty do staging, bez SSIS
```

**Kolejność i zależności (gating):**
```
1. extract_powerplant            (Python, KRYTYCZNY)
2. Load_DimPowerPlant            (SSIS,   KRYTYCZNY — pogoda i fakty go potrzebują)
3. extract_poland_energy ─┐
   extract_power_output   ├─ (Python, niezależne; sukces każdego śledzony osobno)
   extract_weather       ─┘   (czyta współrzędne z DimPowerPlant → dlatego po kroku 2)
4. Load_FactPolandEnergy / Load_FactPowerPlantOutput / Load_FactWeather
   (SSIS — pakiet faktu rusza TYLKO gdy jego ekstrakt się powiódł)
```
- Krok krytyczny (1 lub 2) padł → cały bieg `FAILED`, przerwanie.
- Ekstrakt faktu padł (typowo pogoda – opóźnienie źródła) → pakiet faktu **pominięty (SKIPPED)**, bieg kończy się `PARTIAL`. Pusty staging **nie nadpisze** dobrego faktu.
- `dtexec` szukany wśród wersji SQL Server 160/150/140/130 (lub `--no-ssis`).

### 5.2 Dlaczego okno kroczące, a nie watermark

- Meteostat publikuje dane z **kilkudniowym opóźnieniem**.
- Fakty ładowane są metodą **DELETE-okno + INSERT** (idempotentnie dla okna ze staging).
- Tryb `incremental` co bieg wciąga ostatnie **14 dni** (`INCREMENTAL_DAYS` > spodziewane opóźnienie) → spóźnione dane pogodowe i korekty PSE same się uzupełniają, **bez duplikatów**.

### 5.3 Harmonogram (produkcja)

- **Harmonogram zadań Windows** uruchamia `run_etl.ps1` codziennie.
- `run_etl.ps1` → `python load_range.py --incremental`, log do `logs\etl_RRRRMMDD.log`, zwraca kod wyjścia.
- Alternatywa orkiestracji wewnątrz SSIS: pakiet `Master.dtsx` (`Load_DimPowerPlant`, a po sukcesie równolegle trzy pakiety faktów).

### 5.4 Audyt biegów (`schemat audit`)

`Audit_setup.sql` tworzy:
- `audit.EtlRun` — jeden wiersz na bieg: `Mode`, `DateFrom/To`, `RunSsis`, `Status` (RUNNING→SUCCESS/PARTIAL/FAILED), `DurationSec`, `Host`, `ErrorMessage`.
- `audit.EtlStep` — jeden wiersz na krok: `StepName`, `StepType` (python/ssis), `Status` (SUCCESS/FAILED/SKIPPED), `[Rows]` (liczba wierszy w staging/fakcie), `DurationSec`, `Detail`.
- `audit.vLastRun` — widok ostatniego biegu z krokami.

---

## 6. Obsługa zmiany czasu (DST) — kompletny łańcuch

1. **PSE** oznacza drugą, zdublowaną godzinę jesienią literą `a` doklejaną do `dtime`.
2. **Python** (`parse_pse_dtime`) wykrywa `a` → `isExtraHour=1`, obcina literę; grupuje po `(slot, isExtraHour)`, żeby nie skleić dwóch kopii godziny.
3. **DimTime** ma osobny wiersz dla zdublowanej godziny (bit `X=1` na końcu `TimeId`).
4. **SSIS** „soli" klucz czasu wyrażeniem `DATEADD(SECOND, isExtraHour, ts)` po obu stronach lookupu → wiersz dla godziny dodatkowej trafia na własny `TimeId`, klucze pozostają unikalne.
5. **Wiosna** (brakująca godzina): flagi `isMissingHourDay`/`isMissingHour` w `DimTime`.

---

## 7. Kontrola jakości danych

- **`DataQuality_checks.sql`** — framework reguł w wymiarach: Kompletność, Unikalność, Poprawność, Spójność, Aktualność. Wyniki → `dq.CheckResults` ze statusem PASS/FAIL i `RunId`. Sprawdza m.in. unikalność kluczy faktów, integralność `TimeId`/`PowerPlantId`, poprawność SCD2, fizyczne zakresy miar pogodowych.
- **`PostLoad_checks.sql`** — szybki test po ładowaniu: liczby wierszy, zakres dat, świeżość każdego faktu (z tolerancją na lag Meteostatu dla `FactWeather`), brakujące dni, dni o nietypowej liczbie kwadransów, elektrownie ze staging niedopasowane do wymiaru.
- Uzupełnienie: techniczny **audyt** (`audit.EtlRun/EtlStep`) wiąże wyniki reguł z konkretnym biegiem.

---

## 8. Mapowanie źródło → cel (skrót STTM)

| Cel                     | Źródło                         | Pola źródłowe | Reguła |
|-------------------------|--------------------------------|---------------|--------|
| `DimPowerPlant`         | PSE `gen-jw` + `powerplant_meta.csv` (atrybuty z Instrat) | nazwa, kategoria, moc, lokalizacja | SCD2 po nazwie jako kluczu biznesowym |
| `DimTime`               | generator kalendarza           | timestamp     | atrybuty kalendarzowe + flagi DST |
| `FactWeather`           | Meteostat                      | `temp,dwpt,rhum,prcp,wdir,wspd,pres,coco` | kopiowanie + lookup czasu/elektrowni |
| `FactPowerPlantOutput`  | PSE `gen-jw`                   | `value`       | agregacja po elektrowni i kwadransie |
| `FactPolandEnergy`      | PSE `energy-prices`,`rce-pln`,`kse-load` | ceny, bilans, load | agregacja do kwadransa; średnia (suma dla `balance_power`) |

---

## 9. Prawdopodobne pytania na obronie (gotowe odpowiedzi)

- **Czemu Python + SSIS, a nie jedno narzędzie?** Python wygodny do REST/paginacji/transformacji (pandas); SSIS daje sprawdzone lookupy, SCD2 i orkiestrację w ekosystemie SQL Server. Granica: E/T w Pythonie, L w SSIS.
- **Czemu staging jest pełny (TRUNCATE+reload), a nie inkrementalny?** Okno dat jest małe i zamknięte; pełny reload = prostota i idempotencja. Inkrementalność jest na poziomie *faktów* (DELETE-okno+INSERT) i okna kroczącego.
- **Jak nie powstają duplikaty przy nakładających się oknach?** Fakty ładowane metodą DELETE-okno+INSERT; ten sam zakres można puścić wielokrotnie bez skutków ubocznych.
- **Co, gdy pogoda się spóźni?** Ekstrakt pogody zwróci mniej/nic → pakiet `Load_FactWeather` jest pominięty, bieg = PARTIAL, stary fakt nietknięty. Następny bieg (okno 14 dni) dociągnie braki.
- **Jak radzicie sobie ze zmianą czasu?** Marker `a` z PSE → `isExtraHour` → osobny `TimeId` (bit X) → „solony" lookup w SSIS. Wiosenna luka oznaczona flagami missing-hour.
- **Po co `slot_start = dtime − 15 min`?** PSE datuje koniec kwadransa; ujednolicamy do początku slotu, żeby spójnie łączyć z `DimTime`.
- **Skąd metadane elektrowni?** Lista z PSE `gen-jw`; atrybuty (kategoria/moc/lokalizacja/województwo) z bazy elektrowni Instrat, utrzymywane w `powerplant_meta.csv`.
- **Czemu kolejność DimPowerPlant → pogoda jest sztywna?** `extract_weather.py` czyta współrzędne aktywnych elektrowni z `DimPowerPlant` — bez aktualnego wymiaru nie wie, dla jakich punktów pobrać pogodę.

---

## 10. Ściąga „gdzie co jest" (pliki)

| Obszar | Plik |
|--------|------|
| Ekstrakcja elektrowni | `Python_scripts/extract_powerplant.py` |
| Ekstrakcja danych krajowych | `Python_scripts/extract_poland_energy.py` |
| Ekstrakcja generacji | `Python_scripts/extract_power_output.py` |
| Ekstrakcja pogody | `Python_scripts/extract_weather.py` |
| Generator kalendarza | `Python_scripts/DimTimeloader.py` |
| Orkiestrator | `Python_scripts/load_range.py` |
| Wrapper Harmonogramu Windows | `Python_scripts/run_etl.ps1` |
| Metadane elektrowni | `Python_scripts/powerplant_meta.csv` |
| Model hurtowni + SCD2 | `sql_help/00_Create_PowerDWH_empty.sql`, `sql_help/SCD_2_DimPowerPlant.sql` |
| Audyt | `sql_help/Audit_setup.sql` |
| Kontrola jakości | `sql_help/DataQuality_checks.sql`, `sql_help/PostLoad_checks.sql` |
| Pakiety SSIS | `Power_DWH/Master.dtsx`, `Load_*.dtsx` |
| Raport BI | `business.pbix` |
