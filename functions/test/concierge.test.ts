import { trimProfile, buildContextBlock, parseResponse } from "../src/concierge";

describe("trimProfile", () => {
  const profile = {
    combined: {
      top_genres: [
        { genre: "Action", weight: 10 },
        { genre: "Drama", weight: 5 },
        { genre: "Sci-Fi", weight: 4 },
        { genre: "Thriller", weight: 3 },
        { genre: "Comedy", weight: 2 },
        { genre: "Horror", weight: 1 },
        { genre: "Western", weight: 0 },
      ],
      shared_favorites: [
        { title: "The Matrix" },
        { title: "Inception" },
      ],
      compatibility: { within_1_star_pct: 0.75 },
    },
    per_user: {
      u1: {
        top_genres: [{ genre: "Action", weight: 8 }],
        liked_titles: [
          { title: "The Matrix", stars: 5 },
          { title: "Die Hard", stars: 5 },
        ],
        disliked_titles: [{ title: "Bad Movie", stars: 1 }],
        avg_rating: 4.2,
      },
    },
  };

  test("together mode surfaces shared genres + favorites + compat", () => {
    const out = trimProfile(profile, "u1", "together");
    expect(out).toContain("Shared top genres: Action, Drama, Sci-Fi");
    expect(out).toContain("Both loved: The Matrix, Inception");
    expect(out).toContain("Rating agreement: 75% within 1 star");
  });

  test("together mode caps top genres at 6", () => {
    const out = trimProfile(profile, "u1", "together");
    expect(out).toContain("Horror");
    expect(out).not.toContain("Western");
  });

  test("solo mode surfaces per-user profile", () => {
    const out = trimProfile(profile, "u1", "solo");
    expect(out).toContain("Top genres: Action");
    expect(out).toContain("High-rated: The Matrix, Die Hard");
    expect(out).toContain("Low-rated: Bad Movie");
  });

  test("undefined profile returns friendly placeholder", () => {
    expect(trimProfile(undefined, "u1", "together")).toBe(
      "No taste profile yet.",
    );
  });

  test("solo mode with missing per_user returns placeholder", () => {
    expect(trimProfile({ combined: {} }, "u1", "solo")).toBe(
      "No taste profile yet.",
    );
  });

  test("solo mode prefers per_user_solo over per_user when present", () => {
    const out = trimProfile(
      {
        per_user: {
          u1: {
            top_genres: [{ genre: "Drama", weight: 5 }],
            liked_titles: [{ title: "CrossContext", stars: 5 }],
            disliked_titles: [],
            avg_rating: 3.0,
          },
        },
        per_user_solo: {
          u1: {
            top_genres: [{ genre: "Horror", weight: 5 }],
            liked_titles: [{ title: "SoloOnly", stars: 5 }],
            disliked_titles: [],
            avg_rating: 4.5,
          },
        },
      },
      "u1",
      "solo",
    );
    expect(out).toContain("Horror");
    expect(out).toContain("SoloOnly");
    // Cross-context Drama shouldn't leak into the solo summary.
    expect(out).not.toContain("Drama");
    expect(out).not.toContain("CrossContext");
  });

  test("solo mode falls back to per_user when per_user_solo is missing", () => {
    const out = trimProfile(
      {
        per_user: {
          u1: {
            top_genres: [{ genre: "Action", weight: 5 }],
            liked_titles: [{ title: "Legacy", stars: 5 }],
            disliked_titles: [],
            avg_rating: 4.0,
          },
        },
      },
      "u1",
      "solo",
    );
    expect(out).toContain("Action");
    expect(out).toContain("Legacy");
  });

  test("together with no compat key omits the compat line", () => {
    const out = trimProfile(
      {
        combined: {
          top_genres: [{ genre: "Action", weight: 1 }],
          shared_favorites: [],
        },
      },
      "u1",
      "together",
    );
    expect(out).not.toContain("Rating agreement");
  });
});

describe("buildContextBlock", () => {
  test("includes MODE + TASTE PROFILE always", () => {
    const block = buildContextBlock("P", [], [], [], "solo", undefined);
    expect(block).toContain("MODE: SOLO");
    expect(block).toContain("TASTE PROFILE:");
    expect(block).toContain("P");
  });

  test("includes MOOD FILTER line when provided", () => {
    const block = buildContextBlock("P", [], [], [], "together", "funny");
    expect(block).toContain("MOOD FILTER: funny");
  });

  test("omits MOOD FILTER when undefined", () => {
    const block = buildContextBlock("P", [], [], [], "together", undefined);
    expect(block).not.toContain("MOOD FILTER:");
  });

  test("lists each section only when non-empty", () => {
    const block = buildContextBlock(
      "P",
      ["A", "B"],
      ["C"],
      ["D", "E", "F"],
      "together",
      undefined,
    );
    expect(block).toContain("RECENTLY WATCHED (2):\nA, B");
    expect(block).toContain("IN PROGRESS:\nC");
    expect(block).toContain("WATCHLIST (3 titles):\nD, E, F");
  });

  test("empty history/watchlist sections are dropped", () => {
    const block = buildContextBlock("P", [], [], [], "solo", undefined);
    expect(block).not.toContain("RECENTLY WATCHED");
    expect(block).not.toContain("IN PROGRESS");
    expect(block).not.toContain("WATCHLIST");
  });
});

describe("parseResponse", () => {
  test("plain JSON parses", () => {
    const out = parseResponse('{"text": "hi", "titles": []}');
    expect(out.text).toBe("hi");
    expect(out.titles).toEqual([]);
  });

  test("json fence is stripped", () => {
    const out = parseResponse(
      '```json\n{"text": "ok", "titles": [{"tmdb_id": 1, "media_type": "movie", "title": "X", "year": null, "reason": "r"}]}\n```',
    );
    expect(out.text).toBe("ok");
    expect(out.titles).toHaveLength(1);
    expect(out.titles[0].title).toBe("X");
  });

  test("bare triple-backtick fence also stripped", () => {
    const out = parseResponse('```\n{"text": "ok", "titles": []}\n```');
    expect(out.text).toBe("ok");
  });

  test("missing titles field defaults to empty array", () => {
    const out = parseResponse('{"text": "hi"}');
    expect(out.titles).toEqual([]);
  });

  test("missing text field defaults to empty string", () => {
    const out = parseResponse('{"titles": []}');
    expect(out.text).toBe("");
  });

  test("non-array titles becomes empty array", () => {
    const out = parseResponse('{"text": "hi", "titles": "oops"}');
    expect(out.titles).toEqual([]);
  });

  test("malformed JSON throws", () => {
    expect(() => parseResponse("not json at all")).toThrow();
  });
});
