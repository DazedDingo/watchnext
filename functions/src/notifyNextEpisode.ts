import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineSecret } from "firebase-functions/params";

/**
 * Daily push notification: "next episode of an in-progress show airs today".
 *
 * Reuses the data shape behind the client-side `upNextProvider`. For each
 * household, scan watch entries with `media_type='tv'` AND
 * `in_progress_status='watching'`, look up `next_episode_to_air` via TMDB
 * `/tv/{id}`, and if `air_date` matches today (Etc/UTC), send one FCM
 * push per household member token.
 *
 * Idempotency: every successful push stamps
 * `last_episode_notified_for: '{YYYY-MM-DD}'` on the watch entry. The
 * helper short-circuits when the stamp matches the air date already, so
 * a repeat cron invocation in the same day is a no-op. Once the next
 * episode rolls over to a new air date, the stamp is stale and the
 * push fires again on that day.
 *
 * Cost: 1 cron/day × ~few households × ~1 TMDB call per in-progress
 * show. Free-tier safe — TMDB is unmetered, FCM is free, the CF runs
 * once a day.
 */

const TMDB_API_KEY = defineSecret("TMDB_API_KEY");

/** Pure helper. Decides which watch entries need a push, given today's
 *  date, the in-progress watch entries, and the per-tmdbId next-episode
 *  air dates resolved from TMDB. Excluded:
 *    - shows TMDB returned no `next_episode_to_air` for (cancelled, etc)
 *    - shows whose next ep airs on a day other than today
 *    - shows already notified for the same air date (idempotency)
 *  Test target — orchestration around it (Firestore, TMDB, FCM) is
 *  integration territory and skipped from unit tests. */
export type WatchEntryRow = {
  entryId: string;
  tmdbId: number;
  title: string;
  posterPath?: string | null;
  /** Already-stamped air date from a prior successful notify, or
   *  undefined if never notified. */
  lastEpisodeNotifiedFor?: string;
};

export type NextEpisodeInfo = {
  airDate: string; // YYYY-MM-DD
  seasonNumber: number;
  episodeNumber: number;
  episodeName?: string | null;
};

export type Notification = {
  entryId: string;
  tmdbId: number;
  showTitle: string;
  posterPath?: string | null;
  airDate: string;
  seasonNumber: number;
  episodeNumber: number;
  episodeName?: string | null;
};

export function pickEntriesNeedingNotify(
  today: string,
  entries: WatchEntryRow[],
  nextEpByTmdbId: Record<number, NextEpisodeInfo | null>,
): Notification[] {
  const out: Notification[] = [];
  for (const entry of entries) {
    const next = nextEpByTmdbId[entry.tmdbId];
    if (!next) continue;
    if (next.airDate !== today) continue;
    if (entry.lastEpisodeNotifiedFor === next.airDate) continue;
    out.push({
      entryId: entry.entryId,
      tmdbId: entry.tmdbId,
      showTitle: entry.title,
      posterPath: entry.posterPath ?? null,
      airDate: next.airDate,
      seasonNumber: next.seasonNumber,
      episodeNumber: next.episodeNumber,
      episodeName: next.episodeName ?? null,
    });
  }
  return out;
}

/** Format `S##E##` for push body. Pure. */
export function formatEpisodeLabel(season: number, episode: number): string {
  const s = season.toString().padStart(2, "0");
  const e = episode.toString().padStart(2, "0");
  return `S${s}E${e}`;
}

/** Today as YYYY-MM-DD in Etc/UTC. The CF schedule uses UTC; matching the
 *  scheduler's reference frame avoids "off by one" edge cases at midnight
 *  in the household's local zone. */
function todayUtcIso(): string {
  const now = new Date();
  return now.toISOString().slice(0, 10);
}

async function fetchNextEpisode(
  tmdbId: number,
  apiKey: string,
): Promise<NextEpisodeInfo | null> {
  // Lean /tv/{id} call — same endpoint the client `upNextProvider` uses,
  // returns `next_episode_to_air` in the base payload. Trim defends
  // against trailing newlines in Secret Manager values (same class of
  // bug that bit OMDb in gotcha 35b — `\n` URL-encodes to `%0A` and the
  // upstream rejects the request as "Invalid API key").
  const url = `https://api.themoviedb.org/3/tv/${tmdbId}?api_key=${apiKey.trim()}&language=en-US`;
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    const json = (await res.json()) as Record<string, unknown>;
    const next = json["next_episode_to_air"] as Record<string, unknown> | null;
    if (!next) return null;
    const airDate = next["air_date"] as string | null;
    const seasonNumber = next["season_number"] as number | null;
    const episodeNumber = next["episode_number"] as number | null;
    const episodeName = next["name"] as string | null;
    if (!airDate || seasonNumber == null || episodeNumber == null) return null;
    return {
      airDate,
      seasonNumber,
      episodeNumber,
      episodeName,
    };
  } catch (err) {
    logger.warn(`notifyNextEpisode: TMDB lookup failed for tmdbId=${tmdbId}`, err);
    return null;
  }
}

/** Fan out per household. Exported for direct invocation in tests against
 *  the Firestore emulator if desired (not used today). */
