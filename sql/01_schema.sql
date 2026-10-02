/* =====================================================================
   Contract Approval Workflow - Step 1: SQL Server schema
   Run in SSMS / Azure Data Studio / VS Code (mssql extension).
   ===================================================================== */

IF DB_ID('ContractWorkflow') IS NULL
    CREATE DATABASE ContractWorkflow;
GO
USE ContractWorkflow;
GO

/* ---------- Tables ---------- */

CREATE TABLE dbo.Contracts (
    ContractId        INT IDENTITY(1,1) PRIMARY KEY,
    Title             NVARCHAR(200)  NOT NULL,
    Counterparty      NVARCHAR(200)  NOT NULL,
    ContractType      NVARCHAR(50)   NOT NULL,           -- NDA, MSA, SOW, Vendor...
    ContractValue     DECIMAL(18,2)  NULL,
    Status            NVARCHAR(30)   NOT NULL
        CONSTRAINT DF_Contracts_Status DEFAULT 'Submitted'
        CONSTRAINT CK_Contracts_Status CHECK (Status IN ('Submitted','InReview','Approved','Rejected')),
    SharePointItemId  INT            NULL,               -- ID of the SharePoint list item
    SubmittedBy       NVARCHAR(150)  NOT NULL,
    CreatedAt         DATETIME2      NOT NULL CONSTRAINT DF_Contracts_Created DEFAULT SYSUTCDATETIME(),
    UpdatedAt         DATETIME2      NOT NULL CONSTRAINT DF_Contracts_Updated DEFAULT SYSUTCDATETIME()
);
GO

-- One SharePoint item = one contract row (makes Power Automate retries safe / idempotent)
CREATE UNIQUE INDEX UX_Contracts_SharePointItemId
    ON dbo.Contracts (SharePointItemId)
    WHERE SharePointItemId IS NOT NULL;
GO

CREATE TABLE dbo.ApprovalHistory (
    HistoryId   INT IDENTITY(1,1) PRIMARY KEY,
    ContractId  INT           NOT NULL
        CONSTRAINT FK_ApprovalHistory_Contracts REFERENCES dbo.Contracts(ContractId),
    Action      NVARCHAR(30)  NOT NULL,                  -- Submitted / Approved / Rejected
    ActedBy     NVARCHAR(150) NOT NULL,
    Comments    NVARCHAR(1000) NULL,
    ActedAt     DATETIME2     NOT NULL CONSTRAINT DF_ApprovalHistory_ActedAt DEFAULT SYSUTCDATETIME()
);
GO

CREATE TABLE dbo.IntegrationLog (
    LogId       INT IDENTITY(1,1) PRIMARY KEY,
    Source      NVARCHAR(50)   NOT NULL,                 -- 'PowerAutomate', 'API', 'SQL'
    Endpoint    NVARCHAR(200)  NULL,
    StatusCode  INT            NULL,
    Level       NVARCHAR(10)   NOT NULL DEFAULT 'INFO',  -- INFO / WARN / ERROR
    Message     NVARCHAR(2000) NOT NULL,
    CreatedAt   DATETIME2      NOT NULL CONSTRAINT DF_IntegrationLog_Created DEFAULT SYSUTCDATETIME()
);
GO

CREATE INDEX IX_ApprovalHistory_ContractId ON dbo.ApprovalHistory (ContractId);
CREATE INDEX IX_IntegrationLog_Level_CreatedAt ON dbo.IntegrationLog (Level, CreatedAt DESC);
GO

/* ---------- Stored procedures ---------- */

-- 1) Create a contract (idempotent on SharePointItemId)
CREATE OR ALTER PROCEDURE dbo.usp_CreateContract
    @Title            NVARCHAR(200),
    @Counterparty     NVARCHAR(200),
    @ContractType     NVARCHAR(50),
    @ContractValue    DECIMAL(18,2) = NULL,
    @SharePointItemId INT = NULL,
    @SubmittedBy      NVARCHAR(150)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        -- Already created for this SharePoint item? Return it instead of duplicating.
        IF @SharePointItemId IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.Contracts WHERE SharePointItemId = @SharePointItemId)
        BEGIN
            SELECT ContractId, Status, CAST(1 AS BIT) AS AlreadyExisted
            FROM dbo.Contracts WHERE SharePointItemId = @SharePointItemId;
            RETURN;
        END

        BEGIN TRAN;

        INSERT INTO dbo.Contracts (Title, Counterparty, ContractType, ContractValue, SharePointItemId, SubmittedBy)
        VALUES (@Title, @Counterparty, @ContractType, @ContractValue, @SharePointItemId, @SubmittedBy);

        DECLARE @NewId INT = SCOPE_IDENTITY();

        INSERT INTO dbo.ApprovalHistory (ContractId, Action, ActedBy, Comments)
        VALUES (@NewId, 'Submitted', @SubmittedBy, 'Contract submitted');

        COMMIT;

        SELECT ContractId, Status, CAST(0 AS BIT) AS AlreadyExisted
        FROM dbo.Contracts WHERE ContractId = @NewId;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT INTO dbo.IntegrationLog (Source, Endpoint, Level, Message)
        VALUES ('SQL', 'usp_CreateContract', 'ERROR', ERROR_MESSAGE());
        THROW;
    END CATCH
