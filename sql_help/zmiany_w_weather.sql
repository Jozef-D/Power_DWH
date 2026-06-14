ALTER TABLE FactWeather ALTER COLUMN pressure   DECIMAL(6,1) NULL;  -- ~1013 hPa nie miesci sie w (4,1)
ALTER TABLE FactWeather ALTER COLUMN temp                  DECIMAL(4,1) NULL;
ALTER TABLE FactWeather ALTER COLUMN dew_point             DECIMAL(4,1) NULL;
ALTER TABLE FactWeather ALTER COLUMN relative_humidity_pct DECIMAL(4,1) NULL;
ALTER TABLE FactWeather ALTER COLUMN precipitation         DECIMAL(4,1) NULL;
ALTER TABLE FactWeather ALTER COLUMN wind_direction        DECIMAL(4,1) NULL;
ALTER TABLE FactWeather ALTER COLUMN wind_speed            DECIMAL(4,1) NULL;
ALTER TABLE FactWeather ALTER COLUMN weather_code          INT NULL;