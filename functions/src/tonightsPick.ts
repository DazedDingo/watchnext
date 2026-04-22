import { onSchedule } from "firebase-functions/v2/scheduler";
import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";

/**
 * Per-household Tonight's Pick doc. Populated by the scheduled CF once a
 * day so the Android home-screen widget has a stable doc to read from.
 * The in-app Home screen still picks locally (interactive — respects
 * filters + "Not tonight" dismissals); this doc is the widget-facing
 * deterministic pick so both members see the same thing from their
 * launcher.
 */
export interface TonightsPick {
  tmdbId: number;
  mediaType: "movie" | "tv";
  title: string;
  posterPath: string;
  year: number | null;
  matchScore: number;
  aiBlurb: string;
  updatedAt: admin.firestore.Timestamp;
  // Soft "why this one" hint for the widget so it doesn't just say
  // "Tonight's Pick" with no context. Captured from the top rec's source.
  source: string;
}

/**
 * Pure helper: given a list of candidate recs + a set of watched keys,
 * return the best pick (highest match_score that isn't already watched).
 * Null when no candidate survives.
 *
 * Exported for testing. Accepts the raw Firestore doc shape rather than
 * a typed Recommendation so tests stay lightweight.
 */
export function pickTonightsPick(
  recs: Array<Record<string, unknown>>,
  watchedKeys: Set<string>,
): Record<string, unknown> | null {
  let best: Record<string, unknown> | null = null;
  let bestScore = -1;
  for (const r of recs) {
    const mt = r.media_type;
    const id = r.tmdb_id;
    if (typeof mt !== "string" || typeof id !== "number") continue;
    if (watchedKeys.has(`${mt}:${id}`)) continue;
    const score = typeof r.match_score === "number" ? r.match_score : 0;
    if (score > bestScore) {
      best = r;
      bestScore = score;
    }
  }
  return best;
}

async function updateHousehold(
  db: admin.firestore.Firestore,
  hhId: string,
): Promise<"written" | "no-candidate" | "error"> {
  try {
    // Pull a wide window so we don't pick a known-watched title as "tonight's
    // pick". 300 mirrors the Home stream cap.
    const [recsSnap, entriesSnap] = await Promise.all([
      db
        .collection(`households/${hhId}/recommendations`)
        .orderBy("match_score", "desc")
        .limit(300)
        .get(),
      db.collection(`households/${hhId}/watchEntries`).get(),
    ]);

    const watched = new Set<string>();
    for (const d of entriesSnap.docs) {
      const data = d.data();
      const mt = data.media_type as string | undefined;
      const id = data.tmdb_id as number | undefined;
      if (mt && typeof id === "number") watched.add(`${mt}:${id}`);
    }

    const pick = pickTonightsPick(
      recsSnap.docs.map((d) => d.data()),
      watched,
    );
    if (!pick) return "no-candidate";

    const doc: TonightsPick = {
      tmdbId: pick.tmdb_id as number,
      mediaType: pick.media_type as "movie" | "tv",
      title: (pick.title as string) ?? "",
      posterPath: (pick.poster_path as string) ?? "",
      year: typeof pick.year === "number" ? (pick.year as number) : null,
      matchScore:
        typeof pick.match_score === "number" ? (pick.match_score as number) : 0,
      aiBlurb: (pick.ai_blurb as string) ?? "",
      updatedAt: admin.firestore.Timestamp.now(),
      source: (pick.source as string) ?? "unknown",
    };

    await db
      .doc(`households/${hhId}/tonightsPick/current`)
      .set(doc, { merge: true });
    return "written";
  } catch (err) {
    logger.warn("tonightsPick household update failed", {
      hhId,
      error: (err as Error).message,
    });
    return "error";
  }
}

/**
 * Scheduled daily at 08:00 UTC (~early morning UK / late night US).
 *
 * Iterates every household and writes a Tonight's Pick doc. Runs even
 * when a household has no recs — that's the "no-candidate" path, which
 * just skips without wiping any prior pick (so the widget still shows
 * yesterday's pick rather than going blank).
 */
export const updateTonightsPickDaily = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "Etc/UTC",
    region: "europe-west2",
  },
  async () => {
    const db = admin.firestore();
    const hhSnap = await db.collection("households").get();
    let written = 0;
    let skipped = 0;
    let errors = 0;
    for (const hh of hhSnap.docs) {
      const result = await updateHousehold(db, hh.id);
      if (result === "written") written++;
      else if (result === "no-candidate") skipped++;
      else errors++;
    }
    logger.info("Tonight's Pick sweep complete", {
      households: hhSnap.size,
      written,
      skipped,
      errors,
    });
  },
);
