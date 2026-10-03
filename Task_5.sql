-- TASK 5: ETL PROCESS DEVELOPMENT

USE WalmartDW;
GO

--SECTION 1: ETL LOG TABLE
   
IF OBJECT_ID('dw.ETL_Log') IS NOT NULL DROP TABLE dw.ETL_Log;

CREATE TABLE dw.ETL_Log (
    LogID        INT IDENTITY(1,1) PRIMARY KEY,
    PipelineRunID UNIQUEIDENTIFIER,
    StepName     VARCHAR(100),
    StartTime    DATETIME2 DEFAULT SYSDATETIME(),
    EndTime      DATETIME2 NULL,
    RowsAffected INT NULL,
    Status       VARCHAR(20) NULL,       -- RUNNING / SUCCESS / FAILED
    Message      VARCHAR(500) NULL
);
GO


-- SECTION 2: EXTRACT
  
IF OBJECT_ID('stg.usp_Extract') IS NOT NULL DROP PROCEDURE stg.usp_Extract;
GO
CREATE PROCEDURE stg.usp_Extract
    @FolderPath VARCHAR(500),        
    @PipelineRunID UNIQUEIDENTIFIER,
    @RowsExtracted INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @sql NVARCHAR(MAX);
    DECLARE @LogID INT;

   
    IF RIGHT(@FolderPath, 1) NOT IN ('\', '/')
        SET @FolderPath = @FolderPath + '\';

    INSERT INTO dw.ETL_Log (PipelineRunID, StepName, Status)
    VALUES (@PipelineRunID, 'EXTRACT', 'RUNNING');
    SET @LogID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;  

        
        IF OBJECT_ID('stg.Train') IS NOT NULL TRUNCATE TABLE stg.Train;
        IF OBJECT_ID('stg.Stores') IS NOT NULL TRUNCATE TABLE stg.Stores;
        IF OBJECT_ID('stg.Features_Raw') IS NOT NULL TRUNCATE TABLE stg.Features_Raw;
        IF OBJECT_ID('stg.Features') IS NOT NULL TRUNCATE TABLE stg.Features;
        IF OBJECT_ID('stg.Holidays') IS NOT NULL TRUNCATE TABLE stg.Holidays;

        -- 2a. Train 
        SET @sql = N'BULK INSERT stg.Train FROM ''' + @FolderPath + N'train.csv''
            WITH (FORMAT=''CSV'', CODEPAGE=''65001'', FIRSTROW=2,
                  FIELDTERMINATOR='','', ROWTERMINATOR=''0x0a'', TABLOCK);';
        EXEC sp_executesql @sql;

        -- 2b. Stores 
        SET @sql = N'BULK INSERT stg.Stores FROM ''' + @FolderPath + N'stores.csv''
            WITH (FORMAT=''CSV'', CODEPAGE=''65001'', FIRSTROW=2,
                  FIELDTERMINATOR='','', ROWTERMINATOR=''0x0d'', TABLOCK);';
        EXEC sp_executesql @sql;

        -- 2c. Features 
        SET @sql = N'BULK INSERT stg.Features_Raw FROM ''' + @FolderPath + N'features.csv''
            WITH (FORMAT=''CSV'', CODEPAGE=''65001'', FIRSTROW=2,
                  FIELDTERMINATOR='','', ROWTERMINATOR=''0x0a'', TABLOCK);';
        EXEC sp_executesql @sql;

        INSERT INTO stg.Features
            (Store, [Date], Temperature, Fuel_Price, MarkDown1, MarkDown2, MarkDown3, MarkDown4, MarkDown5, CPI, Unemployment, IsHoliday)
        SELECT
            TRY_CAST(Store AS INT), TRY_CAST([Date] AS DATE),
            TRY_CAST(NULLIF(Temperature, 'NA') AS DECIMAL(6,2)),
            TRY_CAST(NULLIF(Fuel_Price, 'NA') AS DECIMAL(6,3)),
            TRY_CAST(NULLIF(MarkDown1, 'NA') AS DECIMAL(12,2)),
            TRY_CAST(NULLIF(MarkDown2, 'NA') AS DECIMAL(12,2)),
            TRY_CAST(NULLIF(MarkDown3, 'NA') AS DECIMAL(12,2)),
            TRY_CAST(NULLIF(MarkDown4, 'NA') AS DECIMAL(12,2)),
            TRY_CAST(NULLIF(MarkDown5, 'NA') AS DECIMAL(12,2)),
            TRY_CAST(NULLIF(CPI, 'NA') AS DECIMAL(10,4)),
            TRY_CAST(NULLIF(Unemployment, 'NA') AS DECIMAL(5,3)),
            IsHoliday
        FROM stg.Features_Raw;

        -- 2d. Holidays - all three yearly JSON files, unioned
        DECLARE @json2010 NVARCHAR(MAX), @json2011 NVARCHAR(MAX), @json2012 NVARCHAR(MAX);
        SET @sql = N'SELECT @j = BulkColumn FROM OPENROWSET(BULK ''' + @FolderPath + N'US - 2010.json'', SINGLE_CLOB) AS j;';
        EXEC sp_executesql @sql, N'@j NVARCHAR(MAX) OUTPUT', @j=@json2010 OUTPUT;
        SET @sql = N'SELECT @j = BulkColumn FROM OPENROWSET(BULK ''' + @FolderPath + N'US - 2011.json'', SINGLE_CLOB) AS j;';
        EXEC sp_executesql @sql, N'@j NVARCHAR(MAX) OUTPUT', @j=@json2011 OUTPUT;
        SET @sql = N'SELECT @j = BulkColumn FROM OPENROWSET(BULK ''' + @FolderPath + N'US - 2012.json'', SINGLE_CLOB) AS j;';
        EXEC sp_executesql @sql, N'@j NVARCHAR(MAX) OUTPUT', @j=@json2012 OUTPUT;

        INSERT INTO stg.Holidays (HolidayDate, LocalName, Name, CountryCode, Fixed, Global, Types)
        SELECT CAST([date] AS DATE), localName, name, countryCode, CAST(fixed AS BIT), CAST([global] AS BIT),
               (SELECT STRING_AGG(value, ', ') FROM OPENJSON(types) WITH (value NVARCHAR(50) '$'))
        FROM OPENJSON(@json2010)
        WITH ([date] NVARCHAR(20) '$.date', localName NVARCHAR(100) '$.localName', name NVARCHAR(100) '$.name',
              countryCode NVARCHAR(10) '$.countryCode', fixed NVARCHAR(10) '$.fixed', [global] NVARCHAR(10) '$.global',
              types NVARCHAR(MAX) '$.types' AS JSON)
        UNION ALL
        SELECT CAST([date] AS DATE), localName, name, countryCode, CAST(fixed AS BIT), CAST([global] AS BIT),
               (SELECT STRING_AGG(value, ', ') FROM OPENJSON(types) WITH (value NVARCHAR(50) '$'))
        FROM OPENJSON(@json2011)
        WITH ([date] NVARCHAR(20) '$.date', localName NVARCHAR(100) '$.localName', name NVARCHAR(100) '$.name',
              countryCode NVARCHAR(10) '$.countryCode', fixed NVARCHAR(10) '$.fixed', [global] NVARCHAR(10) '$.global',
              types NVARCHAR(MAX) '$.types' AS JSON)
        UNION ALL
        SELECT CAST([date] AS DATE), localName, name, countryCode, CAST(fixed AS BIT), CAST([global] AS BIT),
               (SELECT STRING_AGG(value, ', ') FROM OPENJSON(types) WITH (value NVARCHAR(50) '$'))
        FROM OPENJSON(@json2012)
        WITH ([date] NVARCHAR(20) '$.date', localName NVARCHAR(100) '$.localName', name NVARCHAR(100) '$.name',
              countryCode NVARCHAR(10) '$.countryCode', fixed NVARCHAR(10) '$.fixed', [global] NVARCHAR(10) '$.global',
              types NVARCHAR(MAX) '$.types' AS JSON);

        COMMIT TRANSACTION;  -- FIX

        SELECT @RowsExtracted =
            (SELECT COUNT(*) FROM stg.Train) + (SELECT COUNT(*) FROM stg.Stores) +
            (SELECT COUNT(*) FROM stg.Features) + (SELECT COUNT(*) FROM stg.Holidays);

        UPDATE dw.ETL_Log SET EndTime = SYSDATETIME(), RowsAffected = @RowsExtracted, Status = 'SUCCESS'
        WHERE LogID = @LogID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;  -- FIX: never log success/failure inside a doomed/open tran
        UPDATE dw.ETL_Log SET EndTime = SYSDATETIME(), Status = 'FAILED', Message = ERROR_MESSAGE()
        WHERE LogID = @LogID;
        THROW;
    END CATCH
END;
GO



-- SECTION 3: TRANSFORM
  
IF OBJECT_ID('stg.usp_Transform') IS NOT NULL DROP PROCEDURE stg.usp_Transform;
GO
CREATE PROCEDURE stg.usp_Transform
    @PipelineRunID UNIQUEIDENTIFIER,
    @RowsTransformed INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @LogID INT;
    INSERT INTO dw.ETL_Log (PipelineRunID, StepName, Status) VALUES (@PipelineRunID, 'TRANSFORM', 'RUNNING');
    SET @LogID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION;  -- FIX: atomic transform

        IF OBJECT_ID('stg.Train_Clean') IS NOT NULL DROP TABLE stg.Train_Clean;
        IF OBJECT_ID('stg.Features_Clean') IS NOT NULL DROP TABLE stg.Features_Clean;
        IF OBJECT_ID('stg.Stores_Clean') IS NOT NULL DROP TABLE stg.Stores_Clean;
        IF OBJECT_ID('stg.Holidays_Clean') IS NOT NULL DROP TABLE stg.Holidays_Clean;
        IF OBJECT_ID('stg.Store_Monthly_Summary') IS NOT NULL DROP TABLE stg.Store_Monthly_Summary;

        -- 3a. Train_Clean
        SELECT
            Store, Dept, [Date] AS SaleDate, Weekly_Sales,
            CASE WHEN UPPER(LTRIM(RTRIM(IsHoliday))) = 'TRUE' THEN 1 ELSE 0 END AS IsHoliday,
            CASE WHEN Weekly_Sales < 0 THEN 1 ELSE 0 END AS IsReturn         -- derived attribute
        INTO stg.Train_Clean
        FROM stg.Train;

        -- 3b. Features_Clean: 
        SELECT
            Store, [Date] AS FeatureDate, Temperature, Fuel_Price,
            ISNULL(MarkDown1, 0) AS MarkDown1, ISNULL(MarkDown2, 0) AS MarkDown2,
            ISNULL(MarkDown3, 0) AS MarkDown3, ISNULL(MarkDown4, 0) AS MarkDown4,
            ISNULL(MarkDown5, 0) AS MarkDown5, CPI, Unemployment,
            CASE WHEN UPPER(LTRIM(RTRIM(IsHoliday))) = 'TRUE' THEN 1 ELSE 0 END AS IsHoliday
        INTO stg.Features_Clean
        FROM stg.Features;

        -- 3c. Stores_Clean: column renaming/standardisation 
        SELECT Store AS StoreID, Type AS StoreType, Size
        INTO stg.Stores_Clean
        FROM stg.Stores;

        -- 3d. Holidays_Clean: duplicate removal 
        WITH RankedHolidays AS (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY HolidayDate ORDER BY Global DESC, Name ASC) AS rn
            FROM stg.Holidays
        )
        SELECT HolidayDate, LocalName, Name AS HolidayName, CountryCode, Fixed, Global, Types AS HolidayType, 1 AS IsHoliday
        INTO stg.Holidays_Clean
        FROM RankedHolidays WHERE rn = 1;

        -- 3e. Aggregation (NEW): 
        SELECT
            Store,
            YEAR(SaleDate) AS SalesYear,
            MONTH(SaleDate) AS SalesMonth,
            SUM(Weekly_Sales) AS TotalMonthlySales,
            AVG(Weekly_Sales) AS AvgWeeklySales,
            COUNT(*) AS RecordCount,
            SUM(CASE WHEN Weekly_Sales < 0 THEN 1 ELSE 0 END) AS ReturnRecordCount
        INTO stg.Store_Monthly_Summary
        FROM stg.Train_Clean
        GROUP BY
            Store,
            YEAR(SaleDate),
            MONTH(SaleDate);

        COMMIT TRANSACTION;  -- FIX

        SELECT @RowsTransformed =
            (SELECT COUNT(*) FROM stg.Train_Clean) + (SELECT COUNT(*) FROM stg.Features_Clean) +
            (SELECT COUNT(*) FROM stg.Stores_Clean) + (SELECT COUNT(*) FROM stg.Holidays_Clean) +
            (SELECT COUNT(*) FROM stg.Store_Monthly_Summary);

        UPDATE dw.ETL_Log SET EndTime = SYSDATETIME(), RowsAffected = @RowsTransformed, Status = 'SUCCESS'
        WHERE LogID = @LogID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;  -- FIX
        UPDATE dw.ETL_Log SET EndTime = SYSDATETIME(), Status = 'FAILED', Message = ERROR_MESSAGE()
        WHERE LogID = @LogID;
        THROW;
    END CATCH
