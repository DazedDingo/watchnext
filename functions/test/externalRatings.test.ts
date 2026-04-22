import { parseOmdbPayload, CACHE_TTL_MS } from "../src/externalRatings";

describe("parseOmdbPayload", () => {
  it("parses a full OMDb payload", () => {
    const raw = {
      Response: "True",
      imdbRating: "8.5",
      imdbVotes: "1,234,567",
      Metascore: "82",
      Ratings: [
        { Source: "Internet Movie Database", Value: "8.5/10" },
        { Source: "Rotten Tomatoes", Value: "92%" },
        { Source: "Metacritic", Value: "82/100" },
      ],
    };
    const out = parseOmdbPayload(raw, "tt0133093");
    expect(out.imdbId).toBe("tt0133093");
    expect(out.imdbRating).toBe(8.5);
    expect(out.imdbVotes).toBe(1234567);
    expect(out.rtRating).toBe(92);
    expect(out.metascore).toBe(82);
    expect(out.source).toBe("omdb");
    expect(out.notFound).toBeUndefined();
    expect(out.fetchedAtMs).toBeGreaterThan(0);
  });

  it("maps N/A fields to null", () => {
    const raw = {
      imdbRating: "N/A",
      imdbVotes: "N/A",
      Metascore: "N/A",
      Ratings: [],
    };
    const out = parseOmdbPayload(raw, "tt9999999");
    expect(out.imdbRating).toBeNull();
    expect(out.imdbVotes).toBeNull();
    expect(out.rtRating).toBeNull();
    expect(out.metascore).toBeNull();
  });

  it("handles missing Ratings array", () => {
    const out = parseOmdbPayload(
      { imdbRating: "7.0" },
      "tt0000001",
    );
    expect(out.rtRating).toBeNull();
    expect(out.imdbRating).toBe(7.0);
  });

  it("strips commas and % from numeric strings", () => {
    const out = parseOmdbPayload(
      {
        imdbVotes: "10,000",
        Ratings: [{ Source: "Rotten Tomatoes", Value: "75%" }],
      },
      "tt1234567",
    );
    expect(out.imdbVotes).toBe(10000);
    expect(out.rtRating).toBe(75);
  });

  it("ignores non-RT entries in Ratings", () => {
    const out = parseOmdbPayload(
      {
        Ratings: [
          { Source: "Metacritic", Value: "70/100" },
          { Source: "Internet Movie Database", Value: "7.2/10" },
        ],
      },
      "tt1234567",
    );
    expect(out.rtRating).toBeNull();
  });
});

describe("CACHE_TTL_MS", () => {
  it("is 7 days", () => {
    expect(CACHE_TTL_MS).toBe(7 * 24 * 60 * 60 * 1000);
  });
});
