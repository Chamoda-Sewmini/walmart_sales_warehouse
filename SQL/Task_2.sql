--TASK 2 - DATA SOURCE IDENTIFICATION & PREPARATION
 
-- SECTION 0: DATABASE & SCHEMA
CREATE DATABASE WalmartDW;
GO                                  

USE WalmartDW;
GO

CREATE SCHEMA stg;
GO                                  


-- SECTION 1: STAGING TABLES
-- 1a. Train (sales fact source)
CREATE TABLE stg.Train (
    Store        INT,
    Dept         INT,
    [Date]       DATE,
    Weekly_Sales DECIMAL(12,2),
    IsHoliday    VARCHAR(10)
);
GO

-- 1b. Stores (dimension source)
CREATE TABLE stg.Stores (
    Store INT,
    Type  CHAR(1),
    Size  INT
);
GO

-- 1c. Features_Raw - ALL-VARCHAR landing table.
CREATE TABLE stg.Features_Raw (
    Store        VARCHAR(10),
    [Date]       VARCHAR(20),
    Temperature  VARCHAR(20),
    Fuel_Price   VARCHAR(20),
    MarkDown1    VARCHAR(20),
    MarkDown2    VARCHAR(20),
    MarkDown3    VARCHAR(20),
    MarkDown4    VARCHAR(20),
    MarkDown5    VARCHAR(20),
    CPI          VARCHAR(20),
    Unemployment VARCHAR(20),
    IsHoliday    VARCHAR(10)
);
GO

-- 1d. Features - final typed table, populated from Features_Raw
CREATE TABLE stg.Features (
    Store        INT,
    [Date]       DATE,
    Temperature  DECIMAL(6,2),
    Fuel_Price   DECIMAL(6,3),
    MarkDown1    DECIMAL(12,2) NULL,
    MarkDown2    DECIMAL(12,2) NULL,
    MarkDown3    DECIMAL(12,2) NULL,
    MarkDown4    DECIMAL(12,2) NULL,
    MarkDown5    DECIMAL(12,2) NULL,
    CPI          DECIMAL(10,4) NULL,
    Unemployment DECIMAL(5,3) NULL,
    IsHoliday    VARCHAR(10)
);
GO

-- 1e. Holidays - raw shredded JSON
CREATE TABLE stg.Holidays (
    HolidayDate  DATE,
    LocalName    NVARCHAR(100),
    Name         NVARCHAR(100),
    CountryCode  CHAR(2),
    Fixed        BIT,
    Global       BIT,
    Types        NVARCHAR(100)
);
GO


-- SECTION 2: DATA LOADING
-- 2a. Train (expect 421,570 rows)
BULK INSERT stg.Train
FROM 'C:\Users\MSI\Desktop\Academic\3rd year\1st sem\DWBI\Assignment\Datasets\train.csv'
WITH (
    FORMAT = 'CSV',
    CODEPAGE = '65001',
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    TABLOCK
);
GO

-- 2b.Stores (expect 45 rows) 
BULK INSERT stg.Stores
FROM 'C:\Users\MSI\Desktop\Academic\3rd year\1st sem\DWBI\Assignment\Datasets\stores.csv'
WITH (
    FORMAT = 'CSV',
    CODEPAGE = '65001',
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0d',
    TABLOCK
);
GO

-- 2c. Features - load as text first (expect 8,190 rows)
BULK INSERT stg.Features_Raw
FROM 'C:\Users\MSI\Desktop\Academic\3rd year\1st sem\DWBI\Assignment\Datasets\features.csv'
WITH (
    FORMAT = 'CSV',
    CODEPAGE = '65001',
    FIRSTROW = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR = '0x0a',
    TABLOCK
);
GO

-- then convert, turning the literal "NA" text into a real NULL
INSERT INTO stg.Features
    (Store, [Date], Temperature, Fuel_Price, MarkDown1, MarkDown2, MarkDown3, MarkDown4, MarkDown5, CPI, Unemployment, IsHoliday)