END;
GO


--SECTION 4: LOAD
   
IF OBJECT_ID('dw.usp_Load') IS NOT NULL DROP PROCEDURE dw.usp_Load;
GO
CREATE PROCEDURE dw.usp_Load
    @PipelineRunID UNIQUEIDENTIFIER,
    @RowsLoaded INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @LogID INT;
    INSERT INTO dw.ETL_Log (PipelineRunID, StepName, Status) VALUES (@PipelineRunID, 'LOAD', 'RUNNING');
    SET @LogID = SCOPE_IDENTITY();

    BEGIN TRY
        BEGIN TRANSACTION; 
        DELETE FROM dw.FactSales;
        DELETE FROM dw.DimDate;
        DELETE FROM dw.DimStore;
        DELETE FROM dw.DimDepartment;
        DBCC CHECKIDENT ('dw.DimStore', RESEED, 0);
        DBCC CHECKIDENT ('dw.DimDepartment', RESEED, 0);
        DBCC CHECKIDENT ('dw.FactSales', RESEED, 0);

        -- 4a. DimDate (loaded first - independent of the other dims)
        ;WITH DistinctDates AS (SELECT DISTINCT SaleDate FROM stg.Train_Clean)
        INSERT INTO dw.DimDate
            (DateKey, FullDate, DayOfWeekName, DayOfMonth, WeekOfYear, MonthNumber, MonthName, Quarter, [Year], IsPublicHoliday, HolidayName, HolidayType)
        SELECT
            CONVERT(INT, FORMAT(d.SaleDate, 'yyyyMMdd')), d.SaleDate,
            DATENAME(WEEKDAY, d.SaleDate), DATEPART(DAY, d.SaleDate), DATEPART(WEEK, d.SaleDate),
            DATEPART(MONTH, d.SaleDate), DATENAME(MONTH, d.SaleDate), DATEPART(QUARTER, d.SaleDate), DATEPART(YEAR, d.SaleDate),
            CASE WHEN h.HolidayDate IS NOT NULL THEN 1 ELSE 0 END, h.HolidayName, h.HolidayType
        FROM DistinctDates d
        LEFT JOIN stg.Holidays_Clean h ON d.SaleDate = h.HolidayDate;

        -- 4b. DimStore (derived attribute: SizeCategory)
        INSERT INTO dw.DimStore (StoreID, StoreType, StoreSize, SizeCategory)
        SELECT StoreID, StoreType, Size,
            CASE WHEN Size < 50000 THEN 'Small' WHEN Size < 150000 THEN 'Medium' ELSE 'Large' END
        FROM stg.Stores_Clean;

        -- 4c. DimDepartment (derived attribute: DeptName)
        INSERT INTO dw.DimDepartment (DeptID, DeptName)
        SELECT DISTINCT Dept, CONCAT('Department ', Dept) FROM stg.Train_Clean;

        -- 4d. FactSales (loaded last - depends on all three dims above)
        DECLARE @UnmatchedRows INT;
        SELECT @UnmatchedRows = COUNT(*)
        FROM stg.Train_Clean t
        LEFT JOIN dw.DimDate dd       ON t.SaleDate = dd.FullDate
        LEFT JOIN dw.DimStore ds      ON t.Store    = ds.StoreID
        LEFT JOIN dw.DimDepartment dp ON t.Dept     = dp.DeptID
        WHERE dd.DateKey IS NULL OR ds.StoreKey IS NULL OR dp.DeptKey IS NULL;

        IF @UnmatchedRows > 0
        BEGIN
            DECLARE @ErrMsg NVARCHAR(400) = CONCAT(
                @UnmatchedRows,
                ' row(s) in stg.Train_Clean have no matching DimDate/DimStore/',
                'DimDepartment record - aborting load to avoid silently losing them.');
            RAISERROR(@ErrMsg, 16, 1);
        END;

        INSERT INTO dw.FactSales
            (DateKey, StoreKey, DeptKey, Weekly_Sales, MarkDown1, MarkDown2, MarkDown3, MarkDown4, MarkDown5,
             Temperature, Fuel_Price, CPI, Unemployment, IsHolidayWeek)
        SELECT
            dd.DateKey, ds.StoreKey, dp.DeptKey, t.Weekly_Sales,
            f.MarkDown1, f.MarkDown2, f.MarkDown3, f.MarkDown4, f.MarkDown5,
            f.Temperature, f.Fuel_Price, f.CPI, f.Unemployment, t.IsHoliday
        FROM stg.Train_Clean t
        JOIN dw.DimDate dd        ON t.SaleDate = dd.FullDate
        JOIN dw.DimStore ds       ON t.Store    = ds.StoreID
        JOIN dw.DimDepartment dp  ON t.Dept     = dp.DeptID
        LEFT JOIN stg.Features_Clean f ON t.Store = f.Store AND t.SaleDate = f.FeatureDate;

        COMMIT TRANSACTION;  -- FIX

        SELECT @RowsLoaded =
            (SELECT COUNT(*) FROM dw.DimDate) + (SELECT COUNT(*) FROM dw.DimStore) +
            (SELECT COUNT(*) FROM dw.DimDepartment) + (SELECT COUNT(*) FROM dw.FactSales);

        UPDATE dw.ETL_Log SET EndTime = SYSDATETIME(), RowsAffected = @RowsLoaded, Status = 'SUCCESS'
        WHERE LogID = @LogID;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;  -- FIX
        UPDATE dw.ETL_Log SET EndTime = SYSDATETIME(), Status = 'FAILED', Message = ERROR_MESSAGE()
        WHERE LogID = @LogID;
        THROW;
    END CATCH
