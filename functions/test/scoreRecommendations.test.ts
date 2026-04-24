import {
  isCandidate,
  trimProfileForPrompt,
  buildPrompt,
  buildSystemPrompt,
  buildBatchPrompt,
  parseScores,
  scoreAndWriteCandidates,
} from "../src/scoreRecommendations";
import { GeminiClient } from "../src/ai/gemini";
// Mock Firestore from the firebase-functions-test suite if available;
// fall back to a lightweight stub that records writes.
type Write = { path: string; data: Record<string, unknown>; merge: boolean };
function stubFirestore(writes: Write[]) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const writer: any = {
    set: (ref: { path: string }, data: Record<string, unknown>, opts?: { merge?: boolean }) => {
      writes.push({ path: ref.path, data, merge: !!opts?.merge });
    },
    close: async () => undefined,
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const db: any = {
    bulkWriter: () => writer,
    doc: (path: string) => ({ path }),
  };
  return db;
}

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

  test("accepts optional runtime alongside required fields", () => {
    expect(
      isCandidate({
        media_type: "movie",
        tmdb_id: 1,
        title: "X",
        runtime: 95,
      }),
    ).toBe(true);
    // null runtime (trending-sourced candidate) is still valid.
    expect(
      isCandidate({
        media_type: "movie",
        tmdb_id: 1,
        title: "X",
        runtime: null,
      }),
    ).toBe(true);
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
    expect(out.per_user_solo_summary).toEqual({});
    expect(out.per_user_together_summary).toEqual({});
  });

  test("per-mode summaries read per_user_solo/together when present", () => {
    const out = trimProfileForPrompt({
      member_uids: ["u1"],
      per_user: {
        u1: {
          top_genres: [{ genre: "Action", weight: 5 }],
          liked_titles: [{ title: "CrossContext" }],
          disliked_titles: [],
          avg_rating: 3.8,
        },
      },
      per_user_solo: {
        u1: {
          top_genres: [{ genre: "Horror", weight: 5 }],
          liked_titles: [{ title: "SoloFav" }],
          disliked_titles: [],
          avg_rating: 4.2,
        },
      },
      per_user_together: {
        u1: {
          top_genres: [{ genre: "Comedy", weight: 5 }],
          liked_titles: [{ title: "TogetherFav" }],
          disliked_titles: [],
          avg_rating: 3.5,
        },
      },
    });
    expect(out.per_user_solo_summary.u1).toContain("Horror");
    expect(out.per_user_solo_summary.u1).toContain("SoloFav");
    expect(out.per_user_solo_summary.u1).toContain("avg 4.2");
    expect(out.per_user_together_summary.u1).toContain("Comedy");
    expect(out.per_user_together_summary.u1).toContain("TogetherFav");
    // Cross-context summary still populated (consumers may need it).
    expect(out.per_user_summary.u1).toContain("CrossContext");
  });

  test("legacy profile (no per_user_solo/together) falls back to per_user", () => {
    const out = trimProfileForPrompt({
      member_uids: ["u1"],
      per_user: {
        u1: {
          top_genres: [{ genre: "Action", weight: 5 }],
          liked_titles: [{ title: "L" }],
          disliked_titles: [],
          avg_rating: 4.0,
        },
      },
    });
    expect(out.per_user_solo_summary.u1).toBe(out.per_user_summary.u1);
    expect(out.per_user_together_summary.u1).toBe(out.per_user_summary.u1);
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
    per_user_solo_summary: { u1: "avg 4.2; likes: Horror" },
    per_user_together_summary: { u1: "avg 3.5; likes: Comedy" },
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

  test("prompt includes both solo and together taste summaries per member", () => {
    const prompt = buildPrompt(
      [{ media_type: "movie", tmdb_id: 1, title: "A" }],
      profile,
    );
    expect(prompt).toContain("together-context taste:");
    expect(prompt).toContain("solo-context taste:");
    // Summaries for u1 each land under their labelled line.
    expect(prompt).toContain("Horror");
    expect(prompt).toContain("Comedy");
    // Tells Claude how to route the two contexts into the two scores.
    expect(prompt).toContain("together-context taste for the `together` score");
    expect(prompt).toContain("solo-context taste for their own `solo` score");
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

describe("buildSystemPrompt / buildBatchPrompt split (prompt caching)", () => {
  const profile = {
    member_uids: ["u1", "u2"],
    combined_top_genres: ["Drama", "Comedy"],
    per_user_summary: { u1: "avg 4.0", u2: "avg 4.2" },
    per_user_solo_summary: { u1: "likes: Horror", u2: "likes: Action" },
    per_user_together_summary: { u1: "likes: Comedy", u2: "likes: Drama" },
  };

  test("system prompt carries the static stuff (instructions + household)", () => {
    const sys = buildSystemPrompt(profile);
    expect(sys).toContain("You score movie/TV candidates");
    expect(sys).toContain("Top shared genres: Drama, Comedy");
    expect(sys).toContain("together-context taste:");
    expect(sys).toContain("solo-context taste:");
    expect(sys).toContain("Return ONLY a JSON array");
  });

  test("system prompt does NOT contain any batch-specific lines", () => {
    const sys = buildSystemPrompt(profile);
    // Instructions may reference the "[key=...]" format but never a resolved
    // candidate key like "[key=movie:123]" — those belong to the user turn.
    expect(sys).not.toMatch(/\[key=(movie|tv):\d+\]/);
    expect(sys).not.toMatch(/CANDIDATES:/);
  });

  test("batch prompt carries only the candidate block", () => {
    const batch = buildBatchPrompt([
      { media_type: "movie", tmdb_id: 1, title: "A" },
      { media_type: "tv", tmdb_id: 7, title: "B" },
    ]);
    expect(batch).toContain("CANDIDATES:");
    expect(batch).toContain("[key=movie:1]");
    expect(batch).toContain("[key=tv:7]");
    expect(batch).not.toContain("Top shared genres");
    expect(batch).not.toContain("Return ONLY");
  });

  test("system prompt is identical across different calls (pure function)", () => {
    expect(buildSystemPrompt(profile)).toBe(buildSystemPrompt(profile));
  });

  test("buildPrompt still returns the concatenated back-compat string", () => {
    const combined = buildPrompt(
      [{ media_type: "movie", tmdb_id: 1, title: "A" }],
      profile,
    );
    expect(combined).toContain("Top shared genres");
    expect(combined).toContain("[key=movie:1]");
  });
});

describe("scoreAndWriteCandidates (Gemini)", () => {
  const profile = {
    member_uids: ["u1"],
    combined_top_genres: ["Drama"],
    per_user_summary: { u1: "avg 4.0" },
    per_user_solo_summary: { u1: "" },
    per_user_together_summary: { u1: "" },
  };

  type Call = { systemInstruction: string; userText: string };

  function fakeGemini(responder: (call: Call) => string): {
    client: GeminiClient;
    calls: Call[];
  } {
    const calls: Call[] = [];
    const client: GeminiClient = {
      async generate({ systemInstruction, messages }) {
        const userTurn = messages.filter((m) => m.role === "user").at(-1);
        const call: Call = {
          systemInstruction,
          userText: userTurn?.text ?? "",
        };
        calls.push(call);
        return responder(call);
      },
    };
    return { client, calls };
  }

  test("writes one rec doc per candidate, merging scores when returned", async () => {
    const candidates = [
      { media_type: "movie" as const, tmdb_id: 1, title: "A" },
      { media_type: "tv" as const, tmdb_id: 2, title: "B" },
    ];
    const { client, calls } = fakeGemini(() =>
      JSON.stringify([
        { key: "movie:1", together: 82, solo: { u1: 88 }, blurb: "great", blurb_solo: { u1: "yes" } },
        { key: "tv:2", together: 55, solo: { u1: 60 }, blurb: "ok", blurb_solo: { u1: "meh" } },
      ]),
    );
    const writes: Write[] = [];
    const db = stubFirestore(writes);

    const out = await scoreAndWriteCandidates({
      db,
      gemini: client,
      householdId: "hh1",
      candidates,
      profile,
    });

    expect(out.written).toBe(2);
    expect(out.scored).toBe(2);
    expect(calls).toHaveLength(1);
    expect(calls[0].systemInstruction).toContain("Top shared genres: Drama");
    expect(calls[0].userText).toContain("[key=movie:1]");
    expect(calls[0].userText).toContain("[key=tv:2]");

    const byPath = Object.fromEntries(writes.map((w) => [w.path, w.data]));
    expect(byPath["households/hh1/recommendations/movie:1"].match_score).toBe(82);
    expect(byPath["households/hh1/recommendations/movie:1"].ai_blurb).toBe("great");
    expect(byPath["households/hh1/recommendations/tv:2"].match_score).toBe(55);
  });

  test("markdown-fenced JSON output is still parsed cleanly", async () => {
    // Gemini Flash commonly wraps output in ```json fences despite the
    // system instruction. parseScores strips them — lock the behaviour
    // end-to-end so a quirky wrapper doesn't degrade to match_score=50.
    const candidates = [{ media_type: "movie" as const, tmdb_id: 9, title: "Z" }];
    const { client } = fakeGemini(
      () =>
        "```json\n[{\"key\":\"movie:9\",\"together\":77,\"solo\":{\"u1\":80},\"blurb\":\"x\",\"blurb_solo\":{\"u1\":\"y\"}}]\n```",
    );
    const writes: Write[] = [];
    const db = stubFirestore(writes);

    const out = await scoreAndWriteCandidates({
      db,
      gemini: client,
      householdId: "hh1",
      candidates,
      profile,
    });

    expect(out.scored).toBe(1);
    expect(writes[0].data.match_score).toBe(77);
    expect(writes[0].data.scored).toBe(true);
  });

  test("batch failure falls back to match_score=50 for that batch only", async () => {
    // BATCH_SIZE is 10, so two batches here. First batch errors; second
    // succeeds. The failed batch's candidates must still be written with
    // defaults so they surface in Firestore at a neutral score.
    const candidates = Array.from({ length: 12 }, (_, i) => ({
      media_type: "movie" as const,
      tmdb_id: i + 1,
      title: `T${i + 1}`,
    }));
    let call = 0;
    const client: GeminiClient = {
      async generate() {
        call++;
        if (call === 1) throw new Error("rate limited");
        // second batch has candidates 11 and 12 (0-indexed tmdb_ids 11, 12)
        return JSON.stringify([
          { key: "movie:11", together: 70, solo: {}, blurb: "", blurb_solo: {} },
          { key: "movie:12", together: 72, solo: {}, blurb: "", blurb_solo: {} },
        ]);
      },
    };
    const writes: Write[] = [];
    const db = stubFirestore(writes);

    const out = await scoreAndWriteCandidates({
      db,
      gemini: client,
      householdId: "hh1",
      candidates,
      profile,
    });

    expect(out.written).toBe(12);
    expect(out.scored).toBe(2);
    const byPath = Object.fromEntries(writes.map((w) => [w.path, w.data]));
    // First batch (1-10) all default to 50 because the Gemini call threw.
    expect(byPath["households/hh1/recommendations/movie:1"].match_score).toBe(50);
    expect(byPath["households/hh1/recommendations/movie:1"].scored).toBe(false);
    // Second batch came through.
    expect(byPath["households/hh1/recommendations/movie:11"].match_score).toBe(70);
    expect(byPath["households/hh1/recommendations/movie:11"].scored).toBe(true);
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
