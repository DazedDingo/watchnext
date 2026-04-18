import {
  evaluateBadges,
  diffBadgeUnlocks,
  BadgeState,
  DecisionDoc,
  EntryDoc,
  MemberDoc,
  RatingDoc,
} from "../src/gamificationUpdater";

const entry = (overrides: Partial<EntryDoc> = {}): EntryDoc => ({
  media_type: "movie",
  genres: [],
  ...overrides,
});

const member = (overrides: Partial<MemberDoc> & { uid: string }): MemberDoc =>
  ({ ...overrides });

const rating = (overrides: Partial<RatingDoc> & { uid: string }): RatingDoc =>
  ({ level: "movie", stars: 4, ...overrides });

const decision = (overrides: Partial<DecisionDoc> = {}): DecisionDoc =>
  ({ was_compromise: false, ...overrides });

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

  test("empty inputs → eight household badges, zero per-user", () => {
    const badges = evaluateBadges({ entries: [], members: [] });
    expect(badges).toHaveLength(8);
    expect(badges.map((b) => b.id)).toEqual([
      "first_watch",
      "century_club",
      "genre_explorer",
      "binge_master",
      "marathon_mode",
      "compromise_champ",
      "show_finisher",
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

  describe("Marathon Mode", () => {
    test("entries without timestamps → zero progress", () => {
      const entries = Array.from({ length: 8 }, () => entry());
      const badges = evaluateBadges({ entries, members: [] });
      const b = findBadge(badges, "marathon_mode");
      expect(b.progress).toBe(0);
      expect(b.earned).toBe(false);
    });

    test("earned at 5 watches on the same UTC day", () => {
      const base = Date.UTC(2026, 3, 18, 14);
      const entries = [
        ...Array.from({ length: 5 }, (_, i) =>
          entry({ last_watched_at_ms: base + i * 60_000 })),
        entry({ last_watched_at_ms: base + 3 * 86_400_000 }),
      ];
      const badges = evaluateBadges({ entries, members: [] });
      const b = findBadge(badges, "marathon_mode");
      expect(b.earned).toBe(true);
      expect(b.progress).toBe(5);
    });

    test("progress tracks max-day count when below threshold", () => {
      const day = Date.UTC(2026, 3, 18);
      const entries = [
        ...Array.from({ length: 4 }, (_, i) =>
          entry({ last_watched_at_ms: day + i * 60_000 })),
        entry({ last_watched_at_ms: day + 86_400_000 }),
      ];
      const badges = evaluateBadges({ entries, members: [] });
      const b = findBadge(badges, "marathon_mode");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(4);
    });
  });

  describe("Five Star Fan", () => {
    test("below threshold → not earned, progress tracks count", () => {
      const m = member({ uid: "u1" });
      const ratings = [
        ...Array.from({ length: 4 }, () => rating({ uid: "u1", stars: 5 })),
        rating({ uid: "u1", stars: 4 }),
      ];
      const badges = evaluateBadges({ entries: [], members: [m], ratings });
      const b = findBadge(badges, "five_star_fan_u1");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(4);
    });

    test("earned at 10 five-star ratings, progress caps", () => {
      const m = member({ uid: "u1" });
      const ratings = Array.from({ length: 12 }, () =>
        rating({ uid: "u1", stars: 5 }));
      const badges = evaluateBadges({ entries: [], members: [m], ratings });
      const b = findBadge(badges, "five_star_fan_u1");
      expect(b.earned).toBe(true);
      expect(b.progress).toBe(10);
    });

    test("another member's 5-stars do not count", () => {
      const a = member({ uid: "u1" });
      const b = member({ uid: "u2" });
      const ratings = Array.from({ length: 10 }, () =>
        rating({ uid: "u2", stars: 5 }));
      const badges = evaluateBadges({ entries: [], members: [a, b], ratings });
      expect(findBadge(badges, "five_star_fan_u1").earned).toBe(false);
      expect(findBadge(badges, "five_star_fan_u2").earned).toBe(true);
    });

    test("episode-level ratings do not inflate the count", () => {
      const m = member({ uid: "u1" });
      const ratings = Array.from({ length: 12 }, () =>
        rating({ uid: "u1", stars: 5, level: "episode" }));
      const badges = evaluateBadges({ entries: [], members: [m], ratings });
      expect(findBadge(badges, "five_star_fan_u1").progress).toBe(0);
    });
  });

  describe("Critic", () => {
    test("counts only ratings with a non-empty note", () => {
      const m = member({ uid: "u1" });
      const ratings = [
        ...Array.from({ length: 6 }, (_, i) =>
          rating({ uid: "u1", stars: 4, note: `thoughts ${i}` })),
        rating({ uid: "u1", stars: 3, note: "   " }),
        rating({ uid: "u1", stars: 2 }),
      ];
      const badges = evaluateBadges({ entries: [], members: [m], ratings });
      const b = findBadge(badges, "critic_u1");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(6);
    });

    test("earned at 10 rated-with-note entries", () => {
      const m = member({ uid: "u1" });
      const ratings = Array.from({ length: 10 }, (_, i) =>
        rating({ uid: "u1", stars: 4, note: `note ${i}` }));
      const badges = evaluateBadges({ entries: [], members: [m], ratings });
      expect(findBadge(badges, "critic_u1").earned).toBe(true);
    });
  });

  describe("Compromise Champ", () => {
    test("counts only wasCompromise=true decisions", () => {
      const decisions = [
        ...Array.from({ length: 3 }, () =>
          decision({ was_compromise: true })),
        decision({ was_compromise: false }),
      ];
      const badges = evaluateBadges({
        entries: [],
        members: [],
        decisions,
      });
      const b = findBadge(badges, "compromise_champ");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(3);
    });

    test("earned at 5 compromise wins, progress caps", () => {
      const decisions = Array.from({ length: 7 }, () =>
        decision({ was_compromise: true }));
      const badges = evaluateBadges({
        entries: [],
        members: [],
        decisions,
      });
      const b = findBadge(badges, "compromise_champ");
      expect(b.earned).toBe(true);
      expect(b.progress).toBe(5);
    });
  });

  describe("Show Finisher", () => {
    test("only TV entries with completed status count", () => {
      const entries = [
        ...Array.from({ length: 3 }, () =>
          entry({ media_type: "tv", in_progress_status: "completed" })),
        entry({ media_type: "tv", in_progress_status: "dropped" }),
        entry({ media_type: "movie", in_progress_status: "completed" }),
      ];
      const badges = evaluateBadges({ entries, members: [] });
      const b = findBadge(badges, "show_finisher");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(3);
    });

    test("earned at 5 finished shows", () => {
      const entries = Array.from({ length: 6 }, () =>
        entry({ media_type: "tv", in_progress_status: "completed" }));
      const badges = evaluateBadges({ entries, members: [] });
      expect(findBadge(badges, "show_finisher").earned).toBe(true);
    });
  });

  describe("Tagger", () => {
    test("counts only ratings with at least one tag", () => {
      const m = member({ uid: "u1" });
      const ratings = [
        ...Array.from({ length: 5 }, () =>
          rating({ uid: "u1", stars: 4, tags: ["funny"] })),
        rating({ uid: "u1", stars: 4 }),
      ];
      const badges = evaluateBadges({ entries: [], members: [m], ratings });
      const b = findBadge(badges, "tagger_u1");
      expect(b.earned).toBe(false);
      expect(b.progress).toBe(5);
    });

    test("earned at 10 tagged ratings", () => {
      const m = member({ uid: "u1" });
      const ratings = Array.from({ length: 10 }, () =>
        rating({ uid: "u1", stars: 4, tags: ["slow", "beautiful"] }));
      const badges = evaluateBadges({ entries: [], members: [m], ratings });
      expect(findBadge(badges, "tagger_u1").earned).toBe(true);
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
