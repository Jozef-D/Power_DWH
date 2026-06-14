CREATE TABLE stg.Weather (
    PowerPlantId INT      NOT NULL,
    [time]       DATETIME NOT NULL,
    temp FLOAT NULL, dew_point FLOAT NULL, relative_humidity_pct FLOAT NULL,
    precipitation FLOAT NULL, wind_direction FLOAT NULL,
    wind_speed FLOAT NULL, pressure FLOAT NULL,
    weather_code INT NULL
);
GO