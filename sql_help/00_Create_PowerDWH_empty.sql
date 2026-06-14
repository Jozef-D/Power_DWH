
IF DB_ID('PowerDWH') IS NULL
    CREATE DATABASE PowerDWH;
GO

USE PowerDWH;
GO

IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl;');
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg;');
GO


CREATE TABLE dbo.DimTime (
    TimeId           BIGINT   NOT NULL,
    [timestamp]      DATETIME NOT NULL,
    [year]           INT      NOT NULL,
    quarter_year     TINYINT  NOT NULL,
    [month]          TINYINT  NOT NULL,
    [week]           TINYINT  NOT NULL,
    [day]            TINYINT  NOT NULL,
    [hour]           TINYINT  NOT NULL,
    quarter_hour     TINYINT  NOT NULL,
    dayOfWeek        TINYINT  NOT NULL,
    isWeekend        BIT      NOT NULL,
    isExtraHourDay   BIT      NOT NULL,
    isExtraHour      BIT      NOT NULL,
    isMissingHourDay BIT      NOT NULL,
    isMissingHour    BIT      NOT NULL,
    CONSTRAINT PK_DimTime PRIMARY KEY CLUSTERED (TimeId)
);
GO

CREATE TABLE dbo.DimPowerPlant (
    PowerPlantId         INT IDENTITY(1,1) NOT NULL,
    PowerPlantName       VARCHAR(100) NOT NULL,
    category             VARCHAR(100) NOT NULL,
    latitude             DECIMAL(9,6) NULL,
    longitude            DECIMAL(9,6) NULL,
    voivodeship          VARCHAR(100) NOT NULL,
    validFrom            BIGINT NOT NULL,
    validTo              BIGINT NULL,
    isValid              BIT NOT NULL CONSTRAINT DF_DimPowerPlant_isValid DEFAULT (1),
    installed_power      INT NOT NULL,
    record_creation_date BIGINT NOT NULL,
    CONSTRAINT PK_DimPowerPlant PRIMARY KEY CLUSTERED (PowerPlantId)
);
GO

CREATE TABLE dbo.FactPowerPlantOutput (
    FactPowerId  BIGINT IDENTITY(1,1) NOT NULL,
    PowerPlantId INT    NOT NULL,
    TimeId       BIGINT NOT NULL,
    Power        FLOAT  NOT NULL,
    CONSTRAINT PK_FactPowerPlantOutput PRIMARY KEY CLUSTERED (FactPowerId),
    CONSTRAINT FK_fact_power_plant FOREIGN KEY (PowerPlantId) REFERENCES dbo.DimPowerPlant (PowerPlantId),
    CONSTRAINT FK_fact_power_time  FOREIGN KEY (TimeId)       REFERENCES dbo.DimTime (TimeId)
);
GO
CREATE NONCLUSTERED INDEX idx_power_plant_time ON dbo.FactPowerPlantOutput (TimeId);
GO

CREATE TABLE dbo.FactWeather (
    FactWeatherId         BIGINT IDENTITY(1,1) NOT NULL,
    PowerPlantId          INT    NOT NULL,
    TimeId                BIGINT NOT NULL,
    temp                  DECIMAL(4,1) NULL,
    dew_point             DECIMAL(4,1) NULL,
    relative_humidity_pct DECIMAL(4,1) NULL,
    precipitation         DECIMAL(4,1) NULL,
    wind_direction        DECIMAL(4,1) NULL,
    wind_speed            DECIMAL(4,1) NULL,
    pressure              DECIMAL(6,1) NULL,
    weather_code          INT NULL,
    CONSTRAINT PK_FactWeather PRIMARY KEY CLUSTERED (FactWeatherId),
    CONSTRAINT FK_fact_weather_power_plant FOREIGN KEY (PowerPlantId) REFERENCES dbo.DimPowerPlant (PowerPlantId),
    CONSTRAINT FK_fact_weather_time        FOREIGN KEY (TimeId)       REFERENCES dbo.DimTime (TimeId)
);
GO
CREATE NONCLUSTERED INDEX idx_weather_power_plant ON dbo.FactWeather (PowerPlantId);
CREATE NONCLUSTERED INDEX idx_weather_time        ON dbo.FactWeather (TimeId);
GO

