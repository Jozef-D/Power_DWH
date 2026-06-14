CREATE OR ALTER PROCEDURE etl.usp_Load_DimPowerPlant
AS
BEGIN
    SET NOCOUNT ON;

    -- TimeId p�nocy dnia �adowania: YYYYMMDD + HH(00)+QQ(00)+X(0)
    DECLARE @LoadTimeId BIGINT =
        CAST(CONVERT(char(8), CAST(SYSDATETIME() AS date), 112) + '00000' AS BIGINT);

    IF NOT EXISTS (SELECT 1 FROM DimTime WHERE TimeId = @LoadTimeId)
        THROW 50001, 'Brak wiersza DimTime dla dnia ladowania � rozszerz zakres DimTime.', 1;

    -- 1) zamknij wersje, w ktorych zmienila sie category lub installed_power
    UPDATE d
       SET d.validTo = @LoadTimeId,
           d.isValid = 0
    FROM DimPowerPlant d
    JOIN stg.PowerPlant s ON s.PowerPlantName = d.PowerPlantName
    WHERE d.isValid = 1
      AND d.validFrom <> @LoadTimeId   -- nie zamykaj wersji otwartej tego samego dnia (unika wersji zerowej dlugosci)
      AND (d.category <> s.category OR d.installed_power <> s.installed_power);

    -- 2) wstaw nowe wersje dla zmienionych (juz zamknietych) i calkiem nowych elektrowni
    INSERT INTO DimPowerPlant
        (PowerPlantName, category, latitude, longitude, voivodeship,
         validFrom, validTo, isValid, installed_power, record_creation_date)
    SELECT s.PowerPlantName, s.category,
           COALESCE(s.latitude, 0), COALESCE(s.longitude, 0), s.voivodeship,
           @LoadTimeId, NULL, 1, s.installed_power, @LoadTimeId
    FROM stg.PowerPlant s
    LEFT JOIN DimPowerPlant d
           ON d.PowerPlantName = s.PowerPlantName AND d.isValid = 1
    WHERE d.PowerPlantName IS NULL;   -- brak otwartej wersji = nowa lub wlasnie zamknieta
END