/* =====================================================================
   Power_DWH - schemat audytu ETL.
   Loguje kazdy bieg orkiestratora (load_range.py): czas, tryb, zakres,
   status oraz per-krok liczby wierszy i ewentualne bledy.
   Re-runnable.
   ===================================================================== */
USE PowerDWH;
GO
IF SCHEMA_ID('audit') IS NULL EXEC('CREATE SCHEMA audit;');
GO

IF OBJECT_ID('audit.EtlRun') IS NULL
CREATE TABLE audit.EtlRun (
    RunId        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EtlRun PRIMARY KEY,
    StartedAt    DATETIME2    NOT NULL CONSTRAINT DF_EtlRun_Started DEFAULT SYSDATETIME(),
    FinishedAt   DATETIME2    NULL,
    Mode         VARCHAR(20)  NOT NULL,                 -- range | incremental | backfill
    DateFrom     DATE         NULL,
    DateTo       DATE         NULL,
    RunSsis      BIT          NOT NULL,
    Status       VARCHAR(20)  NOT NULL CONSTRAINT DF_EtlRun_Status DEFAULT 'RUNNING', -- RUNNING|SUCCESS|PARTIAL|FAILED
    DurationSec  INT          NULL,
    Host         VARCHAR(128) NULL,
    ErrorMessage VARCHAR(2000) NULL
);
GO

IF OBJECT_ID('audit.EtlStep') IS NULL
CREATE TABLE audit.EtlStep (
    StepId      BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_EtlStep PRIMARY KEY,
    RunId       INT          NOT NULL CONSTRAINT FK_EtlStep_Run REFERENCES audit.EtlRun(RunId),
    StepName    VARCHAR(80)  NOT NULL,
    StepType    VARCHAR(20)  NOT NULL,                  -- python | ssis
    StartedAt   DATETIME2    NOT NULL CONSTRAINT DF_EtlStep_Started DEFAULT SYSDATETIME(),
    FinishedAt  DATETIME2    NULL,
    Status      VARCHAR(20)  NOT NULL CONSTRAINT DF_EtlStep_Status DEFAULT 'RUNNING', -- RUNNING|SUCCESS|FAILED|SKIPPED
    [Rows]      BIGINT       NULL,                      -- wiersze w staging po ekstrakcie / w fakcie po zaladowaniu
    DurationSec INT          NULL,
    Detail      VARCHAR(2000) NULL
);
GO
CREATE NONCLUSTERED INDEX IX_EtlStep_Run ON audit.EtlStep(RunId);
GO

-- Wygodny widok: ostatni bieg + jego kroki
IF OBJECT_ID('audit.vLastRun') IS NOT NULL DROP VIEW audit.vLastRun;
GO
CREATE VIEW audit.vLastRun AS
SELECT TOP (1000) r.RunId, r.StartedAt, r.Status AS RunStatus, r.Mode, r.DateFrom, r.DateTo,
       s.StepName, s.StepType, s.Status AS StepStatus, s.[Rows], s.DurationSec, s.Detail
FROM audit.EtlRun r
JOIN audit.EtlStep s ON s.RunId = r.RunId
WHERE r.RunId = (SELECT MAX(RunId) FROM audit.EtlRun)
ORDER BY s.StepId;
GO
