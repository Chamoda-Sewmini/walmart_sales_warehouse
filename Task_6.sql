USE WalmartDW;
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'mart')
    EXEC('CREATE SCHEMA mart');
GO



-- PART A: CHAIN-WIDE SALES MART (all departments)

-- A1. mart.FactSalesPerformance - flattened, report-ready fact table
IF OBJECT_ID('mart.FactSalesPerformance') IS NOT NULL DROP TABLE mart.FactSalesPerformance;
GO

SELECT
    f.SalesKey,
    dd.FullDate                                  AS SaleDate,
    dd.[Year],
    dd.MonthName,
    dd.MonthNumber,
    dd.Quarter,
    dd.WeekOfYear,
    dd.IsPublicHoliday,
    dd.HolidayName,
    ds.StoreID,
    ds.StoreType,
    ds.StoreSize,
    ds.SizeCategory,
    dp.DeptID,
    dp.DeptName,
    f.Weekly_Sales,
    CASE WHEN f.Weekly_Sales < 0 THEN 1 ELSE 0 END AS IsReturn,
    f.MarkDown1, f.MarkDown2, f.MarkDown3, f.MarkDown4, f.MarkDown5,
    (ISNULL(f.MarkDown1,0) + ISNULL(f.MarkDown2,0) + ISNULL(f.MarkDown3,0)
     + ISNULL(f.MarkDown4,0) + ISNULL(f.MarkDown5,0))  AS MarkDownTotal,
    f.Temperature,
    f.Fuel_Price,
    f.CPI,
    f.Unemployment,
    f.IsHolidayWeek
INTO mart.FactSalesPerformance
FROM dw.FactSales f
JOIN dw.DimDate dd       ON f.DateKey = dd.DateKey
JOIN dw.DimStore ds      ON f.StoreKey = ds.StoreKey
JOIN dw.DimDepartment dp ON f.DeptKey = dp.DeptKey;
GO
--(421 570 rows affected)

-- Index the columns this audience will actually filter/group by
CREATE NONCLUSTERED INDEX IX_FactSalesPerformance_Store ON mart.FactSalesPerformance(StoreID);
CREATE NONCLUSTERED INDEX IX_FactSalesPerformance_Dept  ON mart.FactSalesPerformance(DeptID);
CREATE NONCLUSTERED INDEX IX_FactSalesPerformance_Date  ON mart.FactSalesPerformance(SaleDate);
GO

-- A2. mart.MonthlySalesByStoreDept - pre-aggregated summary table
IF OBJECT_ID('mart.MonthlySalesByStoreDept') IS NOT NULL DROP TABLE mart.MonthlySalesByStoreDept;
GO

SELECT
    StoreID,
    StoreType,
    SizeCategory,
    DeptID,
    DeptName,
    [Year],
    MonthNumber,
    MonthName,
    SUM(Weekly_Sales)                                              AS TotalSales,
    AVG(Weekly_Sales)                                              AS AvgWeeklySales,
    COUNT(*)                                                       AS WeekCount,
    SUM(CASE WHEN IsHolidayWeek = 1 THEN Weekly_Sales ELSE 0 END)   AS HolidayWeekSales,
    SUM(MarkDownTotal)                                             AS TotalMarkDownSpend,
    SUM(IsReturn)                                                  AS ReturnWeekCount
INTO mart.MonthlySalesByStoreDept
FROM mart.FactSalesPerformance
GROUP BY StoreID, StoreType, SizeCategory, DeptID, DeptName, [Year], MonthNumber, MonthName;
GO


CREATE NONCLUSTERED INDEX IX_MonthlySales_Store ON mart.MonthlySalesByStoreDept(StoreID);
CREATE NONCLUSTERED INDEX IX_MonthlySales_Dept  ON mart.MonthlySalesByStoreDept(DeptID);
GO

-- A3. VALIDATION (Part A)

SELECT 'mart.FactSalesPerformance'    AS TableName, COUNT(*) AS [RowCount] FROM mart.FactSalesPerformance
UNION ALL
SELECT 'mart.MonthlySalesByStoreDept', COUNT(*) FROM mart.MonthlySalesByStoreDept;
-- Expected: FactSalesPerformance 421,570 | MonthlySalesByStoreDept <= 45 stores x 81 depts x <=33 months

