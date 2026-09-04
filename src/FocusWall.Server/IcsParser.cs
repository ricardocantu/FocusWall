using Ical.Net;
using Ical.Net.DataTypes;
using Ical.Net.Evaluation;

namespace FocusWall.Server;

public record CalendarEventInfo(string Title, DateTimeOffset Start, DateTimeOffset End, bool AllDay);

// Parses one calendar's raw iCalendar (.ics) text into the events occurring on
// a given local date, expanding recurrence (RRULE/EXDATE/RECURRENCE-ID) via
// Ical.Net. Throws Ical.Net.Serialization.SerializationException on malformed
// input — CalendarService catches per-source so one bad feed doesn't blank the
// others, mirroring RssParser.ParseFeed's contract.
public static class IcsParser
{
    public static List<CalendarEventInfo> ParseToday(string icsText, DateOnly today, TimeZoneInfo tz)
    {
        // Load returns null for a body that isn't iCalendar at all (e.g. an HTML
        // sign-in page from an expired secret URL) — fail deliberately so the
        // source shows fetch_failed (FormatException) rather than an NRE.
        var calendar = Calendar.Load(icsText)
            ?? throw new FormatException("not an iCalendar body");

        var todayLocalMidnight = today.ToDateTime(TimeOnly.MinValue); // Kind = Unspecified
        var windowStartUtc = TimeZoneInfo.ConvertTimeToUtc(todayLocalMidnight, tz);
        var windowEndUtc = windowStartUtc.AddDays(1);

        // GetOccurrences only returns occurrences AT/AFTER this bound. Back it
        // off two days: a floating all-day DTSTART (no TZID) evaluates via
        // AsUtc as UTC-midnight-on-that-date, which can land *before*
        // windowStartUtc when the local zone is behind UTC — without the
        // back-off, today's all-day events would be silently skipped.
        var bound = new CalDateTime(DateTime.SpecifyKind(windowStartUtc.AddDays(-2), DateTimeKind.Utc));
        var opts = new EvaluationOptions();

        // A moved/edited/cancelled instance of a recurring event is exported as
        // a second VEVENT with the same UID and a RECURRENCE-ID naming the master
        // occurrence it replaces. Ical.Net reconciles those only in the
        // Calendar-level GetOccurrences; the per-event loop below (kept so one
        // bad VEVENT can't blank the feed) has to drop the replaced master
        // occurrences itself, or a standup dragged from 09:00 to 14:00 shows at
        // both times. RANGE=THISANDFUTURE isn't handled (Google splits the
        // series instead of emitting it).
        var replacedStartsByUid = calendar.Events
            .Where(e => e.Uid is not null && e.RecurrenceIdentifier is not null)
            .ToLookup(e => e.Uid!, e => e.RecurrenceIdentifier!.StartTime.AsUtc);

        var results = new List<CalendarEventInfo>();
        foreach (var ev in calendar.Events)
        {
            try
            {
                var title = ev.Summary?.Trim();
                if (string.IsNullOrEmpty(title)) continue;

                // Outlook keeps a cancelled meeting on the calendar with
                // STATUS:CANCELLED rather than deleting it.
                if (string.Equals(ev.Status, EventStatus.Cancelled, StringComparison.OrdinalIgnoreCase)) continue;

                // DTSTART + DTEND only. A VEVENT that carries DURATION instead
                // of DTEND (valid RFC 5545, rare in Google/Outlook exports) is
                // skipped deliberately — a known limitation, not a crash.
                if (ev.DtStart is null || ev.DtEnd is null) continue;
                var duration = ev.DtEnd.AsUtc - ev.DtStart.AsUtc;
                var occurrences = ev.GetOccurrences(bound, opts);
                var replacedStarts = ev.RecurrenceIdentifier is null && ev.Uid is not null
                    ? replacedStartsByUid[ev.Uid].ToHashSet()
                    : [];

                foreach (var occ in occurrences)
                {
                    if (replacedStarts.Contains(occ.Period.StartTime.AsUtc)) continue; // superseded by a RECURRENCE-ID override

                    if (ev.IsAllDay)
                    {
                        var startDate = DateOnly.FromDateTime(occ.Period.StartTime.Value);
                        if (startDate > today.AddDays(60)) break; // safety valve for a runaway recurring all-day rule
                        if (today < startDate) continue;
                        var endDateExclusive = DateOnly.FromDateTime(occ.Period.StartTime.Value + duration);
                        if (today >= endDateExclusive) continue;

                        results.Add(new CalendarEventInfo(
                            title, new DateTimeOffset(windowStartUtc, TimeSpan.Zero),
                            new DateTimeOffset(windowEndUtc, TimeSpan.Zero), true));
                        break; // an all-day event occupies today at most once
                    }

                    var startUtc = occ.Period.StartTime.AsUtc;
                    if (startUtc >= windowEndUtc) break;
                    var endUtc = startUtc + duration;
                    if (endUtc <= windowStartUtc) continue;

                    results.Add(new CalendarEventInfo(
                        title, new DateTimeOffset(startUtc, TimeSpan.Zero),
                        new DateTimeOffset(endUtc, TimeSpan.Zero), false));
                }
            }
            catch (Exception) { continue; } // one malformed event (missing DTEND, unevaluable RRULE, etc.) shouldn't blank the whole feed
        }

        return results
            .OrderByDescending(e => e.AllDay)
            .ThenBy(e => e.Start)
            .ToList();
    }
}
