import { strict as assert } from "node:assert";
import { classify, getPeriod, localDateTimeToUtc, parseEvents, unfoldIcs } from "./calendar-parser.ts";

Deno.test("unfolds continuation lines in iCalendar feeds", () => {
  assert.deepEqual(unfoldIcs("SUMMARY:Consumer Price Index\r\n for September 2026"), [
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
  assert.deepEqual(events.length, 1);
  assert.deepEqual(events[0].DTSTART_TZID, "America/New_York");
  assert.deepEqual(classify(events[0].SUMMARY), { releaseName: "Consumer Price Index", prefix: "CPI", periodLagMonths: 1 });
  assert.deepEqual(getPeriod(events[0].SUMMARY), "2026-09");
});

Deno.test("converts Eastern Daylight Time release to UTC", () => {
  assert.deepEqual(localDateTimeToUtc("20261014T083000", "America/New_York"), "2026-10-14T12:30:00.000Z");
});

Deno.test("converts Eastern Standard Time release to UTC", () => {
  assert.deepEqual(localDateTimeToUtc("20261110T083000", "America/New_York"), "2026-11-10T13:30:00.000Z");
});

Deno.test("rejects invalid calendar dates and time zones", () => {
  assert.deepEqual(localDateTimeToUtc("20260230T083000", "America/New_York"), null);
  assert.deepEqual(localDateTimeToUtc("20261014T083000", "Not/A_Timezone"), null);
});

Deno.test("does not classify unrelated releases or malformed periods", () => {
  assert.deepEqual(classify("Productivity and Costs for Third Quarter 2026"), null);
  assert.deepEqual(getPeriod("Consumer Price Index for Smarch 2026"), null);
});
