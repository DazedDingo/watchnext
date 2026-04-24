/* eslint-disable no-console */
/**
 * Live-API smoke test for the Gemini migration. Hits the real Gemini endpoint
 * (no Firebase dependencies) and walks both call sites end-to-end:
 *
 *   1. scoreRecommendations — system prompt + a 3-candidate batch → parsed
 *      Score[] with every key matching and scores in [0, 100].
 *   2. concierge — system prompt + a conversational turn → parsed JSON with
 *      a `text` field and a titles array (can be empty).
 *
 * Usage:
 *   cd functions
 *   GEMINI_API_KEY=<key> npx ts-node scripts/smoke_gemini.ts
 *
 * Get a free key from https://aistudio.google.com/apikey (free tier: 1,500
 * req/day on gemini-2.5-flash). The script prints the raw Gemini responses
 * alongside the parsed scores so you can eyeball both the model output AND
 * the JSON-parsing path without deploying anything to Firebase.
 */

import { makeGeminiClient, DEFAULT_GEMINI_MODEL } from "../src/ai/gemini";
import {
  buildSystemPrompt,
  buildBatchPrompt,
  parseScores,
  trimProfileForPrompt,
} from "../src/scoreRecommendations";
import { parseResponse, trimProfile, buildContextBlock } from "../src/concierge";

const apiKey = process.env.GEMINI_API_KEY;
if (!apiKey) {
  console.error("GEMINI_API_KEY is not set. Export it and re-run.");
  process.exit(1);
}

const model = process.env.GEMINI_MODEL || DEFAULT_GEMINI_MODEL;
const gemini = makeGeminiClient(apiKey, model);

async function smokeScorer() {
  console.log(`\n=== SCORE smoke test (${model}) ===`);
  const profile = trimProfileForPrompt({
    member_uids: ["uA", "uB"],
    combined: {
      top_genres: [
        { genre: "Drama", weight: 0.4 },
        { genre: "Comedy", weight: 0.3 },
        { genre: "Sci-Fi", weight: 0.2 },
      ],
    },
    per_user: {
      uA: { avg: 4.2, top_genres: [{ genre: "Drama", weight: 0.5 }] },
      uB: { avg: 3.9, top_genres: [{ genre: "Comedy", weight: 0.5 }] },
    },
    per_user_solo: {
      uA: { avg: 4.3, top_genres: [{ genre: "Horror", weight: 0.6 }] },
      uB: { avg: 4.0, top_genres: [{ genre: "Action", weight: 0.5 }] },
    },
    per_user_together: {
      uA: { avg: 4.0, top_genres: [{ genre: "Drama", weight: 0.5 }] },
      uB: { avg: 3.8, top_genres: [{ genre: "Comedy", weight: 0.5 }] },
    },
  });
  const batch = [
    {
      media_type: "movie" as const,
      tmdb_id: 680,
      title: "Pulp Fiction",
      year: 1994,
      genres: ["Crime", "Drama"],
      overview: "A loose anthology of interconnected L.A. crime stories.",
    },
    {
      media_type: "movie" as const,
      tmdb_id: 27205,
      title: "Inception",
      year: 2010,
      genres: ["Sci-Fi", "Thriller"],
      overview: "A thief who enters the dreams of others to steal secrets.",
    },
    {
      media_type: "tv" as const,
      tmdb_id: 1396,
      title: "Breaking Bad",
      year: 2008,
      genres: ["Drama", "Crime"],
      overview: "A chemistry teacher turns to making meth after a cancer diagnosis.",
    },
  ];

  const started = Date.now();
  const raw = await gemini.generate({
    systemInstruction: buildSystemPrompt(profile),
    messages: [{ role: "user", text: buildBatchPrompt(batch) }],
  });
  const elapsed = Date.now() - started;

  console.log(`--- raw response (${elapsed}ms) ---`);
  console.log(raw);
  const parsed = parseScores(raw);
  console.log("--- parsed scores ---");
  for (const s of parsed) {
    console.log(
      `  ${s.key} together=${s.together} solo=${JSON.stringify(s.solo)} blurb="${s.blurb}"`,
    );
  }

  // Contract checks.
  const expectedKeys = batch.map((c) => `${c.media_type}:${c.tmdb_id}`);
  for (const key of expectedKeys) {
    const hit = parsed.find((p) => p.key === key);
    if (!hit) throw new Error(`missing key ${key} in parsed output`);
    if (hit.together < 0 || hit.together > 100)
      throw new Error(`together out of range for ${key}: ${hit.together}`);
    for (const uid of Object.keys(hit.solo)) {
      const v = hit.solo[uid];
      if (v < 0 || v > 100) throw new Error(`solo[${uid}] out of range for ${key}: ${v}`);
    }
    if (!hit.blurb) throw new Error(`missing blurb for ${key}`);
  }
  console.log("OK scorer — all 3 candidates scored, ranges valid, blurbs present");
}

async function smokeConcierge() {
  console.log(`\n=== CONCIERGE smoke test (${model}) ===`);
  const profileBlock = trimProfile(
    {
      combined: {
        top_genres: [
          { genre: "Drama", weight: 0.4 },
          { genre: "Sci-Fi", weight: 0.3 },
        ],
        shared_favorites: [{ title: "Arrival" }, { title: "The Shawshank Redemption" }],
      },
    },
    "uA",
    "together",
  );
  const contextBlock = buildContextBlock(
    profileBlock,
    ["Arrival (2016)", "Parasite (2019)"],
    ["The Bear (2022)"],
    ["The Brutalist (2024)"],
    "together",
    undefined,
  );
  const SYSTEM_PROMPT = `You are a film and TV recommendation assistant for a two-person household.
Be direct and helpful. Always respond with a JSON object: {"text": string, "titles": [{"tmdb_id": int, "media_type": "movie"|"tv", "title": string, "year": int|null, "reason": string}]}.
Return 3-5 titles unless the user explicitly asks otherwise.`;

  const started = Date.now();
  const raw = await gemini.generate({
    systemInstruction: `${SYSTEM_PROMPT}\n\nHOUSEHOLD CONTEXT:\n${contextBlock}`,
    messages: [
      { role: "user", text: "Recommend something we'd both like for tonight — around 2 hours, cerebral." },
    ],
  });
  const elapsed = Date.now() - started;

  console.log(`--- raw response (${elapsed}ms) ---`);
  console.log(raw);
  const parsed = parseResponse(raw);
  console.log("--- parsed concierge response ---");
  console.log(`  text: ${parsed.text}`);
  for (const t of parsed.titles) {
    console.log(
      `  title: ${t.title} (${t.year ?? "?"}) tmdb=${t.tmdb_id} reason="${t.reason}"`,
    );
  }
  if (!parsed.text) throw new Error("concierge missing text");
  console.log("OK concierge — JSON parsed, text + titles populated");
}

(async () => {
  try {
    await smokeScorer();
    await smokeConcierge();
    console.log("\n==> ALL SMOKE TESTS PASSED");
  } catch (err) {
    console.error("\n==> SMOKE FAIL", err);
    process.exit(1);
  }
})();
