CREATE SCHEMA etl;
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