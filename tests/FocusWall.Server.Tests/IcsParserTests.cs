using FocusWall.Server;

public class IcsParserTests
{
    private static readonly TimeZoneInfo Chicago = TimeZoneInfo.FindSystemTimeZoneById("America/Chicago");
    private static readonly DateOnly Today = new(2026, 7, 17); // a Friday

    private static string Wrap(string vevents) => $"""
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Test//EN
        {vevents}
        END:VCALENDAR
        """;

    [Fact]
    public void SingleTimedEventTodayIsIncluded()
    {
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:oneoff@test
            DTSTART;TZID=America/Chicago:20260717T140000
            DTEND;TZID=America/Chicago:20260717T150000
            SUMMARY:1:1 with Manager
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        var e = Assert.Single(events);
        Assert.Equal("1:1 with Manager", e.Title);
        Assert.False(e.AllDay);
        Assert.Equal(new DateTimeOffset(2026, 7, 17, 19, 0, 0, TimeSpan.Zero), e.Start); // 2pm CDT = 19:00 UTC
        Assert.Equal(new DateTimeOffset(2026, 7, 17, 20, 0, 0, TimeSpan.Zero), e.End);
    }

    [Fact]
    public void RecurringWeeklyEventIncludesTodaysOccurrenceOnly()
    {
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:standup@test
            DTSTART;TZID=America/Chicago:20260713T090000
            DTEND;TZID=America/Chicago:20260713T091500
            RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR
            SUMMARY:Standup
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        var e = Assert.Single(events);
        Assert.Equal("Standup", e.Title);
        Assert.Equal(new DateTimeOffset(2026, 7, 17, 14, 0, 0, TimeSpan.Zero), e.Start); // 9am CDT Friday = 14:00 UTC
    }

    [Fact]
    public void ExdateExcludesTodaysCancelledInstance()
    {
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:standup2@test
            DTSTART;TZID=America/Chicago:20260713T090000
            DTEND;TZID=America/Chicago:20260713T091500
            RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR
            EXDATE;TZID=America/Chicago:20260717T090000
            SUMMARY:Standup (cancelled Friday)
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        Assert.Empty(events);
    }

    [Fact]
    public void AllDaySingleDayEventIsIncluded()
    {
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:allday@test
            DTSTART;VALUE=DATE:20260717
            DTEND;VALUE=DATE:20260718
            SUMMARY:Company Holiday
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        var e = Assert.Single(events);
        Assert.Equal("Company Holiday", e.Title);
        Assert.True(e.AllDay);
    }

    [Fact]
    public void AllDayMultiDayEventSpanningTodayIsIncluded()
    {
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:offsite@test
            DTSTART;VALUE=DATE:20260716
            DTEND;VALUE=DATE:20260719
            SUMMARY:Team Offsite
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        var e = Assert.Single(events);
        Assert.Equal("Team Offsite", e.Title);
        Assert.True(e.AllDay);
    }

    [Fact]
    public void EventOnADifferentDayIsExcluded()
    {
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:yesterday@test
            DTSTART;TZID=America/Chicago:20260710T090000
            DTEND;TZID=America/Chicago:20260710T093000
            SUMMARY:Last Friday one-off
            END:VEVENT
            BEGIN:VEVENT
            UID:nextmonth@test
            DTSTART;VALUE=DATE:20260820
            DTEND;VALUE=DATE:20260821
            SUMMARY:Next month holiday
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        Assert.Empty(events);
    }

    [Fact]
    public void ResultsAreSortedAllDayFirstThenByStartTime()
    {
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:late@test
            DTSTART;TZID=America/Chicago:20260717T160000
            DTEND;TZID=America/Chicago:20260717T163000
            SUMMARY:Late meeting
            END:VEVENT
            BEGIN:VEVENT
            UID:early@test
            DTSTART;TZID=America/Chicago:20260717T090000
            DTEND;TZID=America/Chicago:20260717T093000
            SUMMARY:Early meeting
            END:VEVENT
            BEGIN:VEVENT
            UID:allday@test
            DTSTART;VALUE=DATE:20260717
            DTEND;VALUE=DATE:20260718
            SUMMARY:Holiday
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        Assert.Equal(3, events.Count);
        Assert.Equal("Holiday", events[0].Title);
        Assert.Equal("Early meeting", events[1].Title);
        Assert.Equal("Late meeting", events[2].Title);
    }