SELECT
    (SELECT SUM(Weekly_Sales) FROM dw.FactSales)               AS EDW_Total,
    (SELECT SUM(Weekly_Sales) FROM mart.FactSalesPerformance)  AS Mart_Total,
    CASE WHEN (SELECT SUM(Weekly_Sales) FROM dw.FactSales) =
              (SELECT SUM(Weekly_Sales) FROM mart.FactSalesPerformance)
         THEN 'MATCH' ELSE 'MISMATCH - investigate' END        AS Result;

SELECT
    (SELECT SUM(Weekly_Sales) FROM mart.FactSalesPerformance)  AS FlatTotal,
    (SELECT SUM(TotalSales) FROM mart.MonthlySalesByStoreDept) AS AggregatedTotal,
    CASE WHEN (SELECT SUM(Weekly_Sales) FROM mart.FactSalesPerformance) =
              (SELECT SUM(TotalSales) FROM mart.MonthlySalesByStoreDept)
         THEN 'MATCH' ELSE 'MISMATCH - investigate' END        AS Result;
GO


-- A4. SAMPLE ANALYTICAL QUERIES (Part A - chain-wide questions)

-- Which departments see the biggest sales lift during holiday weeks?
SELECT TOP 10
    DeptID, DeptName,
    AVG(CASE WHEN IsHolidayWeek = 1 THEN Weekly_Sales END)     AS AvgHolidayWeekSales,
    AVG(CASE WHEN IsHolidayWeek = 0 THEN Weekly_Sales END)     AS AvgNonHolidayWeekSales,
    AVG(CASE WHEN IsHolidayWeek = 1 THEN Weekly_Sales END)
      - AVG(CASE WHEN IsHolidayWeek = 0 THEN Weekly_Sales END) AS HolidayLift
FROM mart.FactSalesPerformance
GROUP BY DeptID, DeptName
ORDER BY HolidayLift DESC;

-- Which store size category benefits most from markdown promotions?
SELECT
    SizeCategory,
    SUM(CASE WHEN MarkDownTotal > 0 THEN Weekly_Sales ELSE 0 END) / NULLIF(SUM(CASE WHEN MarkDownTotal > 0 THEN 1 ELSE 0 END),0) AS AvgSalesDuringMarkdown,
    SUM(CASE WHEN MarkDownTotal = 0 THEN Weekly_Sales ELSE 0 END) / NULLIF(SUM(CASE WHEN MarkDownTotal = 0 THEN 1 ELSE 0 END),0) AS AvgSalesNoMarkdown
FROM mart.FactSalesPerformance
WHERE SaleDate >= '2011-11-01'
GROUP BY SizeCategory;

-- Fast monthly trend for one store, straight from the pre-aggregated table
SELECT [Year], MonthName, SUM(TotalSales) AS StoreMonthlyTotal
FROM mart.MonthlySalesByStoreDept
WHERE StoreID = 1
GROUP BY [Year], MonthNumber, MonthName
ORDER BY [Year], MonthNumber;
GO


--PART B: DEPARTMENT-SPECIFIC MART (Department 1 only)
  
-- B1. mart.Dept01_SalesMart - one row per store/week, Dept 1 only
IF OBJECT_ID('mart.Dept01_SalesMart') IS NOT NULL DROP TABLE mart.Dept01_SalesMart;
GO

SELECT
    SalesKey,
    SaleDate, [Year], MonthName, MonthNumber, Quarter, WeekOfYear,
    IsPublicHoliday, HolidayName, IsHolidayWeek,
    StoreID, StoreType, StoreSize, SizeCategory,
    DeptID, DeptName,
    Weekly_Sales,
    IsReturn,
    MarkDown1, MarkDown2, MarkDown3, MarkDown4, MarkDown5, MarkDownTotal,
    Temperature, Fuel_Price, CPI, Unemployment
INTO mart.Dept01_SalesMart
FROM mart.FactSalesPerformance
WHERE DeptID = 1;
GO

CREATE NONCLUSTERED INDEX IX_Dept01_Store ON mart.Dept01_SalesMart(StoreID);
CREATE NONCLUSTERED INDEX IX_Dept01_Date  ON mart.Dept01_SalesMart(SaleDate);
GO

