import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";

import { GEMINI_API_KEY } from "./scoreRecommendations";
import { DEFAULT_GEMINI_MODEL, makeGeminiClient } from "./ai/gemini";

/**
 * Conversational AI concierge (Phase 8).
 *
 * Receives a user message + recent conversation history from the client,
 * builds a rich household-context prompt, calls Gemini, and returns a
 * structured response with a text reply and 3-5 tappable title suggestions.
 *
 * Session turns are persisted to /households/{hh}/conciergeHistory so the
 * chat survives app restarts.
 *
 * Migrated off Anthropic to Gemini 2.5 Flash (free tier). See CLAUDE.md
 * gotcha 16.
 */

const MODEL = DEFAULT_GEMINI_MODEL;

const SYSTEM_PROMPT = `You are a film and TV recommendation assistant for a two-person household.
Be direct and helpful. No filler, no cheerfulness, no personality quirks.
When asked for suggestions, always return 3-5 specific titles.
When the user refines ("make it shorter", "something sci-fi"), adjust accordingly.

Always respond with a JSON object — no markdown fences, no prose outside the object:
{
  "text": "1-3 sentence direct response",
  "titles": [
    {
      "tmdb_id": <integer TMDB id>,
      "media_type": "movie" | "tv",
      "title": "<exact title>",
      "year": <integer or null>,
      "reason": "<≤15 word explanation tailored to this household>"
    }
  ]
}
Return 3-5 titles unless the user explicitly asks for a different number.
If the question is conversational and no specific titles are appropriate, return an empty titles array.`;

type HistoryTurn = { user: string; assistant: string };

type TitleSuggestion = {
  tmdb_id: number;
  media_type: "movie" | "tv";
  title: string;
  year: number | null;
  reason: string;
};

type ConciergeResponse = {
  text: string;
  titles: TitleSuggestion[];
};

export function trimProfile(
  profile: admin.firestore.DocumentData | undefined,
  uid: string,
  mode: string,
): string {
  if (!profile) return "No taste profile yet.";

  const combined = profile.combined as {
    top_genres?: { genre: string; weight: number }[];
    shared_favorites?: { title: string }[];
    compatibility?: { within_1_star_pct: number };
    avg_rating?: number;
  } | undefined;

  type UserSlot = {
    top_genres?: { genre: string; weight: number }[];
    liked_titles?: { title: string; stars: number }[];
    disliked_titles?: { title: string }[];
    avg_rating?: number;
  };

  const perUser = profile.per_user as Record<string, UserSlot> | undefined;
  // Signal-separation slot: solo chat prefers the user's solo-context taste so
  // recommendations don't lean on together-only watches. Legacy tasteProfile
  // docs predate the split — fall back to per_user when missing.
  const perUserSolo =
    profile.per_user_solo as Record<string, UserSlot> | undefined;

  const lines: string[] = [];

  if (mode === "together" && combined) {
    const genres = (combined.top_genres ?? []).slice(0, 6).map(g => g.genre).join(", ");
    const favs = (combined.shared_favorites ?? []).slice(0, 5).map(f => f.title).join(", ");
    const compat = combined.compatibility?.within_1_star_pct;
    lines.push(`Shared top genres: ${genres || "n/a"}`);
    if (favs) lines.push(`Both loved: ${favs}`);
    if (compat != null) lines.push(`Rating agreement: ${Math.round(compat * 100)}% within 1 star`);
  } else {
    const p = perUserSolo?.[uid] ?? perUser?.[uid];
    if (p) {
      const genres = (p.top_genres ?? []).slice(0, 6).map(g => g.genre).join(", ");
      const liked = (p.liked_titles ?? []).slice(0, 6).map(t => t.title).join(", ");
      const disliked = (p.disliked_titles ?? []).slice(0, 3).map(t => t.title).join(", ");
      lines.push(`Top genres: ${genres || "n/a"}`);
      if (liked) lines.push(`High-rated: ${liked}`);
      if (disliked) lines.push(`Low-rated: ${disliked}`);
    }
  }

  return lines.join("\n") || "No taste profile yet.";
}

export function buildContextBlock(
  profile: string,
  recentWatched: string[],
  inProgress: string[],
  watchlist: string[],
  mode: string,
  moodLabel: string | undefined,
): string {
  const parts = [
    `MODE: ${mode.toUpperCase()}`,
    moodLabel ? `MOOD FILTER: ${moodLabel}` : null,
    `\nTASTE PROFILE:\n${profile}`,
    recentWatched.length
      ? `\nRECENTLY WATCHED (${recentWatched.length}):\n${recentWatched.join(", ")}`
      : null,
    inProgress.length
      ? `\nIN PROGRESS:\n${inProgress.join(", ")}`
      : null,
    watchlist.length
      ? `\nWATCHLIST (${watchlist.length} titles):\n${watchlist.join(", ")}`
      : null,
  ];
  return parts.filter(Boolean).join("\n");
}

