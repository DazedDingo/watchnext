import {
  formatEpisodeLabel,
  pickEntriesNeedingNotify,
  NextEpisodeInfo,
  Notification,
  WatchEntryRow,
} from "../src/notifyNextEpisode";

function entry(overrides: Partial<WatchEntryRow> = {}): WatchEntryRow {
  return {
    entryId: "tv:1",
    tmdbId: 1,
    title: "Show",
    posterPath: "/p.jpg",
    ...overrides,
  };
}

function next(overrides: Partial<NextEpisodeInfo> = {}): NextEpisodeInfo {
  return {
    airDate: "2026-04-26",
    seasonNumber: 1,
    episodeNumber: 1,
    episodeName: "Pilot",
    ...overrides,
  };
}

describe("pickEntriesNeedingNotify", () => {
  const today = "2026-04-26";

  test("empty entries returns empty list", () => {
    expect(pickEntriesNeedingNotify(today, [], {})).toEqual([]);
  });

  test("entry airing today is included with all metadata propagated", () => {
    const e = entry({
      entryId: "tv:42",
      tmdbId: 42,
      title: "Severance",
      posterPath: "/sev.jpg",
    });
    const lookup = {
      42: next({
        airDate: today,
        seasonNumber: 2,
        episodeNumber: 3,
        episodeName: "Who Is Alive?",
      }),
    };

    const out = pickEntriesNeedingNotify(today, [e], lookup);

    expect(out).toHaveLength(1);
    const n: Notification = out[0];
    expect(n).toEqual({
      entryId: "tv:42",
      tmdbId: 42,
      showTitle: "Severance",
      posterPath: "/sev.jpg",
      airDate: today,
      seasonNumber: 2,
      episodeNumber: 3,
      episodeName: "Who Is Alive?",
    });
  });

  test("entry airing tomorrow is excluded", () => {
    const lookup = { 1: next({ airDate: "2026-04-27" }) };
    expect(pickEntriesNeedingNotify(today, [entry()], lookup)).toEqual([]);
  });

  test("entry airing next week is excluded", () => {
    const lookup = { 1: next({ airDate: "2026-05-03" }) };
    expect(pickEntriesNeedingNotify(today, [entry()], lookup)).toEqual([]);
  });

  test("entry where TMDB returned null (cancelled show) is excluded", () => {
    const lookup: Record<number, NextEpisodeInfo | null> = { 1: null };
    expect(pickEntriesNeedingNotify(today, [entry()], lookup)).toEqual([]);
  });

  test("entry missing from the lookup map is excluded", () => {
    // Defensive: undefined behaves like null for the gate.
    expect(pickEntriesNeedingNotify(today, [entry()], {})).toEqual([]);
  });

  test("entry already stamped with lastEpisodeNotifiedFor === airDate is excluded (idempotency)", () => {
    const e = entry({ lastEpisodeNotifiedFor: today });
    const lookup = { 1: next({ airDate: today }) };
    expect(pickEntriesNeedingNotify(today, [e], lookup)).toEqual([]);
  });

  test("entry stamped for an older airDate is included (rollover case)", () => {
    const e = entry({ lastEpisodeNotifiedFor: "2026-04-19" });
    const lookup = { 1: next({ airDate: today }) };

    const out = pickEntriesNeedingNotify(today, [e], lookup);

    expect(out).toHaveLength(1);
    expect(out[0].airDate).toBe(today);
    expect(out[0].entryId).toBe("tv:1");
  });

  test("multiple entries, mixed states — only the matching ones come back", () => {
    const entries: WatchEntryRow[] = [
      entry({ entryId: "tv:1", tmdbId: 1, title: "Airs Today" }),
      entry({ entryId: "tv:2", tmdbId: 2, title: "Airs Tomorrow" }),
      entry({ entryId: "tv:3", tmdbId: 3, title: "Cancelled" }),
      entry({
        entryId: "tv:4",
        tmdbId: 4,
        title: "Already Notified",
        lastEpisodeNotifiedFor: today,
      }),
      entry({
        entryId: "tv:5",
        tmdbId: 5,
        title: "Rollover",
        lastEpisodeNotifiedFor: "2026-04-19",
      }),
    ];
    const lookup: Record<number, NextEpisodeInfo | null> = {
      1: next({ airDate: today, seasonNumber: 1, episodeNumber: 7 }),
      2: next({ airDate: "2026-04-27" }),
      3: null,
      4: next({ airDate: today }),
      5: next({ airDate: today, seasonNumber: 3, episodeNumber: 1 }),
    };

    const out = pickEntriesNeedingNotify(today, entries, lookup);
    const ids = out.map((n) => n.entryId).sort();

    expect(ids).toEqual(["tv:1", "tv:5"]);
  });

  test("episode name and poster path propagate when present", () => {
    const e = entry({ posterPath: "/poster.jpg" });
    const lookup = { 1: next({ airDate: today, episodeName: "The Finale" }) };

    const out = pickEntriesNeedingNotify(today, [e], lookup);

    expect(out[0].posterPath).toBe("/poster.jpg");
    expect(out[0].episodeName).toBe("The Finale");
  });

  test("absent posterPath and episodeName become null", () => {
    const e = entry({ posterPath: undefined });
    const lookup = {
      1: next({ airDate: today, episodeName: undefined }),
    };

    const out = pickEntriesNeedingNotify(today, [e], lookup);

    expect(out[0].posterPath).toBeNull();
    expect(out[0].episodeName).toBeNull();
  });

  test("explicit null posterPath and episodeName stay null", () => {
    const e = entry({ posterPath: null });
    const lookup = { 1: next({ airDate: today, episodeName: null }) };

    const out = pickEntriesNeedingNotify(today, [e], lookup);

    expect(out[0].posterPath).toBeNull();
    expect(out[0].episodeName).toBeNull();
  });
});

describe("formatEpisodeLabel", () => {
  test("single-digit season + episode pad to two digits", () => {
    expect(formatEpisodeLabel(1, 1)).toBe("S01E01");
  });

  test("two-digit values stay two digits", () => {
    expect(formatEpisodeLabel(10, 12)).toBe("S10E12");
  });

  test("zero is valid (TMDB S00 specials)", () => {
    expect(formatEpisodeLabel(0, 5)).toBe("S00E05");
  });
});
