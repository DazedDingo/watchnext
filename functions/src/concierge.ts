import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import Anthropic from "@anthropic-ai/sdk";

/**
 * Conversational AI concierge (Phase 8).
 *
 * Receives a user message + recent conversation history from the client,
 * builds a rich household-context prompt, calls Claude, and returns a
 * structured response with a text reply and 3-5 tappable title suggestions.
 *
 * The household context block (taste profile + history + watchlist) is marked
 * with cache_control so Claude reuses it across turns in the same session,
 * cutting latency and cost on follow-up messages.
 *
 * Session turns are persisted to /households/{hh}/conciergeHistory so the
 * chat survives app restarts.
 */

const ANTHROPIC_API_KEY = defineSecret("ANTHROPIC_API_KEY");
const MODEL = "claude-sonnet-4-6";

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
  const cleaned = text.trim()
    .replace(/^```(?:json)?/i, "")
    .replace(/```$/, "")
    .trim();
  const parsed = JSON.parse(cleaned) as ConciergeResponse;
  return {
    text: parsed.text ?? "",
    titles: Array.isArray(parsed.titles) ? parsed.titles : [],
  };
}

export const concierge = onCall(
  { secrets: [ANTHROPIC_API_KEY], region: "europe-west2", timeoutSeconds: 60 },
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

    // Build Claude messages from history + current turn.
    const claudeMessages: Anthropic.MessageParam[] = [];
    for (const turn of (history ?? []).slice(-5)) {
      claudeMessages.push({ role: "user", content: turn.user });
      claudeMessages.push({ role: "assistant", content: turn.assistant });
    }
    claudeMessages.push({ role: "user", content: message });

    const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY.value() });

    // Stable `messages.create` — concierge is low-frequency (one chat at a
    // time), so dropping `cache_control` costs nothing user-visible and
    // avoids SDK-version drift on the deprecated beta.promptCaching path.
    let res: Anthropic.Message;
    try {
      res = await anthropic.messages.create({
        model: MODEL,
        max_tokens: 1024,
        system: `${SYSTEM_PROMPT}\n\nHOUSEHOLD CONTEXT:\n${contextBlock}`,
        messages: claudeMessages,
      });
    } catch (err) {
      console.error("concierge: Claude call failed", { err, model: MODEL });
      const msg = err instanceof Error ? err.message : "AI call failed.";
      throw new HttpsError("internal", msg);
    }

    const block = res.content.find((b) => b.type === "text");
    if (!block || block.type !== "text") {
      throw new HttpsError("internal", "No text in Claude response.");
    }

    let parsed: ConciergeResponse;
    try {
      parsed = parseResponse(block.text);
    } catch {
      // If Claude returned prose instead of JSON, wrap it gracefully.
      parsed = { text: block.text.slice(0, 500), titles: [] };
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
