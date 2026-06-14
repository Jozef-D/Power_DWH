/* =====================================================================
   Power_DWH - ocena jakosci danych (Data Quality).
   Skrypt jest re-runnable: kazde uruchomienie dopisuje nowy RunId.
   Kazda regula liczy FailCount (liczba naruszeń); Status = PASS gdy
   FailCount <= Threshold (domyslnie 0), w przeciwnym razie FAIL.
   Wymiary jakosci: Kompletnosc, Unikalnosc, Poprawnosc, Spojnosc, Aktualnosc.
   ===================================================================== */
USE PowerDWH;
GO
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF SCHEMA_ID('dq') IS NULL EXEC('CREATE SCHEMA dq;');
GO

IF OBJECT_ID('dq.CheckResults') IS NULL
CREATE TABLE dq.CheckResults (
    RunId      INT          NOT NULL,
    CheckTime  DATETIME2    NOT NULL CONSTRAINT DF_dq_time DEFAULT SYSDATETIME(),
    Dimension  VARCHAR(20)  NOT NULL,
    TableName  VARCHAR(40)  NOT NULL,
    CheckName  VARCHAR(140) NOT NULL,
    FailCount  BIGINT       NOT NULL,
    Threshold  BIGINT       NOT NULL CONSTRAINT DF_dq_thr DEFAULT 0,
    Status     AS (CASE WHEN FailCount <= Threshold THEN 'PASS' ELSE 'FAIL' END) PERSISTED,
    Details    VARCHAR(400) NULL
);
GO

DECLARE @RunId INT = ISNULL((SELECT MAX(RunId) FROM dq.CheckResults), 0) + 1;
-- gorna granica TimeId (sentinel dla otwartej wersji SCD validTo = NULL)
DECLARE @MaxTimeId BIGINT = 99999999999999;

/* =======================  DimTime  ======================= */

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Poprawnosc','DimTime','quarter_hour spoza {0,15,30,45}',
       COUNT(*), 'Slot 15-min musi byc 0/15/30/45'
FROM dbo.DimTime WHERE quarter_hour NOT IN (0,15,30,45);

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Poprawnosc','DimTime','pola kalendarzowe poza zakresem',
       COUNT(*), 'hour 0-23, month 1-12, dayOfWeek 1-7, quarter_year 1-4'
FROM dbo.DimTime
WHERE [hour] NOT BETWEEN 0 AND 23 OR [month] NOT BETWEEN 1 AND 12
   OR dayOfWeek NOT BETWEEN 1 AND 7 OR quarter_year NOT BETWEEN 1 AND 4;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Spojnosc','DimTime','isWeekend niezgodny z dayOfWeek',
       COUNT(*), 'isWeekend ma byc 1 tylko dla dayOfWeek IN (6,7)'
FROM dbo.DimTime
WHERE isWeekend <> CASE WHEN dayOfWeek IN (6,7) THEN 1 ELSE 0 END;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Spojnosc','DimTime','isExtraHour=1 poza dniem zmiany czasu',
       COUNT(*), 'isExtraHour moze byc 1 tylko gdy isExtraHourDay=1'
FROM dbo.DimTime WHERE isExtraHour = 1 AND isExtraHourDay = 0;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Spojnosc','DimTime','ostatnia cyfra TimeId != isExtraHour',
       COUNT(*), 'Bit X w TimeId musi rownac sie kolumnie isExtraHour'
FROM dbo.DimTime WHERE (TimeId % 10) <> CAST(isExtraHour AS int);

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Unikalnosc','DimTime','zduplikowane TimeId',
       COUNT(*), 'TimeId musi byc unikalny'
FROM (SELECT TimeId FROM dbo.DimTime GROUP BY TimeId HAVING COUNT(*) > 1) x;

/* =======================  DimPowerPlant  ======================= */

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Unikalnosc','DimPowerPlant','wiele aktywnych wersji elektrowni',
       COUNT(*), 'Dla isValid=1 dokladnie jedna wersja na PowerPlantName'
FROM (SELECT PowerPlantName FROM dbo.DimPowerPlant WHERE isValid = 1
      GROUP BY PowerPlantName HAVING COUNT(*) > 1) x;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Spojnosc','DimPowerPlant','SCD2: validTo niezgodny z isValid',
       COUNT(*), 'isValid=1 -> validTo NULL; isValid=0 -> validTo NOT NULL'
FROM dbo.DimPowerPlant
WHERE (isValid = 1 AND validTo IS NOT NULL) OR (isValid = 0 AND validTo IS NULL);

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Spojnosc','DimPowerPlant','SCD2: validFrom >= validTo',
       COUNT(*), 'Okres wersji musi byc dodatni'
FROM dbo.DimPowerPlant WHERE validTo IS NOT NULL AND validFrom >= validTo;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Spojnosc','DimPowerPlant','SCD2: nakladajace sie okresy wersji',
       COUNT(*), 'Dwie wersje tej samej elektrowni nie moga sie nakladac w czasie'
