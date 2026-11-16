# Multi-host activity resolution (same Network ID on several hosts)

Implements the multi-host scenarios of *WorkVista Scenarios v2*
(7.1 – 7.6, 7.10, 7.12, 7.14, 7.15). **Not included:** 7.11 (night shift) and the
agent-side scenarios (7.7 grace period, 7.8 VDI, 7.9 agent crash, 7.13 DST).

## 1. How it works

```
Agent (host A, B, ...) -> Event Hub -> Consumer -> Data Lake
                                                      |
                                    Processor: ProcessAsync (per file)
                                                      v
                                          RawActivityLog   (NEW: every host, overlaps kept)
                                                      |
                          Processor: ResolveActivitiesAsync (every 2 min, before the summary)
                                                      v
                                          MasterActivityLog (one timeline per employee, NO overlap)
                                                      |
                          Processor: CreateProductivitySummaryAsync (unchanged logic)
                                                      v
                                          EmployeeActivityLogSummary
```

Because `MasterActivityLog` no longer overlaps, the summary calculator, shift-date
planner, dashboards and stored procedures keep working unchanged.

### Resolution rules (`ActivityTimelineResolver`)

1. **Cumulative duplicates**: same host + start + status → the longest row wins.
2. **Overlap priority** (lower wins): Productive 1, No-Impact 2, Non-Productive 3,
   Unknown 4, Idle 999. Same rank → higher `MasterActivityCategory.ProductivityScore`
   wins → then earliest start, lowest host id, lowest row id (deterministic).
   Unknown = category named `Unknown` (its Status stays Non-Productive, as today).
   Losing rows are trimmed/split, so every instant has exactly one category.
3. **Gaps** between two activities (lock, logout, shutdown, other host not yet active)
   are **Idle** (`IsGapFill = 1`, Idle category).
4. **120-minute rule (≥ 120)**: every continuous idle run (agent Idle rows + gaps, all
   hosts merged) of 120 minutes or more is removed completely. Shorter runs are kept.
   Applied per episode, not per day. Exactly 120 min is excluded
   (`ExcludeAtThreshold`, switchable to `> 120`).
5. **Open tail**: the agent only sends an activity when it ends, so the time after the
   employee's latest activity is a running activity. It is shown as provisional Idle
   (`IsGapFill = 1`) until the real row arrives, or until it reaches 120 minutes
   (then it is removed). The resolve step re-runs for employees whose last activity is
   younger than 120 min + 10 min, which refreshes/removes it.
6. Idle before an employee's first Active in the loaded window is not decided/replaced.
7. `TOT_TIMEONSYSTEM` stays equal to `TOT_ACTIVEHOURS` (unchanged).

MasterActivityLog rows are **derived** and rebuilt from RawActivityLog. Only the
differences are deleted/inserted. Rows created by the resolver are recognised by
`SourceRawActivityLogId IS NOT NULL OR IsGapFill = 1`; **legacy/manual rows
(both empty) are never touched.**

## 2. What changed, and where

### Database model (`WorkVista.Server.DataContext`)

| File | Change |
|---|---|
| `Entities/RawActivityLog.cs` | **New** entity: employee, host (`MasterEmployeeSystemInfoId`), category, process, start/end/duration, status, `IsResolved`, `ResolvedAt`. |
| `Configurations/RawActivityLogConfiguration.cs` | **New**: table, FKs (host, category), indexes `UX_RawActivityLog_Dedup` (unique: employee+host+start+end+duration), `IX_RawActivityLog_Employee_StartTime`, `IX_RawActivityLog_Unresolved` (filtered `IsResolved = 0`), `IX_RawActivityLog_EndTime`. |
| `Entities/MasterActivityLog.cs` | **New columns** `SourceRawActivityLogId` (bigint, null) and `IsGapFill` (bit, default 0). |
| `Configurations/MasterActivityLogConfiguration.cs` | Configures the two columns; new filtered index `IX_ActivityLog_Employee_StartTime_Derived`. |
| `WorkVistaDbContext.cs` | `DbSet<RawActivityLog> RawActivityLog`. |

> **No migration was created or run.** Create it yourself, e.g.
> `dotnet ef migrations add AddedRawActivityLogAndGapFill` (MigrationService project).

### Processor (`WorkVista.Processor`)