export function parseResponse(text: string): ConciergeResponse {
  // Gemini (like Claude before it) sometimes wraps the required JSON in prose
  // ("Here you go: { ... }") or adds a trailing sentence. Strip markdown
  // fences first, then extract the outermost JSON object by scanning for the
  // first top-level { ... } pair — depth-counted so nested braces inside
  // strings/values don't confuse us.
  const fenced = text.trim()
    .replace(/^```(?:json)?/i, "")
    .replace(/```$/, "")
    .trim();

  const start = fenced.indexOf("{");
  if (start < 0) throw new Error("No JSON object in LLM response.");

  let depth = 0;
  let end = -1;
  let inString = false;
  let escape = false;
  for (let i = start; i < fenced.length; i++) {
    const ch = fenced[i];
    if (escape) { escape = false; continue; }
    if (inString) {
      if (ch === "\\") escape = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') { inString = true; continue; }
    if (ch === "{") depth++;
    else if (ch === "}") {
      depth--;
      if (depth === 0) { end = i; break; }
    }
  }
  if (end < 0) throw new Error("Unterminated JSON object in LLM response.");

  const parsed = JSON.parse(fenced.slice(start, end + 1)) as ConciergeResponse;
  return {
    text: parsed.text ?? "",
    titles: Array.isArray(parsed.titles) ? parsed.titles : [],
  };
}

export const concierge = onCall(
  { secrets: [GEMINI_API_KEY], region: "europe-west2", timeoutSeconds: 60 },
  async (request) => {
    const uid = request.auth?.uid;
    if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");

    const { householdId, message, sessionId, mode, moodLabel, history } =
      request.data as {
        householdId: string;
        message: string;
        sessionId: string;
        mode: "solo" | "together";
        moodLabel?: string;
        history: HistoryTurn[];
      };

    if (!householdId || !message || !sessionId) {
      throw new HttpsError("invalid-argument", "Missing required fields.");
    }
    if (typeof message !== "string" || message.length > 1500) {
      throw new HttpsError("invalid-argument", "Message too long (max 1500 chars).");
    }

    const db = admin.firestore();

    // Gate on membership.
    const memberSnap = await db.doc(`households/${householdId}/members/${uid}`).get();
    if (!memberSnap.exists) {
      throw new HttpsError("permission-denied", "Not a household member.");
    }

    // Load context data in parallel.
    const [profileSnap, entriesSnap, watchlistSnap] = await Promise.all([
      db.doc(`households/${householdId}/tasteProfile/default`).get(),
      db.collection(`households/${householdId}/watchEntries`)
        .orderBy("last_watched_at", "desc")
        .limit(50)
        .get(),
      db.collection(`households/${householdId}/watchlist`)
        .orderBy("added_at", "desc")
        .limit(30)
        .get(),
    ]);

    const profile = trimProfile(profileSnap.data(), uid, mode);

    const recentWatched: string[] = [];
    const inProgress: string[] = [];
    for (const doc of entriesSnap.docs) {
      const d = doc.data();
      const label = `${d.title as string}${d.year ? ` (${d.year})` : ""}`;
      if (d.in_progress_status === "watching") {
        inProgress.push(label);
      } else {
        recentWatched.push(label);
      }
    }

    const watchlist = watchlistSnap.docs.map((doc) => {
      const d = doc.data();
      return `${d.title as string}${d.year ? ` (${d.year})` : ""}`;
    });

    const contextBlock = buildContextBlock(
      profile,
      recentWatched.slice(0, 20),
      inProgress,
      watchlist,
      mode,
      moodLabel,
    );

    // Build turn list from history + current message. Gemini uses "model"
    // for assistant turns (vs Anthropic's "assistant"); the wrapper converts
    // these to Content parts for generateContent.
    const turns: Array<{ role: "user" | "model"; text: string }> = [];
    for (const turn of (history ?? []).slice(-5)) {
      turns.push({ role: "user", text: turn.user });
      turns.push({ role: "model", text: turn.assistant });
    }
    turns.push({ role: "user", text: message });

    const gemini = makeGeminiClient(GEMINI_API_KEY.value(), MODEL);

    let rawText: string;
    try {
      rawText = await gemini.generate({
        systemInstruction: `${SYSTEM_PROMPT}\n\nHOUSEHOLD CONTEXT:\n${contextBlock}`,
        messages: turns,
      });
    } catch (err) {
      console.error("concierge: Gemini call failed", { err, model: MODEL });
      const msg = err instanceof Error ? err.message : "AI call failed.";
      throw new HttpsError("internal", msg);
    }

    if (!rawText) {
      throw new HttpsError("internal", "No text in Gemini response.");
    }

    let parsed: ConciergeResponse;
    try {
      parsed = parseResponse(rawText);
    } catch {
      // If the model returned prose instead of JSON, wrap it gracefully.
      parsed = { text: rawText.slice(0, 500), titles: [] };
    }

    // Persist turn to Firestore (best-effort — don't fail the response if this errors).
    try {
      await db.collection(`households/${householdId}/conciergeHistory`).add({
        uid,
        session_id: sessionId,
        message,
        response_text: parsed.text,
        titles: parsed.titles,
        created_at: admin.firestore.FieldValue.serverTimestamp(),
      });
    } catch {
      // Non-fatal.
    }

    return parsed;
  },
);
