--TASK 4 - DIMENSIONAL DATA WAREHOUSE DESIGN & IMPLEMENTATION
  
--Grain: each row in FactSales represents the total sales of one department, in one store, for one specific week.

USE WalmartDW;
GO

CREATE SCHEMA dw;
GO

-- SECTION 1: DIMENSION AND FACT TABLE DDL

-- DimDate
CREATE TABLE dw.DimDate (
    DateKey         INT PRIMARY KEY,        -- format YYYYMMDD
    FullDate        DATE NOT NULL UNIQUE,
    DayOfWeekName   VARCHAR(10),            
    DayOfMonth      INT,
    WeekOfYear      INT,
    MonthNumber     INT,
    MonthName       VARCHAR(10),
    Quarter         INT,
    [Year]          INT,
    IsPublicHoliday BIT NOT NULL DEFAULT 0, 
    HolidayName     VARCHAR(100) NULL,
    HolidayType     VARCHAR(50)  NULL
);
GO

-- DimStore
CREATE TABLE dw.DimStore (
    StoreKey     INT IDENTITY(1,1) PRIMARY KEY,
    StoreID      INT NOT NULL UNIQUE,
    StoreType    CHAR(1),
    StoreSize    INT,
    SizeCategory VARCHAR(10)
);
GO

-- DimDepartment
CREATE TABLE dw.DimDepartment (
    DeptKey  INT IDENTITY(1,1) PRIMARY KEY,
    DeptID   INT NOT NULL UNIQUE,
    DeptName VARCHAR(50)
);
GO

-- FactSales
CREATE TABLE dw.FactSales (
    SalesKey      BIGINT IDENTITY(1,1) PRIMARY KEY,
    DateKey       INT NOT NULL REFERENCES dw.DimDate(DateKey),
    StoreKey      INT NOT NULL REFERENCES dw.DimStore(StoreKey),
    DeptKey       INT NOT NULL REFERENCES dw.DimDepartment(DeptKey),
    Weekly_Sales  DECIMAL(12,2) NOT NULL,
    MarkDown1     DECIMAL(12,2) NULL,
    MarkDown2     DECIMAL(12,2) NULL,
    MarkDown3     DECIMAL(12,2) NULL,
    MarkDown4     DECIMAL(12,2) NULL,
    MarkDown5     DECIMAL(12,2) NULL,
    Temperature   DECIMAL(6,2)  NULL,
    Fuel_Price    DECIMAL(6,3)  NULL,
    CPI           DECIMAL(10,4) NULL,
    Unemployment  DECIMAL(5,3)  NULL,
    IsHolidayWeek BIT NOT NULL             
);
GO


-- SECTION 2: DIMENSION POPULATION

-- DimDate
;WITH DistinctDates AS (
    SELECT DISTINCT SaleDate FROM stg.Train_Clean
)
INSERT INTO dw.DimDate
    (DateKey, FullDate, DayOfWeekName, DayOfMonth, WeekOfYear, MonthNumber, MonthName, Quarter, [Year], IsPublicHoliday, HolidayName, HolidayType)
SELECT
    CONVERT(INT, FORMAT(d.SaleDate, 'yyyyMMdd')),
    d.SaleDate,
    DATENAME(WEEKDAY, d.SaleDate),
    DATEPART(DAY, d.SaleDate),
    DATEPART(WEEK, d.SaleDate),
    DATEPART(MONTH, d.SaleDate),
    DATENAME(MONTH, d.SaleDate),
    DATEPART(QUARTER, d.SaleDate),
    DATEPART(YEAR, d.SaleDate),
    CASE WHEN h.HolidayDate IS NOT NULL THEN 1 ELSE 0 END,
    h.HolidayName,
    h.HolidayType
FROM DistinctDates d
LEFT JOIN stg.Holidays_Clean h ON d.SaleDate = h.HolidayDate;
GO

-- DimStore
INSERT INTO dw.DimStore (StoreID, StoreType, StoreSize, SizeCategory)
SELECT
    StoreID,
    StoreType,
    Size,
    CASE
        WHEN Size < 50000  THEN 'Small'
        WHEN Size < 150000 THEN 'Medium'
        ELSE 'Large'
    END
FROM stg.Stores_Clean;
GO

-- DimDepartment
INSERT INTO dw.DimDepartment (DeptID, DeptName)
SELECT DISTINCT Dept, CONCAT('Department ', Dept)
FROM stg.Train_Clean;
GO


-- SECTION 3: FACT TABLE POPULATION

INSERT INTO dw.FactSales
    (DateKey, StoreKey, DeptKey, Weekly_Sales, MarkDown1, MarkDown2, MarkDown3, MarkDown4, MarkDown5,
     Temperature, Fuel_Price, CPI, Unemployment, IsHolidayWeek)