FROM dbo.DimPowerPlant a
JOIN dbo.DimPowerPlant b
  ON a.PowerPlantName = b.PowerPlantName AND a.PowerPlantId < b.PowerPlantId
WHERE a.validFrom < ISNULL(b.validTo,@MaxTimeId)
  AND b.validFrom < ISNULL(a.validTo,@MaxTimeId);

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Poprawnosc','DimPowerPlant','wspolrzedne poza granicami Polski',
       COUNT(*), 'lat 49-55 i lon 14-24, albo (0,0) jako brak danych'
FROM dbo.DimPowerPlant
WHERE NOT ( (latitude = 0 AND longitude = 0)
         OR (latitude BETWEEN 49 AND 55 AND longitude BETWEEN 14 AND 24) );

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Poprawnosc','DimPowerPlant','installed_power < 0',
       COUNT(*), 'Moc zainstalowana nie moze byc ujemna'
FROM dbo.DimPowerPlant WHERE installed_power < 0;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Spojnosc','DimPowerPlant','validFrom/validTo bez wiersza w DimTime',
       COUNT(*), 'Referencyjna integralnosc znacznikow wersji do DimTime'
FROM dbo.DimPowerPlant d
WHERE NOT EXISTS (SELECT 1 FROM dbo.DimTime t WHERE t.TimeId = d.validFrom)
   OR (d.validTo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.DimTime t WHERE t.TimeId = d.validTo));

-- wymiar informacyjny (Threshold wysoki, zeby nie failowac calego raportu)
INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Threshold,Details)
SELECT @RunId,'Kompletnosc','DimPowerPlant','elektrownie z category = unknown',
       COUNT(*), 1000000, 'Brak metadanych w powerplant_meta.csv (informacyjnie)'
FROM dbo.DimPowerPlant WHERE isValid = 1 AND category = 'unknown';

/* =======================  FactPowerPlantOutput  ======================= */

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Unikalnosc','FactPowerPlantOutput','duplikat (PowerPlantId,TimeId)',
       COUNT(*), 'Brak klucza naturalnego na PK - kontrolujemy duplikaty tutaj'
FROM (SELECT PowerPlantId,TimeId FROM dbo.FactPowerPlantOutput
      GROUP BY PowerPlantId,TimeId HAVING COUNT(*) > 1) x;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Spojnosc','FactPowerPlantOutput','klucze obce bez dopasowania',
       COUNT(*), 'PowerPlantId w DimPowerPlant oraz TimeId w DimTime'
FROM dbo.FactPowerPlantOutput f
WHERE NOT EXISTS (SELECT 1 FROM dbo.DimPowerPlant d WHERE d.PowerPlantId=f.PowerPlantId)
   OR NOT EXISTS (SELECT 1 FROM dbo.DimTime t WHERE t.TimeId=f.TimeId);

-- Ujemna generacja jest POPRAWNA dla elektrowni szczytowo-pompowych (kategoria 'Woda',
-- tryb pompowania) i pozostaje zapisana jako wartosc ujemna (moc netto). Bledem jest
-- tylko ujemna generacja poza ta kategoria.
INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Poprawnosc','FactPowerPlantOutput','Power ujemne poza szczytowo-pompowymi',
       COUNT(*), 'Generacja ujemna dozwolona tylko dla kategorii Woda (pompowanie)'
FROM dbo.FactPowerPlantOutput f
JOIN dbo.DimPowerPlant d ON d.PowerPlantId = f.PowerPlantId
WHERE f.Power < 0 AND d.category <> 'Woda';

-- informacyjnie (Threshold wysoki -> zawsze PASS): sloty poboru w trybie pompowania
INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Threshold,Details)
SELECT @RunId,'Poprawnosc','FactPowerPlantOutput','Power ujemne (tryb pompowania, OK)',
       COUNT(*), 1000000, 'Szczytowo-pompowe (Woda): ujemna moc = pobor w trybie pompowania'
FROM dbo.FactPowerPlantOutput f
JOIN dbo.DimPowerPlant d ON d.PowerPlantId = f.PowerPlantId
WHERE f.Power < 0 AND d.category = 'Woda';

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Poprawnosc','FactPowerPlantOutput','Power > 1.05 * moc zainstalowana',
       COUNT(*), 'Generacja przekracza moc zainstalowana wersji elektrowni (margines 5%)'
FROM dbo.FactPowerPlantOutput f
JOIN dbo.DimPowerPlant d ON d.PowerPlantId = f.PowerPlantId
WHERE d.installed_power > 0 AND f.Power > d.installed_power * 1.05;

/* =======================  FactWeather  ======================= */

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Unikalnosc','FactWeather','duplikat (PowerPlantId,TimeId)',
       COUNT(*), 'Jeden pomiar pogody na elektrownie i slot czasu'
FROM (SELECT PowerPlantId,TimeId FROM dbo.FactWeather
      GROUP BY PowerPlantId,TimeId HAVING COUNT(*) > 1) x;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Spojnosc','FactWeather','klucze obce bez dopasowania',
       COUNT(*), 'PowerPlantId w DimPowerPlant oraz TimeId w DimTime'