    [Fact]
    public void MalformedIcsThrowsSoCallerCanSkip()
    {
        Assert.ThrowsAny<Exception>(() => IcsParser.ParseToday("not-valid-ics-at-all", Today, Chicago));
    }

    [Fact]
    public void EventMissingDtendIsSkippedButOtherEventsAreIncluded()
    {
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:malformed@test
            DTSTART;TZID=America/Chicago:20260717T140000
            SUMMARY:Malformed event with no DTEND
            END:VEVENT
            BEGIN:VEVENT
            UID:valid@test
            DTSTART;TZID=America/Chicago:20260717T150000
            DTEND;TZID=America/Chicago:20260717T160000
            SUMMARY:Valid event
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        var e = Assert.Single(events);
        Assert.Equal("Valid event", e.Title);
        Assert.False(e.AllDay);
    }

    [Fact]
    public void RecurrenceIdOverrideReplacesTodaysMasterInstance()
    {
        // Google/Outlook export a moved instance of a recurring meeting as the
        // RRULE master plus a second VEVENT with the same UID and a
        // RECURRENCE-ID naming the instance it replaces. Only the moved copy
        // should show — not the original 09:00 slot as well.
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:standup@test
            DTSTART;TZID=America/Chicago:20260713T090000
            DTEND;TZID=America/Chicago:20260713T091500
            RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR
            SUMMARY:Standup
            END:VEVENT
            BEGIN:VEVENT
            UID:standup@test
            RECURRENCE-ID;TZID=America/Chicago:20260717T090000
            DTSTART;TZID=America/Chicago:20260717T140000
            DTEND;TZID=America/Chicago:20260717T141500
            SUMMARY:Standup (moved)
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        var e = Assert.Single(events);
        Assert.Equal("Standup (moved)", e.Title);
        Assert.Equal(new DateTimeOffset(2026, 7, 17, 19, 0, 0, TimeSpan.Zero), e.Start); // 2pm CDT = 19:00 UTC
    }

    [Fact]
    public void CancelledEventIsSkipped()
    {
        // Outlook keeps a cancelled meeting on the calendar with STATUS:CANCELLED
        // rather than deleting it; it must not render as a live meeting.
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:cancelled@test
            DTSTART;TZID=America/Chicago:20260717T160000
            DTEND;TZID=America/Chicago:20260717T163000
            STATUS:CANCELLED
            SUMMARY:Cancelled sync
            END:VEVENT
            BEGIN:VEVENT
            UID:kept@test
            DTSTART;TZID=America/Chicago:20260717T170000
            DTEND;TZID=America/Chicago:20260717T173000
            SUMMARY:Kept sync
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        var e = Assert.Single(events);
        Assert.Equal("Kept sync", e.Title);
    }

    [Fact]
    public void CancelledRecurrenceIdOverrideAlsoDropsTheMasterInstance()
    {
        // Outlook cancels a single instance of a series by exporting an
        // override VEVENT with RECURRENCE-ID *and* STATUS:CANCELLED. Neither
        // the cancelled override nor the master's original slot should show.
        var ics = Wrap("""
            BEGIN:VEVENT
            UID:standup@test
            DTSTART;TZID=America/Chicago:20260713T090000
            DTEND;TZID=America/Chicago:20260713T091500
            RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR
            SUMMARY:Standup
            END:VEVENT
            BEGIN:VEVENT
            UID:standup@test
            RECURRENCE-ID;TZID=America/Chicago:20260717T090000
            DTSTART;TZID=America/Chicago:20260717T090000
            DTEND;TZID=America/Chicago:20260717T091500
            STATUS:CANCELLED
            SUMMARY:Standup
            END:VEVENT
            """);

        var events = IcsParser.ParseToday(ics, Today, Chicago);

        Assert.Empty(events);
    }
}