END
GO

-- 2) Record an approval decision (validated, transactional)
CREATE OR ALTER PROCEDURE dbo.usp_RecordDecision
    @ContractId INT,
    @Decision   NVARCHAR(30),          -- 'Approved' or 'Rejected'
    @ActedBy    NVARCHAR(150),
    @Comments   NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @Decision NOT IN ('Approved','Rejected')
            THROW 50001, 'Decision must be Approved or Rejected.', 1;

        DECLARE @CurrentStatus NVARCHAR(30);
        SELECT @CurrentStatus = Status FROM dbo.Contracts WHERE ContractId = @ContractId;

        IF @CurrentStatus IS NULL
            THROW 50002, 'Contract not found.', 1;

        IF @CurrentStatus IN ('Approved','Rejected')
            THROW 50003, 'Contract already has a final decision.', 1;

        BEGIN TRAN;

        UPDATE dbo.Contracts
        SET Status = @Decision, UpdatedAt = SYSUTCDATETIME()
        WHERE ContractId = @ContractId;

        INSERT INTO dbo.ApprovalHistory (ContractId, Action, ActedBy, Comments)
        VALUES (@ContractId, @Decision, @ActedBy, @Comments);

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT INTO dbo.IntegrationLog (Source, Endpoint, Level, Message)
        VALUES ('SQL', 'usp_RecordDecision', 'ERROR', ERROR_MESSAGE());
        THROW;
    END CATCH
END
GO

-- 3) List contracts, optionally by status
CREATE OR ALTER PROCEDURE dbo.usp_GetContracts
    @Status NVARCHAR(30) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT ContractId, Title, Counterparty, ContractType, ContractValue,
           Status, SharePointItemId, SubmittedBy, CreatedAt, UpdatedAt
    FROM dbo.Contracts
    WHERE @Status IS NULL OR Status = @Status
    ORDER BY CreatedAt DESC;
END
GO

-- 4) Write an integration log entry (called by the API)
CREATE OR ALTER PROCEDURE dbo.usp_LogIntegrationEvent
    @Source     NVARCHAR(50),
    @Endpoint   NVARCHAR(200) = NULL,
    @StatusCode INT = NULL,
    @Level      NVARCHAR(10) = 'INFO',
    @Message    NVARCHAR(2000)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.IntegrationLog (Source, Endpoint, StatusCode, Level, Message)
    VALUES (@Source, @Endpoint, @StatusCode, @Level, @Message);
END
GO

/* ---------- Seed + smoke test ---------- */

EXEC dbo.usp_CreateContract
    @Title = 'Vendor NDA - Acme', @Counterparty = 'Acme Ltd', @ContractType = 'NDA',
    @ContractValue = 0, @SharePointItemId = 1, @SubmittedBy = 'nova@example.com';

EXEC dbo.usp_RecordDecision
    @ContractId = 1, @Decision = 'Approved', @ActedBy = 'manager@example.com', @Comments = 'Looks good';

EXEC dbo.usp_GetContracts;
GO

/* ---------- Debugging queries (use these in your README / interview) ---------- */

-- Recent errors in the pipeline
SELECT TOP 20 * FROM dbo.IntegrationLog WHERE Level = 'ERROR' ORDER BY CreatedAt DESC;

-- Contracts stuck in review for more than 2 days
SELECT ContractId, Title, Status, CreatedAt
FROM dbo.Contracts
WHERE Status IN ('Submitted','InReview') AND CreatedAt < DATEADD(DAY, -2, SYSUTCDATETIME());

-- Average time from submission to final decision (hours)
SELECT AVG(DATEDIFF(HOUR, c.CreatedAt, c.UpdatedAt) * 1.0) AS AvgHoursToDecision
FROM dbo.Contracts c
WHERE c.Status IN ('Approved','Rejected');
GO
