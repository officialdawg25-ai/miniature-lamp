import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { classify, getPeriod, localDateTimeToUtc, parseEvents, unfoldIcs } from "./calendar-parser.ts";

Deno.test("unfolds continuation lines in iCalendar feeds", () => {
  assertEquals(unfoldIcs("SUMMARY:Consumer Price Index\r\n for September 2026"), [
    "SUMMARY:Consumer Price Indexfor September 2026",
  ]);
});

Deno.test("parses BLS event metadata and timezone", () => {
  const events = parseEvents([
    "BEGIN:VCALENDAR",
    "BEGIN:VEVENT",
    "UID:sample-1",
    "SUMMARY:Consumer Price Index for September 2026",
    "DTSTART;TZID=America/New_York:20261014T083000",
    "END:VEVENT",
    "END:VCALENDAR",
  ].join("\r\n"));
  assertEquals(events.length, 1);
  assertEquals(events[0].DTSTART_TZID, "America/New_York");
  assertEquals(classify(events[0].SUMMARY), { releaseName: "Consumer Price Index", prefix: "CPI" });
  assertEquals(getPeriod(events[0].SUMMARY), "2026-09");
});

Deno.test("converts Eastern Daylight Time release to UTC", () => {
  assertEquals(localDateTimeToUtc("20261014T083000", "America/New_York"), "2026-10-14T12:30:00.000Z");
});

Deno.test("converts Eastern Standard Time release to UTC", () => {
  assertEquals(localDateTimeToUtc("20261110T083000", "America/New_York"), "2026-11-10T13:30:00.000Z");
});

Deno.test("rejects invalid calendar dates and time zones", () => {
  assertEquals(localDateTimeToUtc("20260230T083000", "America/New_York"), null);
  assertEquals(localDateTimeToUtc("20261014T083000", "Not/A_Timezone"), null);
});

Deno.test("does not classify unrelated releases or malformed periods", () => {
  assertEquals(classify("Productivity and Costs for Third Quarter 2026"), null);
  assertEquals(getPeriod("Consumer Price Index for Smarch 2026"), null);
});
