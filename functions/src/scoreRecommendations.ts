import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import Anthropic from "@anthropic-ai/sdk";

/**
 * Claude batch scorer — takes a candidate list, reads the household's
 * tasteProfile, and writes scored docs to /households/{id}/recommendations.
 *
 * Contract (per rec doc):
 *   {
 *     media_type, tmdb_id, title, year, poster_path, genres,
 *     match_score,             // 0-100 together (combined taste)
 *     match_score_solo: { uid: 0-100 } per household member,
 *     ai_blurb,                // ~25 words, together-framed
 *     ai_blurb_solo: { uid: "" },
 *     source,                  // "watchlist" | "trending" | "upcoming" | "reddit" | "similar"
 *     generated_at
 *   }
 *
 * Spec-called model `claude-sonnet-4-20250514`; we default to the current
 * Sonnet (`claude-sonnet-4-6`) and allow override via ANTHROPIC_MODEL secret.
 */

const ANTHROPIC_API_KEY = defineSecret("ANTHROPIC_API_KEY");

const DEFAULT_MODEL = "claude-sonnet-4-6";
const BATCH_SIZE = 10;
// Upped from 50 → 100 after the client went to two-phase refresh: the
// spinner no longer blocks on this CF, so scoring ~100 candidates (10
// sequential batches, ~60–120s) is fine. Wider pool matters when narrow
// filters (e.g. "War, 1970–1989") thin the candidates the user actually
// sees after client-side filters run.
const MAX_CANDIDATES = 100;

export type Candidate = {
  media_type: string;
  tmdb_id: number;
  title: string;
  year?: number | null;
  poster_path?: string | null;
  genres?: string[];
  /** Runtime in minutes. Missing for trending-sourced candidates. */
  runtime?: number | null;
  overview?: string | null;
  source?: string;
};

type Score = {
  key: string;
  together: number;
  solo: Record<string, number>;
  blurb: string;
  blurb_solo: Record<string, string>;
};

export function isCandidate(x: unknown): x is Candidate {
  if (typeof x !== "object" || x === null) return false;
  const c = x as Record<string, unknown>;
  return typeof c.media_type === "string" && typeof c.tmdb_id === "number" &&
    typeof c.title === "string";
}

type PromptUserProfile = {
  top_genres?: { genre: string; weight: number }[];
  liked_titles?: { title: string; stars: number }[];
  disliked_titles?: { title: string; stars: number }[];
  avg_rating?: number;
};

function summarizeUserProfile(p: PromptUserProfile | undefined): string | null {
  if (!p) return null;
  const genres =
    (p.top_genres ?? []).slice(0, 5).map((g) => g.genre).join(", ");
  const liked =
    (p.liked_titles ?? []).slice(0, 6).map((t) => t.title).join(", ");
  const disliked =
    (p.disliked_titles ?? []).slice(0, 4).map((t) => t.title).join(", ");
  return (
    `avg ${p.avg_rating?.toFixed(1) ?? "?"}; likes: ${genres || "n/a"}; ` +
    `high ratings: ${liked || "none"}; low ratings: ${disliked || "none"}`
  );
}