END;
GO


--SECTION 5: MASTER ORCHESTRATION PROCEDURE
   
IF OBJECT_ID('dw.usp_RunFullETL') IS NOT NULL DROP PROCEDURE dw.usp_RunFullETL;
GO
CREATE PROCEDURE dw.usp_RunFullETL
    @FolderPath VARCHAR(500)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @PipelineRunID UNIQUEIDENTIFIER = NEWID();
    DECLARE @RowsExtracted INT, @RowsTransformed INT, @RowsLoaded INT;

    PRINT 'Starting ETL pipeline run: ' + CAST(@PipelineRunID AS VARCHAR(50));

    EXEC stg.usp_Extract @FolderPath = @FolderPath, @PipelineRunID = @PipelineRunID, @RowsExtracted = @RowsExtracted OUTPUT;
    PRINT 'Extract complete. Rows: ' + CAST(@RowsExtracted AS VARCHAR(20));

    EXEC stg.usp_Transform @PipelineRunID = @PipelineRunID, @RowsTransformed = @RowsTransformed OUTPUT;
    PRINT 'Transform complete. Rows: ' + CAST(@RowsTransformed AS VARCHAR(20));

    EXEC dw.usp_Load @PipelineRunID = @PipelineRunID, @RowsLoaded = @RowsLoaded OUTPUT;
    PRINT 'Load complete. Rows: ' + CAST(@RowsLoaded AS VARCHAR(20));

    PRINT 'Pipeline run finished: ' + CAST(@PipelineRunID AS VARCHAR(50));
    SELECT @PipelineRunID AS PipelineRunID;