SELECT
    TRY_CAST(Store AS INT),
    TRY_CAST([Date] AS DATE),
    TRY_CAST(NULLIF(Temperature, 'NA')  AS DECIMAL(6,2)),
    TRY_CAST(NULLIF(Fuel_Price, 'NA')   AS DECIMAL(6,3)),
    TRY_CAST(NULLIF(MarkDown1, 'NA')    AS DECIMAL(12,2)),
    TRY_CAST(NULLIF(MarkDown2, 'NA')    AS DECIMAL(12,2)),
    TRY_CAST(NULLIF(MarkDown3, 'NA')    AS DECIMAL(12,2)),
    TRY_CAST(NULLIF(MarkDown4, 'NA')    AS DECIMAL(12,2)),
    TRY_CAST(NULLIF(MarkDown5, 'NA')    AS DECIMAL(12,2)),
    TRY_CAST(NULLIF(CPI, 'NA')          AS DECIMAL(10,4)),
    TRY_CAST(NULLIF(Unemployment, 'NA') AS DECIMAL(5,3)),
    IsHoliday
FROM stg.Features_Raw;
GO

-- 2d. Holidays - all THREE yearly files (expect 48 rows combined:
--     16 for 2010, 16 for 2011, 16 for 2012). Loading only one file
DECLARE @json2010 NVARCHAR(MAX), @json2011 NVARCHAR(MAX), @json2012 NVARCHAR(MAX);

SELECT @json2010 = BulkColumn FROM OPENROWSET(BULK 'C:\Users\MSI\Desktop\Academic\3rd year\1st sem\DWBI\Assignment\Datasets\US - 2010.json', SINGLE_CLOB) AS j;
SELECT @json2011 = BulkColumn FROM OPENROWSET(BULK 'C:\Users\MSI\Desktop\Academic\3rd year\1st sem\DWBI\Assignment\Datasets\US - 2011.json', SINGLE_CLOB) AS j;
SELECT @json2012 = BulkColumn FROM OPENROWSET(BULK 'C:\Users\MSI\Desktop\Academic\3rd year\1st sem\DWBI\Assignment\Datasets\US - 2012.json', SINGLE_CLOB) AS j;

INSERT INTO stg.Holidays (HolidayDate, LocalName, Name, CountryCode, Fixed, Global, Types)
SELECT
    CAST([date] AS DATE), localName, name, countryCode,
    CAST(fixed AS BIT), CAST([global] AS BIT),
    (SELECT STRING_AGG(value, ', ') FROM OPENJSON(types) WITH (value NVARCHAR(50) '$'))
FROM OPENJSON(@json2010)
WITH (
    [date] NVARCHAR(20) '$.date', localName NVARCHAR(100) '$.localName',
    name NVARCHAR(100) '$.name', countryCode NVARCHAR(10) '$.countryCode',
    fixed NVARCHAR(10) '$.fixed', [global] NVARCHAR(10) '$.global',
    types NVARCHAR(MAX) '$.types' AS JSON
)
UNION ALL
SELECT
    CAST([date] AS DATE), localName, name, countryCode,
    CAST(fixed AS BIT), CAST([global] AS BIT),
    (SELECT STRING_AGG(value, ', ') FROM OPENJSON(types) WITH (value NVARCHAR(50) '$'))
FROM OPENJSON(@json2011)
WITH (
    [date] NVARCHAR(20) '$.date', localName NVARCHAR(100) '$.localName',
    name NVARCHAR(100) '$.name', countryCode NVARCHAR(10) '$.countryCode',
    fixed NVARCHAR(10) '$.fixed', [global] NVARCHAR(10) '$.global',
    types NVARCHAR(MAX) '$.types' AS JSON
)
UNION ALL
SELECT
    CAST([date] AS DATE), localName, name, countryCode,
    CAST(fixed AS BIT), CAST([global] AS BIT),
    (SELECT STRING_AGG(value, ', ') FROM OPENJSON(types) WITH (value NVARCHAR(50) '$'))
FROM OPENJSON(@json2012)
WITH (
    [date] NVARCHAR(20) '$.date', localName NVARCHAR(100) '$.localName',
    name NVARCHAR(100) '$.name', countryCode NVARCHAR(10) '$.countryCode',
    fixed NVARCHAR(10) '$.fixed', [global] NVARCHAR(10) '$.global',
    types NVARCHAR(MAX) '$.types' AS JSON
);
GO


