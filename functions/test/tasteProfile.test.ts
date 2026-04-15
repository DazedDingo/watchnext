import {
  decadeBucket,
  buildUserProfile,
  compatibility,
} from "../src/tasteProfile";

describe("decadeBucket", () => {
  test("1999 → 1990s", () => {
    expect(decadeBucket(1999)).toBe("1990s");
  });
  test("2020 → 2020s", () => {
    expect(decadeBucket(2020)).toBe("2020s");
  });
  test("2000 → 2000s", () => {
    expect(decadeBucket(2000)).toBe("2000s");
  });
  test("undefined / 0 → null", () => {
    expect(decadeBucket(undefined)).toBeNull();
    expect(decadeBucket(0)).toBeNull();
  });
  test("1800 still buckets (no lower bound enforced)", () => {
    expect(decadeBucket(1874)).toBe("1870s");
  });
});

describe("buildUserProfile", () => {
  const entries = new Map([
    [
      "movie:1",
      {
        media_type: "movie",
        tmdb_id: 1,
        title: "Action One",
        year: 2010,
        runtime: 100,
        genres: ["Action", "Thriller"],
      },
    ],
    [
      "movie:2",
      {
        media_type: "movie",
        tmdb_id: 2,
        title: "Drama One",
        year: 2015,
        runtime: 120,
        genres: ["Drama"],
      },
    ],
    [
      "movie:3",
      {
        media_type: "movie",
        tmdb_id: 3,
        title: "Action Two",
        year: 2018,
        runtime: 110,
        genres: ["Action"],
      },
    ],
    [
      "tv:1",
      {
        media_type: "tv",
        tmdb_id: 1,
        title: "Show",
        year: 2022,
        genres: ["Comedy"],
      },
    ],
  ]);

  test("ignores episode/season level ratings", () => {
    const profile = buildUserProfile(
      "u1",
      [
        { uid: "u1", level: "episode", target_id: "tv:1:1_1", stars: 5 },
        { uid: "u1", level: "season", target_id: "tv:1:s1", stars: 5 },
      ],
      entries,
    );
    expect(profile.rated_count).toBe(0);
    expect(profile.avg_rating).toBe(0);
  });

  test("positive genre weights reflect high ratings", () => {
    const profile = buildUserProfile(
      "u1",
      [
        { uid: "u1", level: "movie", target_id: "movie:1", stars: 5 },
        { uid: "u1", level: "movie", target_id: "movie:3", stars: 5 },
      ],
      entries,
    );
    const action = profile.top_genres.find((g) => g.genre === "Action");
    expect(action).toBeDefined();
    expect(action!.weight).toBeGreaterThan(0);
    expect(action!.rated_count).toBe(2);
  });

  test("top_genres are filtered to count ≥ 2", () => {
    const profile = buildUserProfile(
      "u1",
      [{ uid: "u1", level: "movie", target_id: "movie:2", stars: 5 }],
      entries,
    );
    // Drama appears only once → must be filtered out.
    expect(profile.top_genres).toEqual([]);
  });

  test("4+ stars go to liked, 1-2 stars to disliked, 3 neither", () => {
    const profile = buildUserProfile(
      "u1",
      [
        { uid: "u1", level: "movie", target_id: "movie:1", stars: 5 },
        { uid: "u1", level: "movie", target_id: "movie:2", stars: 3 },
        { uid: "u1", level: "movie", target_id: "movie:3", stars: 2 },
      ],
      entries,
    );
    expect(profile.liked_titles.map((t) => t.tmdb_id)).toEqual([1]);
    expect(profile.disliked_titles.map((t) => t.tmdb_id)).toEqual([3]);
  });

  test("median runtime is the middle value", () => {
    const profile = buildUserProfile(
      "u1",
      [
        { uid: "u1", level: "movie", target_id: "movie:1", stars: 5 }, // 100
        { uid: "u1", level: "movie", target_id: "movie:2", stars: 4 }, // 120
        { uid: "u1", level: "movie", target_id: "movie:3", stars: 4 }, // 110
      ],
      entries,
    );
    expect(profile.median_runtime).toBe(110);
  });

  test("decades aggregated from watch entry years", () => {
    const profile = buildUserProfile(
      "u1",
      [
        { uid: "u1", level: "movie", target_id: "movie:1", stars: 5 }, // 2010
        { uid: "u1", level: "movie", target_id: "movie:2", stars: 5 }, // 2015
        { uid: "u1", level: "movie", target_id: "movie:3", stars: 5 }, // 2018
      ],
      entries,
    );
    expect(profile.decades).toEqual({ "2010s": 3 });
  });

  test("tags accumulate with count", () => {
    const profile = buildUserProfile(
      "u1",
      [
        {
          uid: "u1",
          level: "movie",
          target_id: "movie:1",
          stars: 5,
          tags: ["funny", "rewatch"],
        },
        {
          uid: "u1",
          level: "movie",
          target_id: "movie:3",
          stars: 5,
          tags: ["funny"],
        },
      ],
      entries,
    );
    expect(profile.top_tags).toEqual(
      expect.arrayContaining([
        { tag: "funny", count: 2 },
        { tag: "rewatch", count: 1 },
      ]),
    );
  });

  test("missing watch entry for a rating is skipped silently", () => {
    const profile = buildUserProfile(
      "u1",
      [
        { uid: "u1", level: "movie", target_id: "movie:1", stars: 4 },
        { uid: "u1", level: "movie", target_id: "movie:999", stars: 5 },
      ],
      entries,
    );
    // rated_count still includes the orphan; just no genre/decade impact.
    expect(profile.rated_count).toBe(2);
    expect(profile.decades).toEqual({ "2010s": 1 });
  });

  test("another user's ratings are ignored", () => {
    const profile = buildUserProfile(
      "u1",
      [
        { uid: "u2", level: "movie", target_id: "movie:1", stars: 5 },
      ],
      entries,
    );
    expect(profile.rated_count).toBe(0);
  });
});

describe("compatibility", () => {
  const rating = (uid: string, target: string, stars: number) => ({
    uid,
    level: "movie",
    target_id: target,
    stars,
  });

  test("returns zeros when fewer than 2 uids provided", () => {
    expect(compatibility([rating("u1", "m:1", 5)], ["u1"])).toEqual({
      within_1_star_pct: 0,
      rated_both_count: 0,
    });
  });

  test("counts only titles rated by both users", () => {
    const res = compatibility(
      [
        rating("u1", "m:1", 5),
        rating("u2", "m:1", 5),
        rating("u1", "m:2", 4),
        rating("u2", "m:3", 3),
      ],
      ["u1", "u2"],
    );
    expect(res.rated_both_count).toBe(1);
    expect(res.within_1_star_pct).toBe(1);
  });

  test("within_1_star_pct is fraction within delta ≤ 1", () => {
    const res = compatibility(
      [
        rating("u1", "m:1", 5),
        rating("u2", "m:1", 4), // within
        rating("u1", "m:2", 5),
        rating("u2", "m:2", 3), // not within
        rating("u1", "m:3", 4),
        rating("u2", "m:3", 4), // within
      ],
      ["u1", "u2"],
    );
    expect(res.rated_both_count).toBe(3);
    expect(res.within_1_star_pct).toBeCloseTo(2 / 3);
  });

  test("non-movie/show levels are excluded", () => {
    const res = compatibility(
      [
        { uid: "u1", level: "episode", target_id: "x", stars: 5 },
        { uid: "u2", level: "episode", target_id: "x", stars: 5 },
      ],
      ["u1", "u2"],
    );
    expect(res.rated_both_count).toBe(0);
  });
});
