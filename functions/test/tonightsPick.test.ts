import { pickTonightsPick } from "../src/tonightsPick";

function rec(
  overrides: Partial<Record<string, unknown>> = {},
): Record<string, unknown> {
  return {
    media_type: "movie",
    tmdb_id: 1,
    title: "T",
    match_score: 50,
    ...overrides,
  };
}

describe("pickTonightsPick", () => {
  it("returns the highest-scored rec", () => {
    const out = pickTonightsPick(
      [
        rec({ tmdb_id: 1, match_score: 70 }),
        rec({ tmdb_id: 2, match_score: 90 }),
        rec({ tmdb_id: 3, match_score: 55 }),
      ],
      new Set(),
    );
    expect(out?.tmdb_id).toBe(2);
  });

  it("skips already-watched titles", () => {
    const out = pickTonightsPick(
      [
        rec({ tmdb_id: 1, match_score: 95 }),
        rec({ tmdb_id: 2, match_score: 60 }),
      ],
      new Set(["movie:1"]),
    );
    expect(out?.tmdb_id).toBe(2);
  });

  it("returns null when every candidate is watched", () => {
    const out = pickTonightsPick(
      [
        rec({ tmdb_id: 1 }),
        rec({ tmdb_id: 2 }),
      ],
      new Set(["movie:1", "movie:2"]),
    );
    expect(out).toBeNull();
  });

  it("returns null on empty input", () => {
    expect(pickTonightsPick([], new Set())).toBeNull();
  });

  it("ignores malformed candidate rows", () => {
    const out = pickTonightsPick(
      [
        { media_type: "movie" }, // missing tmdb_id
        { tmdb_id: 1 }, // missing media_type
        rec({ tmdb_id: 2, match_score: 75 }),
      ],
      new Set(),
    );
    expect(out?.tmdb_id).toBe(2);
  });

  it("picks across media types and respects watched-key namespacing", () => {
    const out = pickTonightsPick(
      [
        rec({ media_type: "tv", tmdb_id: 1, match_score: 80 }),
        rec({ media_type: "movie", tmdb_id: 1, match_score: 70 }),
      ],
      new Set(["tv:1"]), // movie:1 should still win
    );
    expect(out?.media_type).toBe("movie");
    expect(out?.tmdb_id).toBe(1);
  });
});