SELECT
    dd.DateKey,
    ds.StoreKey,
    dp.DeptKey,
    t.Weekly_Sales,
    f.MarkDown1, f.MarkDown2, f.MarkDown3, f.MarkDown4, f.MarkDown5,
    f.Temperature, f.Fuel_Price, f.CPI, f.Unemployment,
    t.IsHoliday
FROM stg.Train_Clean t
JOIN dw.DimDate dd        ON t.SaleDate = dd.FullDate
JOIN dw.DimStore ds       ON t.Store    = ds.StoreID
JOIN dw.DimDepartment dp  ON t.Dept     = dp.DeptID
LEFT JOIN stg.Features_Clean f ON t.Store = f.Store AND t.SaleDate = f.FeatureDate;
GO


-- SECTION 4: VALIDATION

-- Row counts
SELECT 'DimDate'       AS TableName, COUNT(*) AS Rows FROM dw.DimDate
UNION ALL
SELECT 'DimStore',      COUNT(*) FROM dw.DimStore
UNION ALL
SELECT 'DimDepartment', COUNT(*) FROM dw.DimDepartment
UNION ALL
SELECT 'FactSales',     COUNT(*) FROM dw.FactSales;
-- Expected: DimDate 143 | DimStore 45 | DimDepartment 81 | FactSales 421,570

-- Confirm no rows were silently lost in the fact load
SELECT
    (SELECT COUNT(*) FROM stg.Train_Clean) AS SourceRows,
    (SELECT COUNT(*) FROM dw.FactSales)    AS FactRows,
    CASE WHEN (SELECT COUNT(*) FROM stg.Train_Clean) = (SELECT COUNT(*) FROM dw.FactSales)
         THEN 'MATCH' ELSE 'MISMATCH - investigate' END AS Result;

-- Confirm additive measure totals correctly
SELECT SUM(Weekly_Sales) AS TotalSales, COUNT(*) AS RecordCount
FROM dw.FactSales;

-- Confirm negative sales (returns) were preserved, not dropped
SELECT COUNT(*) AS NegativeSalesInFact
FROM dw.FactSales
WHERE Weekly_Sales < 0;
-- Expected: 1,285

-- Confirm the two holiday signals really do differ (documents the

SELECT
    (SELECT COUNT(*) FROM dw.DimDate WHERE IsPublicHoliday = 1)         AS CivicHolidayDates,      -- expect 7
    (SELECT COUNT(DISTINCT DateKey) FROM dw.FactSales WHERE IsHolidayWeek = 1) AS KaggleHolidayDates; -- expect 10

-- Sample query using the CIVIC holiday flag (DimDate) - exact dates only
SELECT TOP 10
    dd.FullDate, dd.[Year], dd.MonthName, dd.IsPublicHoliday, dd.HolidayName,
    ds.StoreID, ds.StoreType, ds.SizeCategory,
    dp.DeptID,
    f.Weekly_Sales
FROM dw.FactSales f
JOIN dw.DimDate dd       ON f.DateKey = dd.DateKey
JOIN dw.DimStore ds      ON f.StoreKey = ds.StoreKey
JOIN dw.DimDepartment dp ON f.DeptKey = dp.DeptKey
WHERE dd.IsPublicHoliday = 1
ORDER BY dd.FullDate;

-- Sample query using KAGGLE's holiday-WEEK flag (FactSales) - different dates
SELECT TOP 10
    dd.FullDate, dd.[Year], dd.MonthName,
    ds.StoreID, ds.StoreType,
    dp.DeptID,
    f.Weekly_Sales, f.IsHolidayWeek
FROM dw.FactSales f
JOIN dw.DimDate dd       ON f.DateKey = dd.DateKey
JOIN dw.DimStore ds      ON f.StoreKey = ds.StoreKey
JOIN dw.DimDepartment dp ON f.DeptKey = dp.DeptKey
WHERE f.IsHolidayWeek = 1
ORDER BY dd.FullDate;

-- Check star schema relationships (foreign keys)
SELECT
    fk.name AS ForeignKeyName,
    OBJECT_NAME(fk.parent_object_id) AS FactTable,
    OBJECT_NAME(fk.referenced_object_id) AS DimensionTable
FROM sys.foreign_keys fk
WHERE fk.parent_object_id = OBJECT_ID('dw.FactSales');

-- Check the grain (expect 0 rows - no duplicate store+dept+week combinations)
SELECT
    DateKey, StoreKey, DeptKey,
    COUNT(*) AS RecordCount
FROM dw.FactSales
GROUP BY DateKey, StoreKey, DeptKey
HAVING COUNT(*) > 1;
GO
