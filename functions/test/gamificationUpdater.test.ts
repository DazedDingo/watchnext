import {
  evaluateBadges,
  diffBadgeUnlocks,
  BadgeState,
  EntryDoc,
  MemberDoc,
} from "../src/gamificationUpdater";

const entry = (overrides: Partial<EntryDoc> = {}): EntryDoc => ({
  media_type: "movie",
  genres: [],
  ...overrides,
});

const member = (overrides: Partial<MemberDoc> & { uid: string }): MemberDoc =>
  ({ ...overrides });

const findBadge = (badges: BadgeState[], id: string): BadgeState => {
  const b = badges.find((x) => x.id === id);
  if (!b) throw new Error(`badge ${id} not found`);
  return b;
};

describe("evaluateBadges", () => {
  describe("Century Club", () => {
    test("not earned while under 100 entries", () => {
      const entries = Array.from({ length: 42 }, () => entry());
      const badges = evaluateBadges({ entries, members: [] });
      const b = findBadge(badges, "century_club");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(42);
      expect(b.target).toBe(100);
    });

    test("earned at 100, progress caps at target", () => {
      const entries = Array.from({ length: 150 }, () => entry());
      const badges = evaluateBadges({ entries, members: [] });
      const b = findBadge(badges, "century_club");
      expect(b.earned).toBe(true);
      expect(b.progress).toBe(100);
    });
  });

  describe("Genre Explorer", () => {
    test("counts distinct genres, ignoring duplicates", () => {
      const entries = [
        entry({ genres: ["Action", "Thriller"] }),
        entry({ genres: ["Action", "Comedy"] }),
        entry({ genres: ["Drama"] }),
      ];
      const badges = evaluateBadges({ entries, members: [] });
      const b = findBadge(badges, "genre_explorer");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(4);
    });

    test("earned at 5 distinct genres", () => {
      const entries = [
        entry({ genres: ["Action", "Thriller", "Drama"] }),
        entry({ genres: ["Comedy", "Horror"] }),
      ];
      const badges = evaluateBadges({ entries, members: [] });
      const b = findBadge(badges, "genre_explorer");
      expect(b.earned).toBe(true);
      expect(b.progress).toBe(5);
    });

    test("entries with no genres field do not crash", () => {
      const entries = [entry({ genres: undefined })];
      const badges = evaluateBadges({ entries, members: [] });
      const b = findBadge(badges, "genre_explorer");
      expect(b.progress).toBe(0);
      expect(b.earned).toBe(false);
    });
  });

  describe("Prediction Machine", () => {
    test("below volume gate → not earned", () => {
      const m = member({ uid: "u1", predict_total: 5, predict_wins: 5 });
      const badges = evaluateBadges({ entries: [], members: [m] });
      const b = findBadge(badges, "prediction_machine_u1");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(5);
      expect(b.member_uid).toBe("u1");
    });

    test("above volume, below accuracy → not earned", () => {
      const m = member({ uid: "u1", predict_total: 30, predict_wins: 20 });
      const badges = evaluateBadges({ entries: [], members: [m] });
      const b = findBadge(badges, "prediction_machine_u1");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(20);
    });

    test("earned at 20+ predictions with ≥80% accuracy", () => {
      const m = member({ uid: "u1", predict_total: 25, predict_wins: 20 });
      const badges = evaluateBadges({ entries: [], members: [m] });
      const b = findBadge(badges, "prediction_machine_u1");
      expect(b.earned).toBe(true);
    });

    test("sums legacy + per-mode counters (matches Dart getter)", () => {
      const m = member({
        uid: "u1",
        predict_total: 10,
        predict_wins: 8,
        predict_total_solo: 15,
        predict_wins_solo: 12,
      });
      // Total = 25, wins = 20, accuracy = 80% → earned.
      const badges = evaluateBadges({ entries: [], members: [m] });
      expect(findBadge(badges, "prediction_machine_u1").earned).toBe(true);
    });

    test("one badge per member, independent evaluation", () => {
      const a = member({ uid: "u1", predict_total: 25, predict_wins: 22 });
      const b = member({ uid: "u2", predict_total: 10, predict_wins: 8 });
      const badges = evaluateBadges({ entries: [], members: [a, b] });
      expect(findBadge(badges, "prediction_machine_u1").earned).toBe(true);
      expect(findBadge(badges, "prediction_machine_u2").earned).toBe(false);
    });
  });

  test("empty inputs → five household badges, zero per-user", () => {
    const badges = evaluateBadges({ entries: [], members: [] });
    expect(badges).toHaveLength(5);
    expect(badges.map((b) => b.id)).toEqual([
      "first_watch",
      "century_club",
      "genre_explorer",
      "binge_master",
      "perfect_sync",
    ]);
  });

  describe("First Watch", () => {
    test("not earned at zero entries, earned once any entry exists", () => {
      const zero = evaluateBadges({ entries: [], members: [] });
      expect(findBadge(zero, "first_watch").earned).toBe(false);

      const one = evaluateBadges({ entries: [entry()], members: [] });
      expect(findBadge(one, "first_watch").earned).toBe(true);
    });
  });

  describe("Binge Master", () => {
    test("counts only TV entries", () => {
      const entries = [
        ...Array.from({ length: 20 }, () => entry({ media_type: "movie" })),
        ...Array.from({ length: 6 }, () => entry({ media_type: "tv" })),
      ];
      const badges = evaluateBadges({ entries, members: [] });
      const b = findBadge(badges, "binge_master");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(6);
    });

    test("earned at 10 TV entries", () => {
      const entries = Array.from({ length: 12 }, () =>
        entry({ media_type: "tv" }),
      );
      const badges = evaluateBadges({ entries, members: [] });
      expect(findBadge(badges, "binge_master").earned).toBe(true);
    });
  });

  describe("Perfect Sync", () => {
    test("no taste profile → zero progress, not earned", () => {
      const badges = evaluateBadges({ entries: [], members: [] });
      const b = findBadge(badges, "perfect_sync");
      expect(b.progress).toBe(0);
      expect(b.earned).toBe(false);
    });

    test("below threshold, progress rounds to nearest int", () => {
      const badges = evaluateBadges({
        entries: [],
        members: [],
        compatibilityPct: 0.675,
      });
      const b = findBadge(badges, "perfect_sync");
      expect(b.progress).toBe(68);
      expect(b.earned).toBe(false);
    });

    test("earned at 90% compatibility; progress caps at target", () => {
      const badges = evaluateBadges({
        entries: [],
        members: [],
        compatibilityPct: 0.97,
      });
      const b = findBadge(badges, "perfect_sync");
      expect(b.earned).toBe(true);
      expect(b.progress).toBe(90);
    });
  });
});

