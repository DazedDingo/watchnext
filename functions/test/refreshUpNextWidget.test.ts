import {
  buildFcmDataPayload,
  daysBetweenUtc,
  episodeLabel,
  episodeUri,
  pickUpNextRows,
  relativeWhenLabel,
  REFRESH_WIDGET_MAX_TILES,
  REFRESH_WIDGET_WINDOW_DAYS_AHEAD,
  REFRESH_WIDGET_WINDOW_DAYS_BEHIND,
  UpNextRow,
} from "../src/refreshUpNextWidget";

function row(o: Partial<UpNextRow> & { daysUntil: number }): UpNextRow {
  return {
    tmdbId: o.tmdbId ?? 1,
    showTitle: o.showTitle ?? "Show",
    posterPath: o.posterPath ?? "/p.jpg",
    next: o.next ?? {
      airDate: "2026-05-16",
      seasonNumber: 1,
      episodeNumber: 1,
      episodeName: "Pilot",
    },
    daysUntil: o.daysUntil,
  };
}

describe("daysBetweenUtc", () => {
  test("returns 0 for same date", () => {
    expect(daysBetweenUtc("2026-05-15", "2026-05-15")).toBe(0);
  });
  test("returns positive for future", () => {
    expect(daysBetweenUtc("2026-05-15", "2026-05-18")).toBe(3);
  });
  test("returns negative for past", () => {
    expect(daysBetweenUtc("2026-05-15", "2026-05-13")).toBe(-2);
  });
  test("crosses month boundary correctly", () => {
    expect(daysBetweenUtc("2026-04-30", "2026-05-02")).toBe(2);
  });
  test("malformed input returns 0 rather than NaN", () => {
    expect(daysBetweenUtc("garbage", "2026-05-15")).toBe(0);
  });
});

describe("relativeWhenLabel", () => {
  test("today / tomorrow / yesterday short forms", () => {
    expect(relativeWhenLabel(0)).toBe("Out today");
    expect(relativeWhenLabel(1)).toBe("Tomorrow");
    expect(relativeWhenLabel(-1)).toBe("Aired yesterday");
  });
  test("more-than-yesterday-past collapses to Just aired", () => {
    expect(relativeWhenLabel(-3)).toBe("Just aired");
  });
  test("future > 1 day uses In Nd", () => {
    expect(relativeWhenLabel(4)).toBe("In 4d");
  });
});

describe("episodeLabel", () => {
  test("with episode name", () => {
    expect(episodeLabel(3, 4, "Big Reveal")).toBe("S3E4 · Big Reveal");
  });
  test("trims whitespace-only names to code only", () => {
    expect(episodeLabel(3, 4, "   ")).toBe("S3E4");
  });
  test("null/undefined name yields code only", () => {
    expect(episodeLabel(1, 1, null)).toBe("S1E1");
    expect(episodeLabel(1, 1, undefined)).toBe("S1E1");
  });
});

describe("episodeUri", () => {
  test("encodes season + episode into wn:// path query", () => {
    expect(episodeUri(1399, 3, 4)).toBe("wn://title/tv/1399?season=3&episode=4");
  });
});

describe("pickUpNextRows", () => {
  const today = "2026-05-15";
  test("returns sorted-by-soonest within the window", () => {
    const out = pickUpNextRows(today, [
      row({ tmdbId: 1, daysUntil: 3 }),
      row({ tmdbId: 2, daysUntil: 0 }),
      row({ tmdbId: 3, daysUntil: 1 }),
    ]);
    expect(out.map((r) => r.tmdbId)).toEqual([2, 3, 1]);
  });
  test("drops items beyond the window-ahead bound", () => {
    const out = pickUpNextRows(today, [
      row({ tmdbId: 1, daysUntil: REFRESH_WIDGET_WINDOW_DAYS_AHEAD }),
      row({ tmdbId: 2, daysUntil: REFRESH_WIDGET_WINDOW_DAYS_AHEAD + 1 }),
    ]);
    expect(out.map((r) => r.tmdbId)).toEqual([1]);
  });
  test("drops items further-back than the window-behind bound", () => {
    const out = pickUpNextRows(today, [
      row({ tmdbId: 1, daysUntil: -REFRESH_WIDGET_WINDOW_DAYS_BEHIND }),
      row({ tmdbId: 2, daysUntil: -REFRESH_WIDGET_WINDOW_DAYS_BEHIND - 1 }),
    ]);
    expect(out.map((r) => r.tmdbId)).toEqual([1]);
  });
  test("caps at MAX_TILES (default 3)", () => {
    const out = pickUpNextRows(today, [
      row({ tmdbId: 1, daysUntil: 0 }),
      row({ tmdbId: 2, daysUntil: 1 }),
      row({ tmdbId: 3, daysUntil: 2 }),
      row({ tmdbId: 4, daysUntil: 3 }),
      row({ tmdbId: 5, daysUntil: 4 }),
    ]);
    expect(out).toHaveLength(REFRESH_WIDGET_MAX_TILES);
    expect(out.map((r) => r.tmdbId)).toEqual([1, 2, 3]);
  });
  test("empty input returns empty", () => {
    expect(pickUpNextRows(today, [])).toEqual([]);
  });
});

describe("buildFcmDataPayload", () => {
  test("encodes count, slots, and clears unused slots with empty strings", () => {
    const out = buildFcmDataPayload([
      row({
        tmdbId: 1399,
        showTitle: "GoT",
        daysUntil: 0,
        next: {
          airDate: "2026-05-15",
          seasonNumber: 3,
          episodeNumber: 4,
          episodeName: "Big Reveal",
        },
      }),
    ]);
    expect(out["type"]).toBe("refresh_widget");
    expect(out["up_next_count"]).toBe("1");
    expect(out["up_next_0_title"]).toBe("GoT");
    expect(out["up_next_0_episode_label"]).toBe("S3E4 · Big Reveal");
    expect(out["up_next_0_when"]).toBe("Out today");
    expect(out["up_next_0_uri"]).toBe("wn://title/tv/1399?season=3&episode=4");
    // Unused slots must be present (so bg handler can clear stale prefs) and
    // empty (FCM data maps don't allow null).
    for (let i = 1; i < REFRESH_WIDGET_MAX_TILES; i++) {
      expect(out[`up_next_${i}_title`]).toBe("");
      expect(out[`up_next_${i}_episode_label`]).toBe("");
      expect(out[`up_next_${i}_when`]).toBe("");
      expect(out[`up_next_${i}_uri`]).toBe("");
    }
  });
  test("empty rows → count=0, every slot blank, type still set", () => {
    const out = buildFcmDataPayload([]);
    expect(out["type"]).toBe("refresh_widget");
    expect(out["up_next_count"]).toBe("0");
    for (let i = 0; i < REFRESH_WIDGET_MAX_TILES; i++) {
      expect(out[`up_next_${i}_title`]).toBe("");
    }
  });
  test("every value is a string (FCM data map contract)", () => {
    const out = buildFcmDataPayload([row({ daysUntil: 1 })]);
    for (const v of Object.values(out)) {
      expect(typeof v).toBe("string");
    }
  });
});