| File | Change |
|---|---|
| `Services/EmployeeActivityProcessingService.cs` | Class is now `partial`. `ProcessActivityLogsAsync` writes **RawActivityLog** (per host) instead of MasterActivityLog; shift-date planning moved to the resolve step. Idle rows use the dedicated `Idle` category. `ActivityKey` now includes the host. Constructor takes `IOptions<ActivityResolutionOptions>`. |
| `Services/EmployeeActivityProcessingService.Resolution.cs` | **New**: `ResolveActivitiesAsync` – finds employees with unresolved raw rows or an open tail, loads their raw rows, resolves, diffs against MasterActivityLog, re-dates shift dates, marks raw rows resolved. One transaction + per-employee `sp_getapplock` per employee. |
| `Resolution/ActivityTimelineResolver.cs` | **New**, pure (no I/O): the rules above. `ActivityPriority` holds the ranks. |
| `Resolution/ActivityResolutionOptions.cs` | **New** options (section `ActivityResolution`). |
| `Interfaces/IEmployeeActivityProcessingService.cs` | Added `ResolveActivitiesAsync`. |
| `Jobs/ProductivitySummaryJob.cs` | Calls `ResolveActivitiesAsync` before `CreateProductivitySummaryAsync` (every 2 min). |
| `Program.cs` | Registers `ActivityResolutionOptions`. |

### Tests

`WorkVista.Processor.Tests` (new, xUnit, added to `WorkVista.slnx`): 24 tests –
scenarios 7.1–7.6, 7.10, 7.12, 7.14, 7.15, the 119/120-minute boundary, priority,
`ProductivityScore` tie-break, idle merging, open tail, cumulative duplicates.
Run: `dotnet test WorkVista.Processor.Tests`.

### SQL scripts (`SqlScripts/`)

| Script | Purpose |
|---|---|
| `01_Seed_Idle_Category.sql` | Inserts the `Idle` category (ActivityTypeId = 1). Idempotent. |
| `02_usp_ValidateResolvedActivity.sql` | Creates a read-only procedure: overlap check, unresolved raw count, totals per shift date. |

## 3. Configuration (all optional, section `ActivityResolution`)

| Key | Default | Meaning |
|---|---|---|
| `IdleIgnoreThreshold` | `02:00:00` | Idle episode length that is excluded. |
| `ExcludeAtThreshold` | `true` | `true` = exclude at ≥ 120 min, `false` = only > 120 min. |
| `ProvisionalTailIdle` | `true` | Show the not-yet-sent running activity as Idle. |
| `Lookback` | `04:00:00` | Raw rows loaded before the earliest changed row (must exceed the longest activity). |
| `OpenTailMargin` | `00:10:00` | Extra time an employee keeps being re-resolved after the idle threshold. |
| `MaxEmployeesPerRun` | `500` | Employees resolved per run. |

## 4. Deployment steps

1. Create and review the EF migration, apply it (new table + 2 columns + indexes).
2. Run `SqlScripts/01_Seed_Idle_Category.sql`, then `02_usp_ValidateResolvedActivity.sql`.
3. Deploy the Processor. New files go to `RawActivityLog`; the job resolves them.
4. Check with `EXEC dbo.usp_ValidateResolvedActivity @EmployeeCode, @FromLogDate`
   (overlap result set must be empty).

## 5. Behaviour changes to be aware of

- **Cut-over**: data before deployment has no raw rows and stays as it is. Only data
  processed after deployment is resolved.
- **The 120-minute rule is new** to the pipeline. Single-host Idle rows of 120 minutes
  or more (and gaps) are now excluded, so idle/logged hours drop for those cases.
- **Provisional idle** after an employee's latest activity (up to 120 min) appears and
  is corrected/removed as data arrives. A long single activity still running looks
  idle until it is sent.
- **Manual edits** of resolver-created MasterActivityLog rows (Add/Update/Delete
  endpoints) are overwritten by the next rebuild. Legacy/manual rows are safe.
- `ProductivityScore` is only a tie-break inside the same priority rank, and changing
  a score affects windows resolved afterwards (not history unless re-resolved).
- A gap cannot tell a lock from a power-off; both count as Idle up to 120 minutes.
- `SourceRawActivityLogId` has no FK (raw retention can delete rows freely).
- Shift-date logic (night shift) is untouched; it now runs on the resolved timeline.