FROM dbo.FactWeather f
WHERE NOT EXISTS (SELECT 1 FROM dbo.DimPowerPlant d WHERE d.PowerPlantId=f.PowerPlantId)
   OR NOT EXISTS (SELECT 1 FROM dbo.DimTime t WHERE t.TimeId=f.TimeId);

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Poprawnosc','FactWeather','wartosci poza zakresem fizycznym',
       COUNT(*), 'temp[-40,45], rhum[0,100], wdir[0,360], wspd[0,200], prcp>=0, pres[870,1085]'
FROM dbo.FactWeather
WHERE temp < -40 OR temp > 45
   OR relative_humidity_pct < 0 OR relative_humidity_pct > 100
   OR wind_direction < 0 OR wind_direction > 360
   OR wind_speed < 0 OR wind_speed > 200
   OR precipitation < 0
   OR pressure < 870 OR pressure > 1085;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Kompletnosc','FactWeather','wiersz bez zadnego pomiaru',
       COUNT(*), 'Wszystkie miary NULL = pusty wiersz pogody'
FROM dbo.FactWeather
WHERE temp IS NULL AND dew_point IS NULL AND relative_humidity_pct IS NULL
  AND precipitation IS NULL AND wind_direction IS NULL AND wind_speed IS NULL
  AND pressure IS NULL AND weather_code IS NULL;

/* =======================  FactPolandEnergy  ======================= */

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Unikalnosc','FactPolandEnergy','zduplikowany TimeId',
       COUNT(*), 'Dane ogolnokrajowe: jeden wiersz na slot czasu'
FROM (SELECT TimeId FROM dbo.FactPolandEnergy GROUP BY TimeId HAVING COUNT(*) > 1) x;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Spojnosc','FactPolandEnergy','TimeId bez wiersza w DimTime',
       COUNT(*), 'Referencyjna integralnosc do DimTime'
FROM dbo.FactPolandEnergy f
WHERE NOT EXISTS (SELECT 1 FROM dbo.DimTime t WHERE t.TimeId=f.TimeId);

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Poprawnosc','FactPolandEnergy','zapotrzebowanie ujemne',
       COUNT(*), 'load_fcst i load_actual nie moga byc ujemne (ceny moga)'
FROM dbo.FactPolandEnergy WHERE load_fcst < 0 OR load_actual < 0;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Kompletnosc','FactPolandEnergy','wiersz bez zadnej miary',
       COUNT(*), 'Wszystkie miary NULL = pusty wiersz'
FROM dbo.FactPolandEnergy
WHERE cen_cost IS NULL AND cor_cost IS NULL AND ceb_sr_cost IS NULL
  AND sk_cost_power IS NULL AND cdsac_cost IS NULL AND balance_power IS NULL
  AND rce_cost IS NULL AND load_fcst IS NULL AND load_actual IS NULL;

/* =======================  Aktualnosc (Timeliness)  ======================= */

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Aktualnosc','FactPowerPlantOutput','najswiezsze dane starsze niz 60 dni',
       CASE WHEN DATEDIFF(DAY, MAX(t.[timestamp]), SYSDATETIME()) > 60 THEN 1 ELSE 0 END,
       CONCAT('Max timestamp = ', CONVERT(varchar(19), MAX(t.[timestamp]), 120))
FROM dbo.FactPowerPlantOutput f JOIN dbo.DimTime t ON t.TimeId = f.TimeId;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Aktualnosc','FactWeather','najswiezsze dane starsze niz 60 dni',
       CASE WHEN DATEDIFF(DAY, MAX(t.[timestamp]), SYSDATETIME()) > 60 THEN 1 ELSE 0 END,
       CONCAT('Max timestamp = ', CONVERT(varchar(19), MAX(t.[timestamp]), 120))
FROM dbo.FactWeather f JOIN dbo.DimTime t ON t.TimeId = f.TimeId;

INSERT dq.CheckResults (RunId,Dimension,TableName,CheckName,FailCount,Details)
SELECT @RunId,'Aktualnosc','FactPolandEnergy','najswiezsze dane starsze niz 60 dni',
       CASE WHEN DATEDIFF(DAY, MAX(t.[timestamp]), SYSDATETIME()) > 60 THEN 1 ELSE 0 END,
       CONCAT('Max timestamp = ', CONVERT(varchar(19), MAX(t.[timestamp]), 120))
FROM dbo.FactPolandEnergy f JOIN dbo.DimTime t ON t.TimeId = f.TimeId;

/* =======================  RAPORT  ======================= */

-- Szczegoly biezacego uruchomienia
SELECT Dimension, TableName, CheckName, FailCount, Status, Details
FROM dq.CheckResults
WHERE RunId = @RunId
ORDER BY CASE Status WHEN 'FAIL' THEN 0 ELSE 1 END, Dimension, TableName;

-- Podsumowanie: ile PASS / FAIL
SELECT Status, COUNT(*) AS Checks
FROM dq.CheckResults WHERE RunId = @RunId
GROUP BY Status ORDER BY Status;
GO