-- SECTION 3: LOAD VALIDATION
SELECT 'Train'    AS TableName, COUNT(*) AS TotalRows FROM stg.Train      -- expect 421,570
UNION ALL
SELECT 'Features', COUNT(*) FROM stg.Features                              -- expect 8,190
UNION ALL
SELECT 'Stores',   COUNT(*) FROM stg.Stores                                -- expect 45
UNION ALL
SELECT 'Holidays', COUNT(*) FROM stg.Holidays;                             -- expect 48 
GO


-- SECTION 4: DATA QUALITY CHECKS

-- Train: missing values
SELECT
    SUM(CASE WHEN Store IS NULL THEN 1 ELSE 0 END)        AS Missing_Store,
    SUM(CASE WHEN Dept IS NULL THEN 1 ELSE 0 END)         AS Missing_Dept,
    SUM(CASE WHEN [Date] IS NULL THEN 1 ELSE 0 END)       AS Missing_Date,
    SUM(CASE WHEN Weekly_Sales IS NULL THEN 1 ELSE 0 END) AS Missing_Sales,
    SUM(CASE WHEN IsHoliday IS NULL THEN 1 ELSE 0 END)    AS Missing_IsHoliday
FROM stg.Train;

-- Features: missing values (MarkDown/CPI/Unemployment NULLs are expected and meaningful here, not an error)
SELECT
    SUM(CASE WHEN Temperature IS NULL THEN 1 ELSE 0 END)  AS Missing_Temp,
    SUM(CASE WHEN Fuel_Price IS NULL THEN 1 ELSE 0 END)   AS Missing_Fuel,
    SUM(CASE WHEN CPI IS NULL THEN 1 ELSE 0 END)          AS Missing_CPI,          -- expect 585
    SUM(CASE WHEN Unemployment IS NULL THEN 1 ELSE 0 END) AS Missing_Unemp,        -- expect 585
    SUM(CASE WHEN MarkDown1 IS NULL THEN 1 ELSE 0 END)    AS Missing_MD1,          -- expect 4,158
    SUM(CASE WHEN MarkDown2 IS NULL THEN 1 ELSE 0 END)    AS Missing_MD2,          -- expect 5,269
    SUM(CASE WHEN MarkDown3 IS NULL THEN 1 ELSE 0 END)    AS Missing_MD3,          -- expect 4,577
    SUM(CASE WHEN MarkDown4 IS NULL THEN 1 ELSE 0 END)    AS Missing_MD4,          -- expect 4,726
    SUM(CASE WHEN MarkDown5 IS NULL THEN 1 ELSE 0 END)    AS Missing_MD5           -- expect 4,140
FROM stg.Features;

-- Train duplicates on its natural key (expect 0 rows)
SELECT Store, Dept, [Date], COUNT(*) AS DuplicateCount
FROM stg.Train
GROUP BY Store, Dept, [Date]
HAVING COUNT(*) > 1;

-- Features duplicates on its natural key (expect 0 rows)
SELECT Store, [Date], COUNT(*) AS DuplicateCount
FROM stg.Features
GROUP BY Store, [Date]
HAVING COUNT(*) > 1;

-- Holidays duplicates on date (EXPECT 3 dates with 2-3 rows )
SELECT HolidayDate, COUNT(*) AS RecordsForThisDate
FROM stg.Holidays
GROUP BY HolidayDate
HAVING COUNT(*) > 1;

-- Negative sales (real returns in the source data, expect 1,285 -
-- these are flagged, not deleted, since they are valid records)
SELECT COUNT(*) AS NegativeSales FROM stg.Train WHERE Weekly_Sales < 0;

-- Date ranges
SELECT MIN([Date]) AS MinDate, MAX([Date]) AS MaxDate FROM stg.Train;       -- 2010-02-05 to 2012-10-26
SELECT MIN([Date]) AS MinDate, MAX([Date]) AS MaxDate FROM stg.Features;    -- 2010-02-05 to 2013-07-26
SELECT MIN(HolidayDate) AS MinDate, MAX(HolidayDate) AS MaxDate FROM stg.Holidays;

-- IsHoliday distribution
SELECT IsHoliday, COUNT(*) AS Count FROM stg.Train GROUP BY IsHoliday;
SELECT IsHoliday, COUNT(*) AS Count FROM stg.Features GROUP BY IsHoliday;

