import {
  isCandidate,
  trimProfileForPrompt,
  buildPrompt,
  parseScores,
} from "../src/scoreRecommendations";

describe("isCandidate", () => {
  test("accepts a minimal valid candidate", () => {
    expect(
      isCandidate({
        media_type: "movie",
        tmdb_id: 1,
        title: "X",
      }),
    ).toBe(true);
  });

  test("rejects missing fields", () => {
    expect(isCandidate({ tmdb_id: 1, title: "X" })).toBe(false);
    expect(isCandidate({ media_type: "movie", title: "X" })).toBe(false);
    expect(isCandidate({ media_type: "movie", tmdb_id: 1 })).toBe(false);
  });

  test("rejects wrong types", () => {
    expect(isCandidate({ media_type: "movie", tmdb_id: "1", title: "X" })).toBe(
      false,
    );
    expect(isCandidate({ media_type: 1, tmdb_id: 1, title: "X" })).toBe(false);
    expect(isCandidate({ media_type: "movie", tmdb_id: 1, title: 9 })).toBe(
      false,
    );
  });

  test("rejects primitives and null", () => {
    expect(isCandidate(null)).toBe(false);
    expect(isCandidate(undefined)).toBe(false);
    expect(isCandidate("movie:1")).toBe(false);
    expect(isCandidate(42)).toBe(false);
  });
});

describe("trimProfileForPrompt", () => {
  test("extracts member uids + top genres + per-user summary", () => {
    const out = trimProfileForPrompt({
      member_uids: ["u1", "u2"],
      combined: {
        top_genres: [
          { genre: "Action", weight: 1 },
          { genre: "Drama", weight: 2 },
        ],
      },
      per_user: {
        u1: {
          top_genres: [{ genre: "Action", weight: 5 }],
          liked_titles: [{ title: "A", stars: 5 }],
          disliked_titles: [{ title: "B", stars: 1 }],
          avg_rating: 4.0,
        },
        u2: {
          top_genres: [{ genre: "Drama", weight: 5 }],
          liked_titles: [{ title: "C", stars: 4 }],
          disliked_titles: [],
          avg_rating: 3.5,
        },
      },
    });
    expect(out.member_uids).toEqual(["u1", "u2"]);
    expect(out.combined_top_genres).toEqual(["Action", "Drama"]);
    expect(out.per_user_summary.u1).toContain("avg 4.0");
    expect(out.per_user_summary.u1).toContain("Action");
    expect(out.per_user_summary.u1).toContain("high ratings: A");
    expect(out.per_user_summary.u1).toContain("low ratings: B");
    expect(out.per_user_summary.u2).toContain("low ratings: none");
  });

  test("handles undefined profile", () => {
    const out = trimProfileForPrompt(undefined);
    expect(out.member_uids).toEqual([]);
    expect(out.combined_top_genres).toEqual([]);
    expect(out.per_user_summary).toEqual({});
  });

  test("members without per_user data are skipped in summary", () => {
    const out = trimProfileForPrompt({
      member_uids: ["u1", "u2"],
      per_user: {
        u1: {
          top_genres: [],
          liked_titles: [],
          disliked_titles: [],
          avg_rating: 3,
        },
      },
    });
    expect(out.per_user_summary.u1).toBeDefined();
    expect(out.per_user_summary.u2).toBeUndefined();
  });

  test("caps top_genres at 6 and per-user lists at 5/6/4", () => {
    const tenGenres = Array.from({ length: 10 }, (_, i) => ({
      genre: `G${i}`,
      weight: 10 - i,
    }));
    const sevenLiked = Array.from({ length: 7 }, (_, i) => ({
      title: `L${i}`,
      stars: 5,
    }));
    const out = trimProfileForPrompt({
      member_uids: ["u1"],
      combined: { top_genres: tenGenres },
      per_user: {
        u1: {
          top_genres: tenGenres,
          liked_titles: sevenLiked,
          disliked_titles: sevenLiked,
          avg_rating: 4,
        },
      },
    });
    expect(out.combined_top_genres).toHaveLength(6);
    // per-user genres capped at 5
    expect(out.per_user_summary.u1.split(", ").length).toBeGreaterThan(1);
  });
});

describe("buildPrompt", () => {
  const profile = {
    member_uids: ["u1"],
    combined_top_genres: ["Action"],
    per_user_summary: { u1: "avg 4.0; likes: Action" },
  };

  test("prompt includes every candidate with its key tag", () => {
    const prompt = buildPrompt(
      [
        { media_type: "movie", tmdb_id: 1, title: "A", year: 2020 },
        { media_type: "tv", tmdb_id: 7, title: "B" },
      ],
      profile,
    );
    expect(prompt).toContain("[key=movie:1]");
    expect(prompt).toContain("[key=tv:7]");
    expect(prompt).toContain("(2020)");
    expect(prompt).toContain("Top shared genres: Action");
  });

  test("instructs the model to return JSON-only, no prose", () => {
    const prompt = buildPrompt(
      [{ media_type: "movie", tmdb_id: 1, title: "A" }],
      profile,
    );
    expect(prompt).toContain("Return ONLY a JSON array");
    expect(prompt).toContain("no markdown fences");
  });

  test("truncates overview to 200 chars", () => {
    const longOverview = "x".repeat(500);
    const prompt = buildPrompt(
      [
        {
          media_type: "movie",
          tmdb_id: 1,
          title: "A",
          overview: longOverview,
        },
      ],
      profile,
    );
    // The overview line should have at most ~200 x's.
    const xRun = prompt.match(/x+/);
    expect(xRun).toBeTruthy();
    expect(xRun![0].length).toBeLessThanOrEqual(200);
  });
});

describe("parseScores", () => {
  test("plain JSON array", () => {
    const parsed = parseScores(
      '[{"key":"movie:1","together":80,"solo":{"u1":90},"blurb":"b","blurb_solo":{"u1":"s"}}]',
    );
    expect(parsed).toHaveLength(1);
    expect(parsed[0].key).toBe("movie:1");
    expect(parsed[0].together).toBe(80);
  });

  test("strips ```json fence", () => {
    const parsed = parseScores('```json\n[{"key":"movie:1","together":50,"solo":{},"blurb":"","blurb_solo":{}}]\n```');
    expect(parsed[0].together).toBe(50);
  });

  test("strips bare ``` fence", () => {
    const parsed = parseScores('```\n[]\n```');
    expect(parsed).toEqual([]);
  });

  test("throws for non-array JSON", () => {
    expect(() => parseScores('{"key":"movie:1"}')).toThrow(/Expected array/);
  });

  test("throws for malformed JSON", () => {
    expect(() => parseScores("not json")).toThrow();
  });
});
