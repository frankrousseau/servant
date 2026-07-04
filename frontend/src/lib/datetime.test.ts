import { describe, it, expect } from "vitest";
import { zonedToUtcISO, utcToZonedParts, todayInUserTz, formatDate, formatDuration } from "./datetime";

describe("zonedToUtcISO", () => {
  it("interprets wall-clock time in the given zone (Paris summer, UTC+2)", () => {
    expect(zonedToUtcISO("2026-07-15", "09:00", "Europe/Paris")).toBe(
      "2026-07-15T07:00:00.000Z",
    );
  });

  it("handles a zone behind UTC crossing midnight (New York winter, UTC-5)", () => {
    expect(zonedToUtcISO("2026-01-01", "23:30", "America/New_York")).toBe(
      "2026-01-02T04:30:00.000Z",
    );
  });

  it("is identity for UTC", () => {
    expect(zonedToUtcISO("2026-03-10", "14:00", "UTC")).toBe("2026-03-10T14:00:00.000Z");
  });
});

describe("utcToZonedParts", () => {
  it("round-trips with zonedToUtcISO", () => {
    const utc = zonedToUtcISO("2026-07-15", "09:00", "Europe/Paris");
    expect(utcToZonedParts(utc, "Europe/Paris")).toEqual({ date: "2026-07-15", time: "09:00" });
  });

  it("splits a UTC instant into wall-clock date/time for the zone", () => {
    expect(utcToZonedParts("2026-01-02T04:30:00.000Z", "America/New_York")).toEqual({
      date: "2026-01-01",
      time: "23:30",
    });
  });
});

describe("todayInUserTz", () => {
  it("returns a YYYY-MM-DD string", () => {
    expect(todayInUserTz("UTC")).toMatch(/^\d{4}-\d{2}-\d{2}$/);
  });
});

describe("formatDate", () => {
  it("returns an empty string for null/invalid input", () => {
    expect(formatDate(null)).toBe("");
    expect(formatDate("not-a-date")).toBe("");
  });

  it("formats a valid ISO date to a non-empty string", () => {
    expect(formatDate("2026-07-15T07:00:00.000Z")).not.toBe("");
  });
});

describe("formatDuration", () => {
  it("formats seconds and minutes", () => {
    expect(formatDuration(0)).toBe("0:00");
    expect(formatDuration(7)).toBe("0:07");
    expect(formatDuration(83.9)).toBe("1:23");
  });

  it("switches to h:mm:ss past the hour", () => {
    expect(formatDuration(3600)).toBe("1:00:00");
    expect(formatDuration(3661)).toBe("1:01:01");
  });

  it("is defensive about invalid input", () => {
    expect(formatDuration(NaN)).toBe("0:00");
    expect(formatDuration(Infinity)).toBe("0:00");
    expect(formatDuration(-5)).toBe("0:00");
  });
});