END;
GO



-- SECTION 6: EXECUTE THE PIPELINE
   
EXEC dw.usp_RunFullETL @FolderPath = 'C:\Users\MSI\Desktop\Academic\3rd year\1st sem\DWBI\Assignment\Datasets';
GO



--SECTION 7: VALIDATION
 
-- 7a. The pipeline's own log - proves the workflow and sequence
DECLARE @LatestRun UNIQUEIDENTIFIER =
    (SELECT TOP 1 PipelineRunID FROM dw.ETL_Log ORDER BY LogID DESC);

SELECT PipelineRunID, StepName, StartTime, EndTime,
       DATEDIFF(SECOND, StartTime, EndTime) AS DurationSeconds,
       RowsAffected, Status
FROM dw.ETL_Log
WHERE PipelineRunID = @LatestRun
ORDER BY LogID;

-- 7a-ii. Full history across every run, for reference (optional)
SELECT PipelineRunID, StepName, StartTime, EndTime,
       DATEDIFF(SECOND, StartTime, EndTime) AS DurationSeconds,
       RowsAffected, Status
FROM dw.ETL_Log
ORDER BY LogID;

-- 7b. Row counts across the whole chain: raw staging -> cleaned -> star schema
SELECT 'stg.Train (raw)' AS TableName, COUNT(*) AS Rows FROM stg.Train
UNION ALL SELECT 'stg.Train_Clean', COUNT(*) FROM stg.Train_Clean
UNION ALL SELECT 'dw.FactSales', COUNT(*) FROM dw.FactSales
UNION ALL SELECT 'dw.DimDate', COUNT(*) FROM dw.DimDate
UNION ALL SELECT 'dw.DimStore', COUNT(*) FROM dw.DimStore
UNION ALL SELECT 'dw.DimDepartment', COUNT(*) FROM dw.DimDepartment
UNION ALL SELECT 'stg.Store_Monthly_Summary', COUNT(*) FROM stg.Store_Monthly_Summary;
-- Expected: 421,570 | 421,570 | 421,570 | 143 | 45 | 81 | (45 stores x up to 33 months)

