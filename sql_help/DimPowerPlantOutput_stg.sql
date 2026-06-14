CREATE TABLE stg.PowerPlantOutput (
    power_plant VARCHAR(100) NOT NULL,
    dtime       DATETIME     NOT NULL,
    [value]     FLOAT        NOT NULL,
    -- 1 = druga (powtorzona) godzina przy jesiennej zmianie czasu (PSE oznacza dtime litera 'a')
    isExtraHour BIT          NOT NULL CONSTRAINT DF_stgPPO_isExtraHour DEFAULT 0
);
GO