CREATE TABLE dbo.FactPolandEnergy (
    FactNationwideDataId BIGINT IDENTITY(1,1) NOT NULL,
    TimeId        BIGINT NOT NULL,
    cen_cost      DECIMAL(16,4) NULL,
    cor_cost      DECIMAL(16,4) NULL,
    ceb_sr_cost   DECIMAL(16,4) NULL,
    sk_cost_power DECIMAL(16,4) NULL,
    cdsac_cost    DECIMAL(16,4) NULL,
    balance_power DECIMAL(16,4) NULL,
    rce_cost      DECIMAL(16,4) NULL,
    load_fcst     DECIMAL(16,4) NULL,
    load_actual   DECIMAL(16,4) NULL,
    CONSTRAINT PK_FactPolandEnergy PRIMARY KEY CLUSTERED (FactNationwideDataId),
    CONSTRAINT FK_fact_nationwide_time FOREIGN KEY (TimeId) REFERENCES dbo.DimTime (TimeId)
);
GO
CREATE NONCLUSTERED INDEX idx_nationwide_time ON dbo.FactPolandEnergy (TimeId);
GO


CREATE TABLE stg.PowerPlant (
    PowerPlantName  VARCHAR(100) NOT NULL,
    category        VARCHAR(100) NOT NULL,
    installed_power INT          NOT NULL,
    latitude        DECIMAL(9,6) NULL,
    longitude       DECIMAL(9,6) NULL,
    voivodeship     VARCHAR(100) NOT NULL
);
GO

CREATE TABLE stg.PowerPlantOutput (
    power_plant VARCHAR(100) NOT NULL,
    dtime       DATETIME     NOT NULL,
    [value]     FLOAT        NOT NULL,
    isExtraHour BIT          NOT NULL CONSTRAINT DF_stgPPO_isExtraHour DEFAULT (0)
);
GO

CREATE TABLE stg.PolandEnergy (
    [time]        DATETIME NOT NULL,
    isExtraHour   BIT      NOT NULL CONSTRAINT DF_stgPE_isExtraHour DEFAULT (0),
    cen_cost FLOAT NULL, cor_cost FLOAT NULL, ceb_sr_cost FLOAT NULL,
    sk_cost_power FLOAT NULL, cdsac_cost FLOAT NULL, balance_power FLOAT NULL,
    rce_cost FLOAT NULL, load_fcst FLOAT NULL, load_actual FLOAT NULL
);
GO

CREATE TABLE stg.Weather (
    PowerPlantId INT      NOT NULL,
    [time]       DATETIME NOT NULL,
    temp FLOAT NULL, dew_point FLOAT NULL, relative_humidity_pct FLOAT NULL,
    precipitation FLOAT NULL, wind_direction FLOAT NULL,
    wind_speed FLOAT NULL, pressure FLOAT NULL,
    weather_code INT NULL
);
GO

CREATE OR ALTER PROCEDURE etl.usp_Load_DimPowerPlant
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LoadTimeId BIGINT =
        CAST(CONVERT(char(8), CAST(SYSDATETIME() AS date), 112) + '00000' AS BIGINT);

    IF NOT EXISTS (SELECT 1 FROM dbo.DimTime WHERE TimeId = @LoadTimeId)
        THROW 50001, 'Brak wiersza DimTime dla dnia ladowania - rozszerz zakres DimTime.', 1;

    UPDATE d
       SET d.validTo = @LoadTimeId,
           d.isValid = 0
    FROM dbo.DimPowerPlant d
    JOIN stg.PowerPlant s ON s.PowerPlantName = d.PowerPlantName
    WHERE d.isValid = 1
      AND d.validFrom <> @LoadTimeId
      AND (d.category <> s.category OR d.installed_power <> s.installed_power);

    INSERT INTO dbo.DimPowerPlant
        (PowerPlantName, category, latitude, longitude, voivodeship,
         validFrom, validTo, isValid, installed_power, record_creation_date)
    SELECT s.PowerPlantName, s.category,
           COALESCE(s.latitude, 0), COALESCE(s.longitude, 0), s.voivodeship,
           @LoadTimeId, NULL, 1, s.installed_power, @LoadTimeId
    FROM stg.PowerPlant s
    LEFT JOIN dbo.DimPowerPlant d
           ON d.PowerPlantName = s.PowerPlantName AND d.isValid = 1
    WHERE d.PowerPlantName IS NULL;
END
GO