export function trimProfileForPrompt(
  profile: admin.firestore.DocumentData | undefined,
): {
  member_uids: string[];
  combined_top_genres: string[];
  /** Cross-context summary — kept as a fallback and for together scoring when
   * no per-mode slot is present (legacy tasteProfile docs predate the split). */
  per_user_summary: Record<string, string>;
  /** Summary built from ratings filtered to `context='solo' OR null`. */
  per_user_solo_summary: Record<string, string>;
  /** Summary built from ratings filtered to `context='together' OR null`. */
  per_user_together_summary: Record<string, string>;
} {
  const member_uids: string[] =
    (profile?.member_uids as string[] | undefined) ?? [];
  const combined_top_genres =
    ((profile?.combined?.top_genres as { genre: string }[] | undefined) ?? [])
      .slice(0, 6)
      .map((g) => g.genre);

  const perUser =
    (profile?.per_user ?? {}) as Record<string, PromptUserProfile>;
  const perUserSolo =
    (profile?.per_user_solo ?? {}) as Record<string, PromptUserProfile>;
  const perUserTogether =
    (profile?.per_user_together ?? {}) as Record<string, PromptUserProfile>;

  const per_user_summary: Record<string, string> = {};
  const per_user_solo_summary: Record<string, string> = {};
  const per_user_together_summary: Record<string, string> = {};
  for (const uid of member_uids) {
    const allSummary = summarizeUserProfile(perUser[uid]);
    if (allSummary) per_user_summary[uid] = allSummary;
    // Per-mode slot, with graceful fallback to the cross-context summary when
    // the profile doc predates the split (rollout back-compat).
    const soloSummary =
      summarizeUserProfile(perUserSolo[uid]) ?? allSummary;
    if (soloSummary) per_user_solo_summary[uid] = soloSummary;
    const togetherSummary =
      summarizeUserProfile(perUserTogether[uid]) ?? allSummary;
    if (togetherSummary) per_user_together_summary[uid] = togetherSummary;
  }
  return {
    member_uids,
    combined_top_genres,
    per_user_summary,
    per_user_solo_summary,
    per_user_together_summary,
  };
}

export function buildPrompt(
  batch: Candidate[],
  profile: ReturnType<typeof trimProfileForPrompt>,
): string {
  const memberLines = profile.member_uids
    .map((u) => {
      const together =
        profile.per_user_together_summary[u] ??
        profile.per_user_summary[u] ??
        "no data";
      const solo =
        profile.per_user_solo_summary[u] ??
        profile.per_user_summary[u] ??
        "no data";
      return (
        `- ${u}:\n` +
        `    together-context taste: ${together}\n` +
        `    solo-context taste: ${solo}`
      );
    })
    .join("\n");
  const candidateLines = batch
    .map((c, i) => {
      const parts = [
        `#${i + 1} ${c.title}`,
        c.year ? `(${c.year})` : "",
        c.genres?.length ? `— ${c.genres.slice(0, 3).join(", ")}` : "",
      ].filter(Boolean).join(" ");
      const overview = c.overview?.slice(0, 200) ?? "";
      return `${parts} [key=${c.media_type}:${c.tmdb_id}]\n${overview}`;
    })
    .join("\n\n");

  return `You score movie/TV candidates for a two-person household.

Each member has TWO taste profiles — one built from ratings made while
watching together with their partner, and one from ratings made while watching
solo. Use the together-context taste for the \`together\` score and each
member's solo-context taste for their own \`solo\` score.

HOUSEHOLD TASTE PROFILE:
Top shared genres: ${profile.combined_top_genres.join(", ") || "unknown"}
Members:
${memberLines}

CANDIDATES:
${candidateLines}

For each candidate, return a JSON object with:
- key: the [key=...] value from the candidate line
- together: 0-100 score for how well this fits the household watching together (use each member's together-context taste)
- solo: { "<uid>": 0-100 } one score per member uid listed above (use that member's solo-context taste)
- blurb: ≤25 words, framed for both members ("you'll both enjoy..." / "a bit of a stretch for X but Y will love...")
- blurb_solo: { "<uid>": "≤20 words, addressed to that member" }

Return ONLY a JSON array of these objects, no prose, no markdown fences. Output must parse as valid JSON.`;
}

export function parseScores(text: string): Score[] {
  // Strip ```json ... ``` if the model adds fences despite instructions.
  const cleaned = text.trim().replace(/^```(?:json)?/i, "").replace(/```$/, "").trim();
  const parsed = JSON.parse(cleaned);
  if (!Array.isArray(parsed)) throw new Error("Expected array");
  return parsed as Score[];
}

/**
 * Runs the Claude batch-scoring loop over `candidates` and writes one doc per
 * candidate to /households/{householdId}/recommendations. Batches that error
 * out are skipped (logged) rather than failing the whole run — individual
 * candidates in a failed batch fall back to the default 50 score.
 *
 * Shared between the user-triggered `scoreRecommendations` callable (fresh
 * candidate lists from the client) and the scheduled `processRescoreQueue`
 * drain (re-scoring existing recs after new ratings land).
 */