-- 7c. Source-to-fact row match (no rows silently lost across the whole pipeline)
SELECT
    (SELECT COUNT(*) FROM stg.Train) AS RawExtracted,
    (SELECT COUNT(*) FROM dw.FactSales) AS FinalLoaded,
    CASE WHEN (SELECT COUNT(*) FROM stg.Train) = (SELECT COUNT(*) FROM dw.FactSales)
         THEN 'MATCH' ELSE 'MISMATCH - investigate' END AS Result;

-- 7d. Confirm the new derived attribute (IsReturn) is populated correctly
SELECT IsReturn, COUNT(*) AS RecordCount FROM stg.Train_Clean GROUP BY IsReturn;
-- Expected: IsReturn=1 for 1,285 rows (matches Task 2's negative-sales finding)

-- 7e. Confirm the new aggregation table looks sensible
SELECT TOP 5 * FROM stg.Store_Monthly_Summary ORDER BY Store, SalesYear, SalesMonth;
SELECT SUM(TotalMonthlySales) AS GrandTotal FROM stg.Store_Monthly_Summary;
-- Should equal SUM(Weekly_Sales) from dw.FactSales (7f below) - proves the
-- aggregation didn't lose or double-count any sales value

SELECT SUM(Weekly_Sales) AS FactTotal FROM dw.FactSales;

-- 7f. Grain and referential checks carried over from Task 4 (re-verify
-- after this pipeline's DELETE/reload, since a full re-run is the point)
SELECT DateKey, StoreKey, DeptKey, COUNT(*) AS RecordCount
FROM dw.FactSales GROUP BY DateKey, StoreKey, DeptKey HAVING COUNT(*) > 1;
-- Expected: 0 rows
