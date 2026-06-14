-- plik do sprawdzenia poprawno�ci
USE PowerDWH;
GO
SET NOCOUNT ON;

DECLARE @Yesterday date = DATEADD(DAY, -1, CAST(GETDATE() AS date));
DECLARE @WeatherLagDays int = 7;   -- Meteostat publikuje z opoznieniem; tolerancja dla pogody

SELECT 'FactPolandEnergy' AS Tabela, COUNT(*) AS Wierszy,
       MIN(t.[timestamp]) AS Od, MAX(t.[timestamp]) AS [Do],
       DATEDIFF(DAY, MAX(t.[timestamp]), GETDATE()) AS DniOdNajswiezszego
FROM dbo.FactPolandEnergy f JOIN dbo.DimTime t ON t.TimeId = f.TimeId
UNION ALL
SELECT 'FactPowerPlantOutput', COUNT(*),
       MIN(t.[timestamp]), MAX(t.[timestamp]),
       DATEDIFF(DAY, MAX(t.[timestamp]), GETDATE())
FROM dbo.FactPowerPlantOutput f JOIN dbo.DimTime t ON t.TimeId = f.TimeId
UNION ALL
SELECT 'FactWeather', COUNT(*),
       MIN(t.[timestamp]), MAX(t.[timestamp]),
       DATEDIFF(DAY, MAX(t.[timestamp]), GETDATE())
FROM dbo.FactWeather f JOIN dbo.DimTime t ON t.TimeId = f.TimeId;

SELECT 'stg.PowerPlant'       AS Tabela, COUNT(*) AS Wierszy, CAST(NULL AS datetime) AS Od, CAST(NULL AS datetime) AS [Do] FROM stg.PowerPlant
UNION ALL SELECT 'stg.PolandEnergy',     COUNT(*), MIN([time]),  MAX([time])  FROM stg.PolandEnergy
UNION ALL SELECT 'stg.PowerPlantOutput', COUNT(*), MIN(dtime),   MAX(dtime)   FROM stg.PowerPlantOutput
UNION ALL SELECT 'stg.Weather',          COUNT(*), MIN([time]),  MAX([time])  FROM stg.Weather;

SELECT 'FactPolandEnergy' AS Tabela,
       MAX(CAST(t.[timestamp] AS date)) AS NajswiezszyDzien, @Yesterday AS Oczekiwany,
       CASE WHEN MAX(CAST(t.[timestamp] AS date)) >= @Yesterday THEN 'PASS' ELSE 'FAIL' END AS Status
FROM dbo.FactPolandEnergy f JOIN dbo.DimTime t ON t.TimeId = f.TimeId
UNION ALL
SELECT 'FactPowerPlantOutput', MAX(CAST(t.[timestamp] AS date)), @Yesterday,
       CASE WHEN MAX(CAST(t.[timestamp] AS date)) >= @Yesterday THEN 'PASS' ELSE 'FAIL' END
FROM dbo.FactPowerPlantOutput f JOIN dbo.DimTime t ON t.TimeId = f.TimeId
UNION ALL
SELECT 'FactWeather', MAX(CAST(t.[timestamp] AS date)), DATEADD(DAY, -@WeatherLagDays, @Yesterday),
       CASE WHEN MAX(CAST(t.[timestamp] AS date)) >= DATEADD(DAY, -@WeatherLagDays, @Yesterday) THEN 'PASS' ELSE 'FAIL' END
FROM dbo.FactWeather f JOIN dbo.DimTime t ON t.TimeId = f.TimeId;

SELECT t.[year], t.[month], t.[day], COUNT(*) AS Sloty
FROM dbo.FactPolandEnergy f JOIN dbo.DimTime t ON t.TimeId = f.TimeId
GROUP BY t.[year], t.[month], t.[day]
HAVING COUNT(*) NOT IN (92, 96, 100)
ORDER BY t.[year], t.[month], t.[day];

;WITH rng AS (
    SELECT MIN(CAST(t.[timestamp] AS date)) AS d_from,
           MAX(CAST(t.[timestamp] AS date)) AS d_to
    FROM dbo.FactPolandEnergy f JOIN dbo.DimTime t ON t.TimeId = f.TimeId
), dni AS (
    SELECT DISTINCT CAST(t.[timestamp] AS date) AS dz
    FROM dbo.DimTime t, rng
    WHERE CAST(t.[timestamp] AS date) BETWEEN rng.d_from AND rng.d_to
)
SELECT dni.dz AS BrakujacyDzien
FROM dni
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.FactPolandEnergy f JOIN dbo.DimTime t ON t.TimeId = f.TimeId
    WHERE CAST(t.[timestamp] AS date) = dni.dz)
ORDER BY dni.dz;

SELECT DISTINCT s.power_plant AS NiedopasowanaElektrownia
FROM stg.PowerPlantOutput s
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.DimPowerPlant d
    WHERE d.isValid = 1 AND d.PowerPlantName = s.power_plant)
ORDER BY s.power_plant;

SELECT 'FactPowerPlantOutput' AS Tabela,
       COUNT(DISTINCT CAST(t.[timestamp] AS date)) AS Dni,
       COUNT(DISTINCT f.PowerPlantId) AS Elektrowni
FROM dbo.FactPowerPlantOutput f JOIN dbo.DimTime t ON t.TimeId = f.TimeId
UNION ALL
SELECT 'FactWeather',
       COUNT(DISTINCT CAST(t.[timestamp] AS date)),
       COUNT(DISTINCT f.PowerPlantId)
FROM dbo.FactWeather f JOIN dbo.DimTime t ON t.TimeId = f.TimeId;
GO