export async function scoreAndWriteCandidates(params: {
  db: admin.firestore.Firestore;
  anthropic: Anthropic;
  householdId: string;
  candidates: Candidate[];
  profile: ReturnType<typeof trimProfileForPrompt>;
  model: string;
}): Promise<{ written: number; scored: number }> {
  const { db, anthropic, householdId, candidates, profile, model } = params;
  const allScores = new Map<string, Score>();
  for (let i = 0; i < candidates.length; i += BATCH_SIZE) {
    const batch = candidates.slice(i, i + BATCH_SIZE);
    const prompt = buildPrompt(batch, profile);
    let scores: Score[] = [];
    try {
      const res = await anthropic.messages.create({
        model,
        max_tokens: 2000,
        messages: [{ role: "user", content: prompt }],
      });
      const block = res.content.find((b) => b.type === "text");
      if (block && "text" in block) {
        scores = parseScores(block.text);
      }
    } catch (err) {
      console.error("Claude batch failed", { batchStart: i, err });
      continue;
    }
    for (const s of scores) allScores.set(s.key, s);
  }

  const writer = db.bulkWriter();
  const now = admin.firestore.FieldValue.serverTimestamp();
  let written = 0;
  for (const c of candidates) {
    const key = `${c.media_type}:${c.tmdb_id}`;
    const score = allScores.get(key);
    const doc = {
      media_type: c.media_type,
      tmdb_id: c.tmdb_id,
      title: c.title,
      year: c.year ?? null,
      poster_path: c.poster_path ?? null,
      genres: c.genres ?? [],
      runtime: c.runtime ?? null,
      source: c.source ?? "unknown",
      match_score: score?.together ?? 50,
      match_score_solo: score?.solo ?? {},
      ai_blurb: score?.blurb ?? "",
      ai_blurb_solo: score?.blurb_solo ?? {},
      scored: !!score,
      generated_at: now,
    };
    writer.set(
      db.doc(`households/${householdId}/recommendations/${key}`),
      doc,
      { merge: true },
    );
    written += 1;
  }
  await writer.close();
  return { written, scored: allScores.size };
}

export const scoreRecommendations = onCall(
  { secrets: [ANTHROPIC_API_KEY], timeoutSeconds: 540, region: "europe-west2" },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
    const householdId = request.data?.householdId;
    if (typeof householdId !== "string" || !householdId) {
      throw new HttpsError("invalid-argument", "Missing householdId.");
    }
    const rawCandidates = request.data?.candidates;
    if (!Array.isArray(rawCandidates) || rawCandidates.length === 0) {
      throw new HttpsError("invalid-argument", "Missing candidates.");
    }
    const candidates: Candidate[] = rawCandidates.filter(isCandidate).slice(
      0,
      MAX_CANDIDATES,
    );
    if (!candidates.length) {
      throw new HttpsError("invalid-argument", "No valid candidates.");
    }

    const db = admin.firestore();
    const memberSnap = await db
      .doc(`households/${householdId}/members/${uid}`)
      .get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "Not a household member.");
    }

    const profileSnap = await db
      .doc(`households/${householdId}/tasteProfile/default`)
      .get();
    const profileSummary = trimProfileForPrompt(profileSnap.data());

    const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY.value() });
    const model = process.env.ANTHROPIC_MODEL || DEFAULT_MODEL;

    let written: number;
    let scored: number;
    try {
      ({ written, scored } = await scoreAndWriteCandidates({
        db,
        anthropic,
        householdId,
        candidates,
        profile: profileSummary,
        model,
      }));
    } catch (err) {
      console.error("scoreAndWriteCandidates failed", { householdId, err });
      throw new HttpsError("internal", "Failed to persist recommendations.");
    }
    return { ok: true, written, scored, model };
  },
);
