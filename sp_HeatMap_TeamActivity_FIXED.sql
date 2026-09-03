CREATE OR ALTER PROCEDURE [dbo].[sp_HeatMap_TeamActivity]
(
    @FromDate DATE,
    @ToDate DATE,
    @ManagerEmployeeCode VARCHAR(50) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @OffsetMinutes INT = 330;

    ;WITH Numbers AS
    (
        SELECT 0 AS number

        UNION ALL

        SELECT number + 1
        FROM Numbers
        WHERE number < 1000
    ),

    -------------------------------------------------
    -- TEAM LEADS
    -------------------------------------------------
    TeamLeads AS
    (
        SELECT DISTINCT
            EmployeeCode,
            FullName
        FROM vw_MasterEmployee
        WHERE LTRIM(RTRIM(MANAGER_1))
            = LTRIM(RTRIM(@ManagerEmployeeCode))
    ),

    -------------------------------------------------
    -- TEAM MEMBERS + TL THEMSELVES
    -------------------------------------------------
    TeamMembers AS
    (
        SELECT DISTINCT
            E.EmployeeCode,
            TL.EmployeeCode AS TeamLeadCode,
            TL.FullName AS TeamLeadName
        FROM vw_MasterEmployee E
        INNER JOIN TeamLeads TL
            ON TL.EmployeeCode = E.MANAGER_1
            OR TL.EmployeeCode = E.MANAGER_2
            OR TL.EmployeeCode = E.MANAGER_3
            OR TL.EmployeeCode = E.MANAGER_4
            OR TL.EmployeeCode = E.MANAGER_5
            OR TL.EmployeeCode = E.MANAGER_6
            OR TL.EmployeeCode = E.MANAGER_7

        UNION

        SELECT
            EmployeeCode,
            EmployeeCode AS TeamLeadCode,
            FullName AS TeamLeadName
        FROM TeamLeads
    ),

    -------------------------------------------------
    -- ACTIVITY DATA (FILTERED TO THIS MANAGER'S TEAM
    -- + CONVERTED TO IST)
    -- Filtering by TeamMembers here - instead of after
    -- expansion - means fn_ConvertUtcToLocal and the
    -- hourly CROSS APPLY only run for this team's rows,
    -- not for every employee in the company.
    -------------------------------------------------
    ActivityData AS
    (
        SELECT
            tm.TeamLeadCode,
            tm.TeamLeadName,
            a.EmployeeCode,
            dbo.fn_ConvertUtcToLocal
            (
                a.StartTime,
                @OffsetMinutes
            ) AS StartTime,
            dbo.fn_ConvertUtcToLocal
            (
                a.EndTime,
                @OffsetMinutes
            ) AS EndTime
        FROM dbo.MasterActivityLog a
        INNER JOIN TeamMembers tm
            ON tm.EmployeeCode = a.EmployeeCode
        WHERE
            a.IsActive = 1
            AND a.IsDelete = 0
            AND a.LogDate BETWEEN @FromDate AND @ToDate
            AND a.StartTime IS NOT NULL
            AND a.EndTime IS NOT NULL
    ),

    -------------------------------------------------
    -- EXPAND ACTIVITY INTO HOURS
    -------------------------------------------------
    ActivityExpanded AS
    (
        SELECT
            a.TeamLeadCode,
            a.TeamLeadName,
            a.EmployeeCode,

            DATEPART(HOUR, hr.HourStart) AS ActivityHour,

            CASE
                WHEN DATEPART(HOUR, hr.HourStart) >= 22
                    OR DATEPART(HOUR, hr.HourStart) < 6
                    THEN 'Night'

                WHEN DATEPART(HOUR, hr.HourStart) BETWEEN 6 AND 13
                    THEN 'Morning'

                ELSE 'Evening'
            END AS Shift,

            DATEDIFF
            (
                SECOND,

                CASE
                    WHEN a.StartTime > hr.HourStart
                        THEN a.StartTime
                    ELSE hr.HourStart
                END,

                CASE
                    WHEN a.EndTime < DATEADD(HOUR,1,hr.HourStart)
                        THEN a.EndTime
                    ELSE DATEADD(HOUR,1,hr.HourStart)
                END
            ) AS ActiveSeconds

        FROM ActivityData a

        CROSS APPLY
        (
            SELECT
                DATEADD
                (
                    HOUR,
                    n.number,
                    DATEADD
                    (
                        HOUR,
                        DATEDIFF(HOUR,0,a.StartTime),
                        0
                    )
                ) AS HourStart
            FROM Numbers n
            WHERE n.number <= DATEDIFF
            (
                HOUR,
                a.StartTime,
                a.EndTime
            )
        ) hr
    ),

    -------------------------------------------------
    -- EMPLOYEE HOURLY (CAP 60 MIN)
    -------------------------------------------------
    EmployeeHourly AS
    (
        SELECT
            TeamLeadCode,
            TeamLeadName,
            EmployeeCode,
            ActivityHour,
            Shift,

            CASE
                WHEN SUM(ActiveSeconds) / 60.0 > 60
                    THEN 60
                ELSE SUM(ActiveSeconds) / 60.0
            END AS ActiveMinutes

        FROM ActivityExpanded
        WHERE ActiveSeconds > 0
        GROUP BY
            TeamLeadCode,
            TeamLeadName,
            EmployeeCode,
            ActivityHour,
            Shift
    ),

    -------------------------------------------------
    -- TEAM LEAD HOURLY TOTAL
    -- (SUM, not AVG - employees with zero activity
    --  in an hour produce no row in EmployeeHourly,
    --  so averaging over that rowset would divide by
    --  only the "active" employees instead of the
    --  full team. We sum here and divide by the true
    --  headcount (HC) in the final SELECT instead.)
    -------------------------------------------------
    TeamLeadHourly AS
    (
        SELECT
            TeamLeadCode,
            TeamLeadName,
            ActivityHour,
            Shift,
            SUM(ActiveMinutes) AS TotalMinutes
        FROM EmployeeHourly
        GROUP BY
            TeamLeadCode,
            TeamLeadName,
            ActivityHour,
            Shift
    ),

    -------------------------------------------------
    -- HEAD COUNT
    -------------------------------------------------
    TeamLeadHC AS
    (
        SELECT
            TeamLeadCode,
            COUNT(DISTINCT EmployeeCode) AS HC
        FROM TeamMembers
        GROUP BY TeamLeadCode
    )

    -------------------------------------------------
    -- FINAL OUTPUT
    -------------------------------------------------
    SELECT
        t.TeamLeadCode,
        t.TeamLeadName,
        hc.HC,

        NULLIF(SUM(CASE WHEN ActivityHour = 0 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [00],
        NULLIF(SUM(CASE WHEN ActivityHour = 1 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [01],
        NULLIF(SUM(CASE WHEN ActivityHour = 2 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [02],
        NULLIF(SUM(CASE WHEN ActivityHour = 3 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [03],
        NULLIF(SUM(CASE WHEN ActivityHour = 4 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [04],
        NULLIF(SUM(CASE WHEN ActivityHour = 5 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [05],
        NULLIF(SUM(CASE WHEN ActivityHour = 6 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [06],
        NULLIF(SUM(CASE WHEN ActivityHour = 7 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [07],
        NULLIF(SUM(CASE WHEN ActivityHour = 8 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [08],
        NULLIF(SUM(CASE WHEN ActivityHour = 9 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [09],
        NULLIF(SUM(CASE WHEN ActivityHour = 10 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [10],
        NULLIF(SUM(CASE WHEN ActivityHour = 11 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [11],
        NULLIF(SUM(CASE WHEN ActivityHour = 12 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [12],
        NULLIF(SUM(CASE WHEN ActivityHour = 13 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [13],
        NULLIF(SUM(CASE WHEN ActivityHour = 14 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [14],
        NULLIF(SUM(CASE WHEN ActivityHour = 15 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [15],
        NULLIF(SUM(CASE WHEN ActivityHour = 16 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [16],
        NULLIF(SUM(CASE WHEN ActivityHour = 17 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [17],
        NULLIF(SUM(CASE WHEN ActivityHour = 18 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [18],
        NULLIF(SUM(CASE WHEN ActivityHour = 19 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [19],
        NULLIF(SUM(CASE WHEN ActivityHour = 20 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [20],
        NULLIF(SUM(CASE WHEN ActivityHour = 21 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [21],
        NULLIF(SUM(CASE WHEN ActivityHour = 22 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [22],
        NULLIF(SUM(CASE WHEN ActivityHour = 23 THEN TotalMinutes END) / NULLIF(CAST(hc.HC AS DECIMAL(18,4)),0),0) AS [23]

    FROM TeamLeadHourly t
    LEFT JOIN TeamLeadHC hc
        ON t.TeamLeadCode = hc.TeamLeadCode

    GROUP BY
        t.TeamLeadCode,
        t.TeamLeadName,
        hc.HC

    ORDER BY
        t.TeamLeadName

    OPTION (MAXRECURSION 1000);
END
GO