describe("diffBadgeUnlocks", () => {
  const base: BadgeState = {
    id: "century_club",
    name: "Century Club",
    progress: 40,
    target: 100,
    earned: false,
    member_uid: null,
  };

  test("first-time evaluation queues all badges as writes", () => {
    const result = diffBadgeUnlocks({
      computed: [base],
      existing: new Map(),
    });
    expect(result.writes).toHaveLength(1);
    expect(result.newlyEarned).toHaveLength(0);
  });

  test("unchanged progress + earned state skips the write", () => {
    const result = diffBadgeUnlocks({
      computed: [base],
      existing: new Map([["century_club", { earned: false, progress: 40 }]]),
    });
    expect(result.writes).toHaveLength(0);
    expect(result.newlyEarned).toHaveLength(0);
  });

  test("progress change queues a write but no FCM", () => {
    const result = diffBadgeUnlocks({
      computed: [{ ...base, progress: 55 }],
      existing: new Map([["century_club", { earned: false, progress: 40 }]]),
    });
    expect(result.writes).toHaveLength(1);
    expect(result.newlyEarned).toHaveLength(0);
  });

  test("earned=false → true queues FCM with full badge state", () => {
    const result = diffBadgeUnlocks({
      computed: [{ ...base, earned: true, progress: 100 }],
      existing: new Map([["century_club", { earned: false, progress: 99 }]]),
    });
    expect(result.writes).toHaveLength(1);
    expect(result.newlyEarned).toHaveLength(1);
    expect(result.newlyEarned[0].id).toBe("century_club");
  });

  test("already-earned does not re-fire FCM on subsequent passes", () => {
    const result = diffBadgeUnlocks({
      computed: [{ ...base, earned: true, progress: 100 }],
      existing: new Map([["century_club", { earned: true, progress: 100 }]]),
    });
    expect(result.writes).toHaveLength(0);
    expect(result.newlyEarned).toHaveLength(0);
  });
});
