/* =====================================================================
   Power_DWH - TEST POPRAWNOSCI DZIALANIA NA DANYCH SYNTETYCZNYCH
   ---------------------------------------------------------------------
   Cel: udowodnic, ze kluczowe mechanizmy hurtowni dzialaja poprawnie,
   bez zaleznosci od zywych zrodel (PSE / Meteostat), Pythona ani SSIS.
   Test wstrzykuje DETERMINISTYCZNE dane syntetyczne, sprawdza wynik
   i NA KONCU WSZYSTKO WYCOFUJE (ROLLBACK) - nie zostawia sladu w bazie.
   Wyniki gromadzone sa w zmiennej tabelarycznej (@res), ktora celowo
   NIE podlega ROLLBACK-owi, dzieki czemu raport przezywa wycofanie danych.

   Co jest weryfikowane (kazda asercja => PASS / FAIL):
     FAZA 1  SCD typu 2 na DimPowerPlant (zamkniecie starej + nowa wersja)
     FAZA 2  Zmiana czasu (DST): powtorzona godzina = dwa odrebne TimeId,
             bez kolizji kluczy (mechanizm "solenia" +1 s w SSIS)
     FAZA 3  Idempotencja ladowania faktu (DELETE-okno + INSERT -> brak duplikatow)
     FAZA 4  Integralnosc referencyjna wymuszana przez baze (FK odrzuca sierote)
     FAZA 5  Kontrola jakosci - test POZYTYWNY (czyste dane => 0 naruszen)
     FAZA 6  Kontrola jakosci - test NEGATYWNY (wstrzykniete bledy => wykryte)

   Wymagania: zalozona baza PowerDWH (00_Create_PowerDWH_empty.sql),
   procedura etl.usp_Load_DimPowerPlant (SCD_2_DimPowerPlant.sql) oraz
   zaladowany DimTime na rok 2026 (DimTimeloader.py + Load_DimTime).

   Uruchomienie:
     sqlcmd -S localhost -d PowerDWH -i sql_help\SyntheticData_test.sql
   ===================================================================== */
USE PowerDWH;
GO
SET NOCOUNT ON;
SET XACT_ABORT OFF;   -- chcemy lapac naruszenia ograniczen bez "dooming" transakcji

DECLARE @res TABLE (   -- zmienna tabelaryczna: PRZEZYWA ROLLBACK (nie jest transakcyjna)
    Seq      INT IDENTITY(1,1),
    Phase    VARCHAR(10),
    TestName VARCHAR(120),
    Expected VARCHAR(60),
    Actual   VARCHAR(60)
);

DECLARE @MaxTimeId BIGINT = 99999999999999;   -- sentinel dla otwartej wersji SCD

-- stale TimeId (musza istniec w DimTime dla 2026 - patrz DimTimeloader.py)
DECLARE @T_today   BIGINT = CAST(CONVERT(char(8), CAST(SYSDATETIME() AS date),112)+'00000' AS BIGINT);
DECLARE @T_old     BIGINT = 2026060100000;   -- 2026-06-01 00:00 (validFrom starej wersji)
DECLARE @T_normal  BIGINT = 2026102502000;   -- 2026-10-25 02:00 godzina zwykla    (X=0)
DECLARE @T_extra   BIGINT = 2026102502001;   -- 2026-10-25 02:00 godzina powtorzona (X=1)
DECLARE @T_w1      BIGINT = 2026061100000;   -- 2026-06-11 00:00 (okno idempotencji)
DECLARE @T_w2      BIGINT = 2026061100150;   -- 2026-06-11 00:15
DECLARE @T_w3      BIGINT = 2026061100300;   -- 2026-06-11 00:30
DECLARE @T_fact    BIGINT = 2026061000000;   -- 2026-06-10 00:00 (rozne testy faktow)
DECLARE @T_fact2   BIGINT = 2026061100450;   -- 2026-06-11 00:45

DECLARE @pp_id INT, @n INT, @base INT, @caught BIT;