async function notifyHousehold(
  db: admin.firestore.Firestore,
  hhId: string,
  apiKey: string,
  today: string,
): Promise<{ pushed: number; skipped: number; errors: number }> {
  // 1. Read all in-progress TV watch entries.
  const entriesSnap = await db
    .collection(`households/${hhId}/watchEntries`)
    .where("media_type", "==", "tv")
    .where("in_progress_status", "==", "watching")
    .get();
  if (entriesSnap.empty) return { pushed: 0, skipped: 0, errors: 0 };

  const entries: (WatchEntryRow & { docRef: admin.firestore.DocumentReference })[] = [];
  for (const doc of entriesSnap.docs) {
    const data = doc.data();
    const tmdbId = data["tmdb_id"] as number | undefined;
    const title = data["title"] as string | undefined;
    if (!tmdbId || !title) continue;
    entries.push({
      entryId: doc.id,
      tmdbId,
      title,
      posterPath: (data["poster_path"] as string | null | undefined) ?? null,
      lastEpisodeNotifiedFor:
        (data["last_episode_notified_for"] as string | undefined) ?? undefined,
      docRef: doc.ref,
    });
  }
  if (entries.length === 0) return { pushed: 0, skipped: 0, errors: 0 };

  // 2. Resolve TMDB next_episode_to_air per show. Sequential with a small
  //    throttle — this CF runs once a day and TMDB has a soft per-IP cap;
  //    no need to fan out aggressively.
  const nextEpByTmdbId: Record<number, NextEpisodeInfo | null> = {};
  for (const e of entries) {
    nextEpByTmdbId[e.tmdbId] = await fetchNextEpisode(e.tmdbId, apiKey);
  }

  // 3. Decide who needs a push (pure).
  const toNotify = pickEntriesNeedingNotify(today, entries, nextEpByTmdbId);
  if (toNotify.length === 0) return { pushed: 0, skipped: entries.length, errors: 0 };

  // 4. Read household member tokens.
  const membersSnap = await db.collection(`households/${hhId}/members`).get();
  const tokens: string[] = [];
  for (const m of membersSnap.docs) {
    const t = m.data()["fcm_token"] as string | undefined;
    if (t) tokens.push(t);
  }
  if (tokens.length === 0) {
    logger.info(`notifyNextEpisode: hh=${hhId} has notifications to send but no tokens`);
    return { pushed: 0, skipped: entries.length, errors: 0 };
  }

  // 5. Send + stamp.
  let pushed = 0;
  let errors = 0;
  for (const n of toNotify) {
    const epLabel = formatEpisodeLabel(n.seasonNumber, n.episodeNumber);
    const bodyName = n.episodeName ? ` — ${n.episodeName}` : "";
    const body = `${n.showTitle} ${epLabel}${bodyName}`;
    for (const token of tokens) {
      try {
        await admin.messaging().send({
          token,
          data: {
            type: "next_episode_today",
            media_type: "tv",
            tmdb_id: n.tmdbId.toString(),
            entry_id: n.entryId,
            season: n.seasonNumber.toString(),
            episode: n.episodeNumber.toString(),
            title: n.showTitle,
          },
          notification: {
            title: "New episode out today",
            body,
          },
          android: { priority: "normal" },
        });
      } catch (err) {
        errors++;
        logger.warn(
          `notifyNextEpisode: FCM send failed for hh=${hhId} entry=${n.entryId}`,
          err,
        );
      }
    }
    // Stamp the air date even if some tokens failed — partial-fail still
    // counts as "we tried", and we'd rather not duplicate-push later.
    try {
      await db
        .doc(`households/${hhId}/watchEntries/${n.entryId}`)
        .update({ last_episode_notified_for: n.airDate });
      pushed++;
    } catch (err) {
      errors++;
      logger.warn(
        `notifyNextEpisode: stamp failed for hh=${hhId} entry=${n.entryId}`,
        err,
      );
    }
  }
  return { pushed, skipped: entries.length - toNotify.length, errors };
}

/**
 * Scheduled at 09:00 UTC daily — far enough into the day that TMDB's
 * `next_episode_to_air.air_date` has rolled over for major release
 * regions, but still early enough that European/UK households see the
 * push at a reasonable morning hour. (UK = 09:00 BST / 10:00 GMT.)
 */
export const notifyNextEpisodeDaily = onSchedule(
  {
    schedule: "0 9 * * *",
    timeZone: "Etc/UTC",
    region: "europe-west2",
    secrets: [TMDB_API_KEY],
  },
  async () => {
    const apiKey = TMDB_API_KEY.value();
    if (!apiKey) {
      logger.error("notifyNextEpisode: TMDB_API_KEY secret unset; skipping");
      return;
    }
    const today = todayUtcIso();
    const db = admin.firestore();
    const hhSnap = await db.collection("households").get();
    let totalPushed = 0;
    let totalSkipped = 0;
    let totalErrors = 0;
    for (const hh of hhSnap.docs) {
      try {
        const r = await notifyHousehold(db, hh.id, apiKey, today);
        totalPushed += r.pushed;
        totalSkipped += r.skipped;
        totalErrors += r.errors;
      } catch (err) {
        totalErrors++;
        logger.warn(`notifyNextEpisode: hh=${hh.id} sweep failed`, err);
      }
    }
    logger.info("notifyNextEpisode sweep complete", {
      households: hhSnap.size,
      today,
      pushed: totalPushed,
      skipped: totalSkipped,
      errors: totalErrors,
    });
  },
);
