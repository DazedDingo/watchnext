import { extractTitle, resolveGenres } from "../src/redditScraper";

describe("extractTitle", () => {
  describe("Pattern 1: Title (year)", () => {
    test("Inception (2010) → Inception", () => {
      expect(extractTitle("Inception (2010)")).toBe("Inception");
    });
    test("The Matrix (1999) wins over other patterns", () => {
      expect(extractTitle("The Matrix (1999) still holds up")).toBe(
        "The Matrix",
      );
    });
    test("Requires 4-digit year", () => {
      expect(extractTitle("Title (999)")).not.toBe("Title");
    });
  });

  describe("Pattern 2: Title - / : / ?", () => {
    test("Oppenheimer - was it worth the hype?", () => {
      expect(extractTitle("Oppenheimer - was it worth the hype?")).toBe(
        "Oppenheimer",
      );
    });
    test("The Bear: season 3 review", () => {
      expect(extractTitle("The Bear: season 3 review")).toBe("The Bear");
    });
    test("What did you think of Breaking Bad?", () => {
      // Starts with capital W but the rest fits pattern 3.
      const r = extractTitle("What did you think of Breaking Bad?");
      expect(r).toBeTruthy();
    });
  });

  describe("Leading [TAG] markers", () => {
    test("[DISCUSSION] Severance - amazing", () => {
      expect(extractTitle("[DISCUSSION] Severance - amazing")).toBe(
        "Severance",
      );
    });
    test("[SPOILERS] The Sopranos (1999)", () => {
      expect(extractTitle("[SPOILERS] The Sopranos (1999)")).toBe(
        "The Sopranos",
      );
    });
  });

  describe("Returns null when nothing matches", () => {
    test("all lowercase text", () => {
      expect(extractTitle("what's a good movie")).toBeNull();
    });
    test("just a tag", () => {
      expect(extractTitle("[META]")).toBeNull();
    });
    test("empty string", () => {
      expect(extractTitle("")).toBeNull();
    });
  });

  describe("Handles apostrophes, ampersands, colons in title", () => {
    test("O'Brother apostrophe in title", () => {
      const r = extractTitle("O'Brother Where Art Thou (2000)");
      expect(r).toBe("O'Brother Where Art Thou");
    });
    test("Law & Order ampersand", () => {
      const r = extractTitle("Law & Order (1990)");
      expect(r).toBe("Law & Order");
    });
  });

  describe("Doesn't over-capture", () => {
    test("long sentences after title stop at separator", () => {
      const r = extractTitle("Dune, the best sci-fi ever made in decades");
      expect(r).toBe("Dune");
    });
  });
});

describe("resolveGenres", () => {
  test("movie ids → names (Documentary, Drama)", () => {
    expect(resolveGenres([99, 18], "movie")).toEqual(["Documentary", "Drama"]);
  });

  test("tv ids → names (Action & Adventure, Documentary)", () => {
    expect(resolveGenres([10759, 99], "tv")).toEqual([
      "Action & Adventure",
      "Documentary",
    ]);
  });

  test("unknown ids are silently dropped", () => {
    expect(resolveGenres([99999, 28], "movie")).toEqual(["Action"]);
  });

  test("undefined ids → empty list", () => {
    expect(resolveGenres(undefined, "movie")).toEqual([]);
  });

  test("empty ids → empty list", () => {
    expect(resolveGenres([], "tv")).toEqual([]);
  });

  test("movie-only id (37 Western) resolves under movie but also under tv (shared)", () => {
    expect(resolveGenres([37], "movie")).toEqual(["Western"]);
    expect(resolveGenres([37], "tv")).toEqual(["Western"]);
  });

  test("movie domain does not use tv-only id (10759)", () => {
    expect(resolveGenres([10759], "movie")).toEqual([]);
  });

  test("tv domain does not use movie-only id (28 Action)", () => {
    // 28 is movie-only; on tv you would see 10759 Action & Adventure.
    expect(resolveGenres([28], "tv")).toEqual([]);
  });

  test("Documentary (99) resolves in both domains — needed for mood match", () => {
    expect(resolveGenres([99], "movie")).toEqual(["Documentary"]);
    expect(resolveGenres([99], "tv")).toEqual(["Documentary"]);
  });
});
