CREATE TABLE stg.PolandEnergy (
    [time]        DATETIME NOT NULL,
    -- 1 = druga (powtorzona) godzina przy jesiennej zmianie czasu (PSE oznacza dtime litera 'a')
    isExtraHour   BIT      NOT NULL CONSTRAINT DF_stgPE_isExtraHour DEFAULT 0,
    cen_cost FLOAT NULL, cor_cost FLOAT NULL, ceb_sr_cost FLOAT NULL,
    sk_cost_power FLOAT NULL, cdsac_cost FLOAT NULL, balance_power FLOAT NULL,
    rce_cost FLOAT NULL, load_fcst FLOAT NULL, load_actual FLOAT NULL
);
GO