-- Store Type distribution (expect only A, B, C)
SELECT DISTINCT Type FROM stg.Stores;
GO


-- SECTION 5: REFERENTIAL INTEGRITY CHECKS

-- Every Store in Train must exist in Stores (expect 0 rows)
SELECT DISTINCT t.Store
FROM stg.Train t
LEFT JOIN stg.Stores s ON t.Store = s.Store
WHERE s.Store IS NULL;

-- Every Store in Features must exist in Stores (expect 0 rows)
SELECT DISTINCT f.Store
FROM stg.Features f
LEFT JOIN stg.Stores s ON f.Store = s.Store
WHERE s.Store IS NULL;

-- Every (Store, Date) in Train should have a matching Features row (expect 0 rows)
SELECT DISTINCT t.Store, t.[Date]
FROM stg.Train t
LEFT JOIN stg.Features f ON t.Store = f.Store AND t.[Date] = f.[Date]
WHERE f.Store IS NULL;

-- Which Train.IsHoliday = TRUE dates map to a named holiday
SELECT DISTINCT t.[Date], h.Name
FROM stg.Train t
LEFT JOIN stg.Holidays h ON t.[Date] = h.HolidayDate
WHERE UPPER(LTRIM(RTRIM(t.IsHoliday))) = 'TRUE'
ORDER BY t.[Date];
GO


-- SECTION 6: CLEANED TABLES 

-- 6a. Train_Clean
IF OBJECT_ID('stg.Train_Clean') IS NOT NULL DROP TABLE stg.Train_Clean;

SELECT
    Store,
    Dept,
    [Date] AS SaleDate,
    Weekly_Sales,
    CASE WHEN UPPER(LTRIM(RTRIM(IsHoliday))) = 'TRUE' THEN 1 ELSE 0 END AS IsHoliday
INTO stg.Train_Clean
FROM stg.Train;

-- 6b. Features_Clean - MarkDown NULLs genuinely mean "no promotion active"   
IF OBJECT_ID('stg.Features_Clean') IS NOT NULL DROP TABLE stg.Features_Clean;

SELECT
    Store,
    [Date] AS FeatureDate,
    Temperature,
    Fuel_Price,
    ISNULL(MarkDown1, 0) AS MarkDown1,
    ISNULL(MarkDown2, 0) AS MarkDown2,
    ISNULL(MarkDown3, 0) AS MarkDown3,
    ISNULL(MarkDown4, 0) AS MarkDown4,
    ISNULL(MarkDown5, 0) AS MarkDown5,
    CPI,
    Unemployment,
    CASE WHEN UPPER(LTRIM(RTRIM(IsHoliday))) = 'TRUE' THEN 1 ELSE 0 END AS IsHoliday
INTO stg.Features_Clean
FROM stg.Features;

-- 6c. Stores_Clean
IF OBJECT_ID('stg.Stores_Clean') IS NOT NULL DROP TABLE stg.Stores_Clean;

SELECT
    Store AS StoreID,
    Type  AS StoreType,
    Size
INTO stg.Stores_Clean
FROM stg.Stores;

-- 6d. Holidays_Clean - DEDUPLICATED to one row per date.
IF OBJECT_ID('stg.Holidays_Clean') IS NOT NULL DROP TABLE stg.Holidays_Clean;

WITH RankedHolidays AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY HolidayDate
               ORDER BY Global DESC, Name ASC
           ) AS rn
    FROM stg.Holidays
)
SELECT
    HolidayDate,
    LocalName,
    Name AS HolidayName,
    CountryCode,
    Fixed,
    Global,
    Types AS HolidayType,
    1 AS IsHoliday
INTO stg.Holidays_Clean
FROM RankedHolidays
WHERE rn = 1;
GO


-- SECTION 7: FINAL VALIDATION
SELECT 'Train_Clean'    AS TableName, COUNT(*) AS Rows FROM stg.Train_Clean       -- expect 421,570
UNION ALL
SELECT 'Features_Clean', COUNT(*) FROM stg.Features_Clean                          -- expect 8,190
UNION ALL
SELECT 'Stores_Clean',   COUNT(*) FROM stg.Stores_Clean                            -- expect 45
UNION ALL
SELECT 'Holidays_Clean', COUNT(*) FROM stg.Holidays_Clean;                         -- expect 39 
GO