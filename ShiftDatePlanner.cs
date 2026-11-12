namespace WorkVista.Processor.ShiftDate
{
    /// <summary>
    /// Plans Shift Dates for one employee's new activities, using the
    /// employee's recently stored rows as context (there is no state table).
    ///
    ///  - Seed: from stored rows that start before the earliest new activity.
    ///  - Fast path: nothing stored at/after the earliest new activity.
    ///  - Late path: stored rows exist at/after the earliest new activity
    ///    (files arrived out of order). Those stored rows are re-dated
    ///    together with the new ones, whatever their age, so a shift that was
    ///    split across files is always put back together.
    ///
    /// Rows that start before the earliest new activity are never changed.
    /// Pure: no I/O, no clock.
    /// </summary>
    public sealed class ShiftDatePlanner
    {
        private readonly ShiftDateResolver _resolver;

        /// <param name="resolver">Shift date resolver.</param>
        /// <param name="lateRecomputeWindow">Kept so existing callers still
        /// compile. It is no longer used: the old "very late" path (only new
        /// rows dated, stored rows left alone) is what let a split shift stay
        /// split, so every out-of-order arrival now takes the Late path.</param>
        public ShiftDatePlanner(
            ShiftDateResolver resolver,
            TimeSpan lateRecomputeWindow)
        {
            _resolver = resolver;
        }

        /// <param name="storedRecent">The employee's stored rows starting at or after
        /// (earliest new start - SeedLookback). Must not contain the new rows.</param>
        /// <param name="newActivities">The employee's rows about to be inserted.</param>
        public ShiftDatePlan Plan(
            IReadOnlyList<StoredShiftActivity> storedRecent,
            IReadOnlyList<ShiftActivity> newActivities)
        {
            if (newActivities.Count == 0)
            {
                return new ShiftDatePlan(
                    Array.Empty<DateOnly>(),
                    Array.Empty<(long, DateOnly)>(),
                    ShiftPlanPath.None,
                    0, 0, 0);
            }

            var minNewStart = newActivities.Min(x => x.StartUtc);

            var before = storedRecent
                .Where(x => x.StartUtc < minNewStart)
                .ToList();

            var after = storedRecent
                .Where(x => x.StartUtc >= minNewStart)
                .OrderBy(x => x.StartUtc)
                .ThenBy(x => x.Id)
                .ToList();

            var seed = BuildSeed(before);

            // Stored rows exist after the new rows: re-resolve them together.
            // Resolution is deterministic, so only rows whose date actually
            // changes are returned as updates.
            if (after.Count > 0)
            {
                return PlanLate(seed, after, newActivities);
            }

            var resolution = _resolver.Resolve(seed, newActivities);

            return new ShiftDatePlan(
                resolution.ShiftDates,
                Array.Empty<(long, DateOnly)>(),
                ShiftPlanPath.Fast,
                resolution.NewShifts,
                resolution.CrossDateAssignments,
                resolution.Anomalies);
        }

        private ShiftDatePlan PlanLate(
            ShiftState? seed,
            List<StoredShiftActivity> after,
            IReadOnlyList<ShiftActivity> newActivities)
        {
            var combined = new List<ShiftActivity>(after.Count + newActivities.Count);

            combined.AddRange(after.Select(x => new ShiftActivity(x.StartUtc, x.EndUtc, x.IsIdle)));
            combined.AddRange(newActivities);

            var resolution = _resolver.Resolve(seed, combined);

            var updates = new List<(long Id, DateOnly LogDate)>();

            for (var i = 0; i < after.Count; i++)
            {
                if (resolution.ShiftDates[i] != after[i].LogDate)
                {
                    updates.Add((after[i].Id, resolution.ShiftDates[i]));
                }
            }

            return new ShiftDatePlan(
                resolution.ShiftDates[after.Count..],
                updates,
                ShiftPlanPath.Late,
                resolution.NewShifts,
                resolution.CrossDateAssignments,
                resolution.Anomalies);
        }

        /// <summary>
        /// State at the end of the stored rows that precede the new activities:
        /// the latest row's LogDate, and the latest non-idle end within that
        /// shift date (the earliest start if the shift only has idle rows).
        /// </summary>
        public static ShiftState? BuildSeed(
            IReadOnlyCollection<StoredShiftActivity> before)
        {
            if (before.Count == 0)
            {
                return null;
            }

            var latest = before
                .OrderByDescending(x => x.StartUtc)
                .ThenByDescending(x => x.Id)
                .First();

            var shiftRows = before
                .Where(x => x.LogDate == latest.LogDate)
                .ToList();

            var nonIdle = shiftRows
                .Where(x => !x.IsIdle)
                .ToList();

            var lastActiveEnd = nonIdle.Count > 0
                ? nonIdle.Max(x => x.EndUtc < x.StartUtc ? x.StartUtc : x.EndUtc)
                : shiftRows.Min(x => x.StartUtc);

            return new ShiftState(
                latest.LogDate,
                lastActiveEnd);
        }
    }
}