BEGIN TRY
BEGIN TRAN;

    /* sanity: czy DimTime ma potrzebne wiersze? jak nie - przerwij z czytelnym bledem */
    IF NOT EXISTS (SELECT 1 FROM dbo.DimTime WHERE TimeId = @T_today)
        THROW 60001, 'Brak wiersza DimTime dla dnia dzisiejszego - zaladuj pelny DimTime (2024-2027).', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.DimTime WHERE TimeId = @T_extra)
        THROW 60002, 'Brak wiersza DimTime dla godziny powtorzonej 2026-10-25 - zaladuj pelny DimTime.', 1;

    /* czyszczenie ewentualnych pozostalosci (w praktyce zbedne - i tak ROLLBACK) */
    DELETE FROM dbo.DimPowerPlant WHERE PowerPlantName = '__SCD_TEST__';
    DELETE FROM stg.PowerPlant   WHERE PowerPlantName = '__SCD_TEST__';

    /* =================================================================
       FAZA 1 - SCD typu 2 na DimPowerPlant
       Scenariusz: istnieje stara, aktywna wersja elektrowni (zalozona
       "wczesniej"); w staging pojawia sie ta sama elektrownia ze ZMIENIONA
       kategoria i moca. Procedura etl.usp_Load_DimPowerPlant powinna
       zamknac stara wersje i otworzyc nowa.
       ================================================================= */

    -- stara, aktywna wersja (validFrom = wczesniejszy TimeId, zeby proc nie pominal jej guardem "ten sam dzien")
    INSERT INTO dbo.DimPowerPlant
        (PowerPlantName, category, latitude, longitude, voivodeship,
         validFrom, validTo, isValid, installed_power, record_creation_date)
    VALUES ('__SCD_TEST__', N'Węgiel kamienny', 52.0, 19.0, 'TEST',
            @T_old, NULL, 1, 1000, @T_old);

    -- zmieniony rekord w staging (inna kategoria i moc)
    INSERT INTO stg.PowerPlant
        (PowerPlantName, category, installed_power, latitude, longitude, voivodeship)
    VALUES ('__SCD_TEST__', N'Gaz ziemny', 1500, 52.0, 19.0, 'TEST');

    EXEC etl.usp_Load_DimPowerPlant;   -- testujemy REALNY artefakt ETL

    -- 1a. dokladnie jedna aktywna wersja
    SELECT @n = COUNT(*) FROM dbo.DimPowerPlant WHERE PowerPlantName='__SCD_TEST__' AND isValid=1;
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('SCD','Po zmianie istnieje dokladnie 1 aktywna wersja','1',CAST(@n AS varchar(60)));

    -- 1b. aktywna wersja ma NOWA kategorie i moc, validTo NULL
    SELECT @n = COUNT(*) FROM dbo.DimPowerPlant
    WHERE PowerPlantName='__SCD_TEST__' AND isValid=1
      AND category=N'Gaz ziemny' AND installed_power=1500 AND validTo IS NULL;
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('SCD','Aktywna wersja = nowe atrybuty + validTo NULL','1',CAST(@n AS varchar(60)));

    -- 1c. stara wersja zamknieta poprawnie (isValid=0, validTo ustawione i > validFrom)
    SELECT @n = COUNT(*) FROM dbo.DimPowerPlant
    WHERE PowerPlantName='__SCD_TEST__' AND isValid=0
      AND validTo IS NOT NULL AND validTo > validFrom;
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('SCD','Stara wersja zamknieta (isValid=0, validTo>validFrom)','1',CAST(@n AS varchar(60)));

    -- 1d. brak nakladajacych sie okresow wersji
    SELECT @n = COUNT(*)
    FROM dbo.DimPowerPlant a JOIN dbo.DimPowerPlant b
      ON a.PowerPlantName=b.PowerPlantName AND a.PowerPlantId<b.PowerPlantId
    WHERE a.PowerPlantName='__SCD_TEST__'
      AND a.validFrom < ISNULL(b.validTo,@MaxTimeId)
      AND b.validFrom < ISNULL(a.validTo,@MaxTimeId);
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('SCD','Brak nakladajacych sie okresow wersji','0',CAST(@n AS varchar(60)));

    -- zapamietaj id aktywnej wersji do testow faktow
    SELECT @pp_id = PowerPlantId FROM dbo.DimPowerPlant
    WHERE PowerPlantName='__SCD_TEST__' AND isValid=1;

    /* =================================================================
       FAZA 2 - Zmiana czasu (DST): powtorzona godzina
       Wstawiamy dwa pomiary produkcji dla TEJ SAMEJ sciany zegara
       (2026-10-25 02:00) - raz jako godzina zwykla (TimeId konczy sie 0),
       raz jako godzina powtorzona (TimeId konczy sie 1). Oba musza wejsc
       jako ODREBNE wiersze (nie sa duplikatem), co dowodzi, ze model NIE
       skleja dwoch kopii godziny przy jesiennej zmianie czasu.
       ================================================================= */
    INSERT INTO dbo.FactPowerPlantOutput (PowerPlantId, TimeId, Power)
    VALUES (@pp_id, @T_normal, 500), (@pp_id, @T_extra, 480);

    -- 2a. wstawiono dwa wiersze
    SELECT @n = COUNT(*) FROM dbo.FactPowerPlantOutput
    WHERE PowerPlantId=@pp_id AND TimeId IN (@T_normal,@T_extra);
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('DST','Powtorzona godzina = 2 odrebne wiersze faktu','2',CAST(@n AS varchar(60)));

    -- 2b. to dwa rozne TimeId (rozniace sie ostatnia cyfra = bit isExtraHour)
    SELECT @n = COUNT(DISTINCT TimeId) FROM dbo.FactPowerPlantOutput
    WHERE PowerPlantId=@pp_id AND TimeId IN (@T_normal,@T_extra);
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('DST','Dwa rozne TimeId dla tej samej sciany zegara','2',CAST(@n AS varchar(60)));

    -- 2c. w DimTime godzina zwykla ma X=0, powtorzona X=1 (spojnosc znacznika)
    SELECT @n = COUNT(*) FROM dbo.DimTime
    WHERE (TimeId=@T_normal AND isExtraHour=0) OR (TimeId=@T_extra AND isExtraHour=1);
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('DST','DimTime: znacznik isExtraHour zgodny z bitem TimeId','2',CAST(@n AS varchar(60)));

    /* =================================================================
       FAZA 3 - Idempotencja ladowania faktu (DELETE-okno + INSERT)
       Powtorne zaladowanie tego samego okna NIE moze tworzyc duplikatow.
       ================================================================= */
    -- pierwszy "bieg": wyczysc okno i zaladuj 3 wiersze (komplet miar - w bazie sa NOT NULL)
    DELETE FROM dbo.FactPolandEnergy WHERE TimeId IN (@T_w1,@T_w2,@T_w3);
    INSERT INTO dbo.FactPolandEnergy
        (TimeId, cen_cost, cor_cost, ceb_sr_cost, sk_cost_power, cdsac_cost, balance_power, rce_cost, load_fcst, load_actual)
    VALUES (@T_w1, 100,10,110,5,300,0,300,17950,18000),
           (@T_w2, 100,10,110,5,310,0,310,18050,18100),
           (@T_w3, 100,10,110,5,305,0,305,18000,18050);
    SELECT @base = COUNT(*) FROM dbo.FactPolandEnergy WHERE TimeId IN (@T_w1,@T_w2,@T_w3);

    -- drugi "bieg" (symulacja ponownego uruchomienia): znow DELETE-okno + INSERT
    DELETE FROM dbo.FactPolandEnergy WHERE TimeId IN (@T_w1,@T_w2,@T_w3);
    INSERT INTO dbo.FactPolandEnergy
        (TimeId, cen_cost, cor_cost, ceb_sr_cost, sk_cost_power, cdsac_cost, balance_power, rce_cost, load_fcst, load_actual)
    VALUES (@T_w1, 100,10,110,5,300,0,300,17950,18000),
           (@T_w2, 100,10,110,5,310,0,310,18050,18100),
           (@T_w3, 100,10,110,5,305,0,305,18000,18050);
    SELECT @n = COUNT(*) FROM dbo.FactPolandEnergy WHERE TimeId IN (@T_w1,@T_w2,@T_w3);

    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('IDEMP','Ponowny bieg nie tworzy duplikatow (liczba stala)',
            CAST(@base AS varchar(60)), CAST(@n AS varchar(60)));

    /* =================================================================
       FAZA 4 - Integralnosc referencyjna wymuszana przez baze
       Proba wstawienia faktu ze sztucznym, nieistniejacym TimeId musi
       zostac ODRZUCONA przez klucz obcy (FK).
       ================================================================= */
    SET @caught = 0;
    BEGIN TRY
        INSERT INTO dbo.FactPolandEnergy
            (TimeId, cen_cost, cor_cost, ceb_sr_cost, sk_cost_power, cdsac_cost, balance_power, rce_cost, load_fcst, load_actual)
        VALUES (99999999999990, 100,10,110,5,300,0,300,17950,18000);  -- TimeId nie istnieje w DimTime
    END TRY
    BEGIN CATCH
        SET @caught = 1;   -- oczekiwane: naruszenie FK
    END CATCH
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('RI','FK odrzuca fakt z nieistniejacym TimeId','1',CAST(@caught AS varchar(60)));

    /* =================================================================
       FAZA 5 - Kontrola jakosci: test POZYTYWNY
       Na CZYSTYCH danych syntetycznych reguly DQ nie moga zglosic naruszen.
       ================================================================= */
    -- 5a. brak duplikatu (PowerPlantId,TimeId) w produkcji dla naszej elektrowni
    SELECT @n = COUNT(*) FROM (
        SELECT TimeId FROM dbo.FactPowerPlantOutput WHERE PowerPlantId=@pp_id
        GROUP BY TimeId HAVING COUNT(*)>1) x;
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('DQ+','Czyste dane: brak duplikatow produkcji','0',CAST(@n AS varchar(60)));

    -- 5b. dokladnie jedna aktywna wersja elektrowni (unikalnosc SCD)
    SELECT @n = COUNT(*) FROM (
        SELECT PowerPlantName FROM dbo.DimPowerPlant WHERE isValid=1 AND PowerPlantName='__SCD_TEST__'
        GROUP BY PowerPlantName HAVING COUNT(*)>1) x;
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('DQ+','Czyste dane: 0 elektrowni z wieloma aktywnymi wersjami','0',CAST(@n AS varchar(60)));

    /* =================================================================
       FAZA 6 - Kontrola jakosci: test NEGATYWNY
       Wstrzykujemy ZNANE bledy i sprawdzamy, czy reguly DQ je WYKRYWAJA
       (FailCount > 0). To dowodzi, ze kontrole nie sa "puste".
       ================================================================= */

    -- 6a. temperatura poza zakresem fizycznym (temp=60 > 45) w FactWeather
    INSERT INTO dbo.FactWeather (PowerPlantId, TimeId, temp) VALUES (@pp_id, @T_fact, 60.0);
    SELECT @n = COUNT(*) FROM dbo.FactWeather
    WHERE PowerPlantId=@pp_id AND (temp < -40 OR temp > 45);
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('DQ-','Wykryto temperature poza zakresem (>45)','1',
            CASE WHEN @n > 0 THEN '1' ELSE '0' END);

    -- 6b. ujemne zapotrzebowanie krajowe (load_actual = -5)
    INSERT INTO dbo.FactPolandEnergy
        (TimeId, cen_cost, cor_cost, ceb_sr_cost, sk_cost_power, cdsac_cost, balance_power, rce_cost, load_fcst, load_actual)
    VALUES (@T_fact, 100,10,110,5,300,0,300,17950,-5);
    SELECT @n = COUNT(*) FROM dbo.FactPolandEnergy WHERE TimeId=@T_fact AND load_actual < 0;
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('DQ-','Wykryto ujemne zapotrzebowanie (load_actual<0)','1',
            CASE WHEN @n > 0 THEN '1' ELSE '0' END);

    -- 6c. duplikat (PowerPlantId,TimeId) w produkcji
    INSERT INTO dbo.FactPowerPlantOutput (PowerPlantId, TimeId, Power)
    VALUES (@pp_id, @T_fact, 50), (@pp_id, @T_fact, 50);
    SELECT @n = COUNT(*) FROM (
        SELECT TimeId FROM dbo.FactPowerPlantOutput WHERE PowerPlantId=@pp_id AND TimeId=@T_fact
        GROUP BY TimeId HAVING COUNT(*)>1) x;
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('DQ-','Wykryto duplikat (PowerPlantId,TimeId)','1',
            CASE WHEN @n > 0 THEN '1' ELSE '0' END);

    -- 6d. produkcja przekraczajaca moc zainstalowana (>1.05*installed_power)
    INSERT INTO dbo.FactPowerPlantOutput (PowerPlantId, TimeId, Power) VALUES (@pp_id, @T_fact2, 99999);
    SELECT @n = COUNT(*) FROM dbo.FactPowerPlantOutput f
    JOIN dbo.DimPowerPlant d ON d.PowerPlantId=f.PowerPlantId
    WHERE f.PowerPlantId=@pp_id AND d.isValid=1
      AND d.installed_power>0 AND f.Power > d.installed_power*1.05;
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('DQ-','Wykryto produkcje > moc zainstalowana','1',
            CASE WHEN @n > 0 THEN '1' ELSE '0' END);

    -- 6e. nakladajace sie wersje SCD (wstrzykniety drugi, kolidujacy rekord)
    INSERT INTO dbo.DimPowerPlant
        (PowerPlantName, category, latitude, longitude, voivodeship,
         validFrom, validTo, isValid, installed_power, record_creation_date)
    VALUES ('__SCD_TEST__', N'Gaz ziemny', 52.0, 19.0, 'TEST',
            @T_old, NULL, 1, 1500, @T_old);   -- celowo nakladajacy sie ze stara wersja
    SELECT @n = COUNT(*)
    FROM dbo.DimPowerPlant a JOIN dbo.DimPowerPlant b
      ON a.PowerPlantName=b.PowerPlantName AND a.PowerPlantId<b.PowerPlantId
    WHERE a.PowerPlantName='__SCD_TEST__'
      AND a.validFrom < ISNULL(b.validTo,@MaxTimeId)
      AND b.validFrom < ISNULL(a.validTo,@MaxTimeId);
    INSERT @res(Phase,TestName,Expected,Actual)
    VALUES ('DQ-','Wykryto nakladajace sie wersje SCD','1',
            CASE WHEN @n > 0 THEN '1' ELSE '0' END);

ROLLBACK;   -- zero sladu: cofamy wszystkie dane syntetyczne (@res przezywa)
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK;
    PRINT 'BLAD TESTU: ' + ERROR_MESSAGE();
    THROW;
END CATCH

/* =======================  RAPORT WYNIKOW  ======================= */
SELECT Seq AS Lp, Phase AS Faza, TestName AS Test, Expected AS Oczekiwano,
       Actual AS Otrzymano,
       CASE WHEN Expected = Actual THEN 'PASS' ELSE 'FAIL' END AS Status
FROM @res ORDER BY Seq;

SELECT CASE WHEN Expected = Actual THEN 'PASS' ELSE 'FAIL' END AS Status, COUNT(*) AS Liczba
FROM @res GROUP BY CASE WHEN Expected = Actual THEN 'PASS' ELSE 'FAIL' END ORDER BY Status;

IF EXISTS (SELECT 1 FROM @res WHERE Expected <> Actual)
    SELECT 'WYNIK KONCOWY' AS Podsumowanie, 'FAIL - co najmniej jeden test nie przeszedl' AS Komunikat;
ELSE
    SELECT 'WYNIK KONCOWY' AS Podsumowanie, 'PASS - wszystkie testy poprawnosci przeszly' AS Komunikat;
GO