-- B2. mart.Dept01_MonthlyByStore - pre-aggregated monthly rollup,
--     same department, one row per store/month
IF OBJECT_ID('mart.Dept01_MonthlyByStore') IS NOT NULL DROP TABLE mart.Dept01_MonthlyByStore;
GO

SELECT
    StoreID, StoreType, SizeCategory,
    [Year], MonthNumber, MonthName,
    SUM(Weekly_Sales)                                              AS TotalSales,
    AVG(Weekly_Sales)                                              AS AvgWeeklySales,
    COUNT(*)                                                       AS WeekCount,
    SUM(CASE WHEN IsHolidayWeek = 1 THEN Weekly_Sales ELSE 0 END)   AS HolidayWeekSales,
    SUM(MarkDownTotal)                                             AS TotalMarkDownSpend,
    SUM(IsReturn)                                                  AS ReturnWeekCount
INTO mart.Dept01_MonthlyByStore
FROM mart.Dept01_SalesMart
GROUP BY StoreID, StoreType, SizeCategory, [Year], MonthNumber, MonthName;
GO

CREATE NONCLUSTERED INDEX IX_Dept01_Monthly_Store ON mart.Dept01_MonthlyByStore(StoreID);
CREATE NONCLUSTERED INDEX IX_Dept01_Monthly_Date  ON mart.Dept01_MonthlyByStore([Year], MonthNumber);
GO

-- B3. VALIDATION (Part B)

-- Row count and department confirmation
SELECT COUNT(*) AS [RowCount], COUNT(DISTINCT DeptID) AS DistinctDepts, MIN(DeptID) AS DeptID
FROM mart.Dept01_SalesMart;
-- DistinctDepts must be exactly 1 - proves this mart really is single-department

-- Confirm the filtered total matches the equivalent slice of the main mart
SELECT
    (SELECT SUM(Weekly_Sales) FROM mart.FactSalesPerformance WHERE DeptID = 1) AS SourceSliceTotal,
    (SELECT SUM(Weekly_Sales) FROM mart.Dept01_SalesMart)                      AS DeptMartTotal,
    CASE WHEN (SELECT SUM(Weekly_Sales) FROM mart.FactSalesPerformance WHERE DeptID = 1) =
              (SELECT SUM(Weekly_Sales) FROM mart.Dept01_SalesMart)
         THEN 'MATCH' ELSE 'MISMATCH - investigate' END                        AS Result;

-- Confirm the monthly rollup matches the dept mart
SELECT
    (SELECT SUM(Weekly_Sales) FROM mart.Dept01_SalesMart)      AS DeptMartTotal,
    (SELECT SUM(TotalSales) FROM mart.Dept01_MonthlyByStore)   AS MonthlyRollupTotal,
    CASE WHEN (SELECT SUM(Weekly_Sales) FROM mart.Dept01_SalesMart) =
              (SELECT SUM(TotalSales) FROM mart.Dept01_MonthlyByStore)
         THEN 'MATCH' ELSE 'MISMATCH - investigate' END        AS Result;

-- How many stores carry this department, and over how many weeks
SELECT COUNT(DISTINCT StoreID) AS StoresCarryingThisDept, COUNT(DISTINCT SaleDate) AS WeeksCovered
FROM mart.Dept01_SalesMart;
GO

-- B4. SAMPLE ANALYTICAL QUERIES (Part B - department-manager's

-- Which stores sell the most of THIS department, and does store size explain it?
SELECT StoreID, StoreType, SizeCategory, SUM(Weekly_Sales) AS TotalSales
FROM mart.Dept01_SalesMart
GROUP BY StoreID, StoreType, SizeCategory
ORDER BY TotalSales DESC;

-- Monthly trend for this department, chain-wide (all stores combined)
SELECT [Year], MonthNumber, MonthName, SUM(TotalSales) AS ChainWideMonthlyTotal
FROM mart.Dept01_MonthlyByStore
GROUP BY [Year], MonthNumber, MonthName
ORDER BY [Year], MonthNumber;

-- Holiday lift specific to this one department
SELECT
    AVG(CASE WHEN IsHolidayWeek = 1 THEN Weekly_Sales END) AS AvgHolidayWeekSales,
    AVG(CASE WHEN IsHolidayWeek = 0 THEN Weekly_Sales END) AS AvgNonHolidayWeekSales
FROM mart.Dept01_SalesMart;
GO
