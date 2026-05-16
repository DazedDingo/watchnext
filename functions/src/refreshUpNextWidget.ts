import * as admin from "firebase-admin";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { onSchedule } from "firebase-functions/v2/scheduler";

// Mirrors `lib/providers/upnext_provider.dart` — same window, same cap so
// the FCM-pushed payload looks identical to what the in-app row would render
// if the user opened the app right now.
export const REFRESH_WIDGET_MAX_TILES = 3;
export const REFRESH_WIDGET_WINDOW_DAYS_AHEAD = 7;
export const REFRESH_WIDGET_WINDOW_DAYS_BEHIND = 1;

const TMDB_API_KEY = defineSecret("TMDB_API_KEY");

export type NextEp = {
  airDate: string;
  seasonNumber: number;
  episodeNumber: number;
  episodeName?: string | null;
};

export type UpNextRow = {
  tmdbId: number;
  showTitle: string;
  posterPath?: string | null;
  next: NextEp;
  /** Days from `today` (UTC) to `next.airDate`. Negative = aired N days ago. */
  daysUntil: number;
};

/** YYYY-MM-DD (UTC). Matches the daily notifyNextEpisode scheduler frame. */
export function todayUtcIso(): string {
  return new Date().toISOString().slice(0, 10);
}

/** Pure: days between two YYYY-MM-DD strings, anchored to UTC midnight. */
export function daysBetweenUtc(a: string, b: string): number {
  const da = Date.parse(`${a}T00:00:00Z`);
  const db = Date.parse(`${b}T00:00:00Z`);
  if (Number.isNaN(da) || Number.isNaN(db)) return 0;
  return Math.round((db - da) / 86400000);
}

/** Pure: relative-time label matching `_relativeWhen` in
 *  `home_widget_service.dart`. The client-side function is duplicated here
 *  so the FCM payload arrives pre-formatted and the background handler
 *  has zero parsing work (it just copies strings into home_widget prefs). */
export function relativeWhenLabel(daysUntil: number): string {
  if (daysUntil === 0) return "Out today";
  if (daysUntil === 1) return "Tomorrow";
  if (daysUntil === -1) return "Aired yesterday";
  if (daysUntil < 0) return "Just aired";
  return `In ${daysUntil}d`;
}

/** Pure: matches `_episodeLabel` in `home_widget_service.dart`. */
export function episodeLabel(
  season: number,
  episode: number,
  name: string | null | undefined,
): string {
  const s = `S${season}E${episode}`;
  const trimmed = (name ?? "").trim();
  return trimmed.length === 0 ? s : `${s} · ${trimmed}`;
}

/** Pure: matches `_episodeUri` in `home_widget_service.dart`. */
export function episodeUri(
  tmdbId: number,
  season: number,
  episode: number,
): string {
  return `wn://title/tv/${tmdbId}?season=${season}&episode=${episode}`;
}

/** Pure: pick the rows whose `next.airDate` lands in the in-app window
 *  (today - WINDOW_BEHIND to today + WINDOW_AHEAD) and stable-sort by
 *  soonest air date. Mirrors the client's `upNextProvider` selection so
 *  the widget never disagrees with what the app would show. */
export function pickUpNextRows(
  today: string,
  rows: UpNextRow[],
  {
    maxTiles = REFRESH_WIDGET_MAX_TILES,
    windowAhead = REFRESH_WIDGET_WINDOW_DAYS_AHEAD,
    windowBehind = REFRESH_WIDGET_WINDOW_DAYS_BEHIND,
  }: {
    maxTiles?: number;
    windowAhead?: number;
    windowBehind?: number;
  } = {},
): UpNextRow[] {
  const inWindow = rows.filter((r) => {
    const d = r.daysUntil;
    return d >= -windowBehind && d <= windowAhead;
  });
  inWindow.sort((a, b) => a.daysUntil - b.daysUntil);
  return inWindow.slice(0, maxTiles);
}

/** Build the FCM `data` map for a refresh push. Keys mirror the
 *  SharedPreferences slot names the AppWidgetProvider reads
 *  (`up_next_${i}_*` + `up_next_count`), so the background handler can
 *  copy them across without parsing. All values are strings — FCM data
 *  maps don't carry typed values. */
export function buildFcmDataPayload(rows: UpNextRow[]): Record<string, string> {
  const out: Record<string, string> = {
    type: "refresh_widget",
    up_next_count: rows.length.toString(),
  };
  for (let i = 0; i < REFRESH_WIDGET_MAX_TILES; i++) {
    if (i < rows.length) {
      const r = rows[i];
      out[`up_next_${i}_title`] = r.showTitle;
      out[`up_next_${i}_episode_label`] = episodeLabel(
        r.next.seasonNumber,
        r.next.episodeNumber,
        r.next.episodeName,
      );
      out[`up_next_${i}_when`] = relativeWhenLabel(r.daysUntil);
      out[`up_next_${i}_uri`] = episodeUri(
        r.tmdbId,
        r.next.seasonNumber,
        r.next.episodeNumber,
      );
    } else {
      // Sentinel so the bg handler can clear stale slots — FCM doesn't
      // forward keys-with-null, so we encode "absent" as an empty string.
      out[`up_next_${i}_title`] = "";
      out[`up_next_${i}_episode_label`] = "";
      out[`up_next_${i}_when`] = "";
      out[`up_next_${i}_uri`] = "";
    }
  }
  return out;
}

// ─── Orchestration (integration territory, not unit-tested) ─────────────────

async function fetchNextEpisode(
  tmdbId: number,
  apiKey: string,
): Promise<NextEp | null> {
  // Duplicated from notifyNextEpisode.ts — keeping the helpers private to
  // each CF avoids a cross-file refactor risk; the function is ~20 lines and
  // the TMDB shape is stable. Trim defends against `\n` in Secret Manager
  // values (gotcha 35b).
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
    return { airDate, seasonNumber, episodeNumber, episodeName };
  } catch (err) {
    logger.warn(`refreshUpNextWidget: TMDB lookup failed for tmdbId=${tmdbId}`, err);
    return null;
  }
}

async function refreshHousehold(
  db: admin.firestore.Firestore,
  hhId: string,
  apiKey: string,
  today: string,
): Promise<{ pushed: number; errors: number }> {
  // 1. In-progress TV entries
  const entriesSnap = await db
    .collection(`households/${hhId}/watchEntries`)
    .where("media_type", "==", "tv")
    .where("in_progress_status", "==", "watching")
    .get();
  if (entriesSnap.empty) return { pushed: 0, errors: 0 };

  const rows: UpNextRow[] = [];
  for (const doc of entriesSnap.docs) {
    const data = doc.data();
    const tmdbId = data["tmdb_id"] as number | undefined;
    const title = data["title"] as string | undefined;
    if (!tmdbId || !title) continue;
    const next = await fetchNextEpisode(tmdbId, apiKey);
    if (!next) continue;
    rows.push({
      tmdbId,
      showTitle: title,
      posterPath: (data["poster_path"] as string | null | undefined) ?? null,
      next,
      daysUntil: daysBetweenUtc(today, next.airDate),
    });
  }

  const picked = pickUpNextRows(today, rows);
  // We still send when picked is empty so the widget clears stale tiles.
  const payload = buildFcmDataPayload(picked);

  const membersSnap = await db.collection(`households/${hhId}/members`).get();
  const tokens: string[] = [];
  for (const m of membersSnap.docs) {
    const t = m.data()["fcm_token"] as string | undefined;
    if (t) tokens.push(t);
  }
  if (tokens.length === 0) return { pushed: 0, errors: 0 };

  let pushed = 0;
  let errors = 0;
  for (const token of tokens) {
    try {
      await admin.messaging().send({
        token,
        data: payload,
        // data-only — no `notification` field. The bg handler runs silently
        // and updates the widget without surfacing a tray notification.
        android: { priority: "high" },
      });
      pushed++;
    } catch (err) {
      errors++;
      logger.warn(`refreshUpNextWidget: FCM failed hh=${hhId}`, err);
    }
  }
  return { pushed, errors };
}

/**
 * Every 6h, push a silent FCM data message to every household member with
 * the latest Up Next payload. The client's background message handler
 * writes the flat keys straight into home_widget SharedPreferences and
 * triggers an AppWidget update — no app launch required, no Riverpod /
 * Firestore work in the background isolate.
 *
 * Cadence rationale: 6h is fine-grained enough that the relative-time
 * label ("Tomorrow", "In 3d") stays accurate even at timezone edges, and
 * coarse enough to stay well under FCM and CF free-tier budgets (4
 * invocations/day × ~2 tokens per household × tiny payload = effectively
 * zero cost).
 */
export const refreshUpNextWidgetEvery6Hours = onSchedule(
  {
    schedule: "0 */6 * * *",
    timeZone: "Etc/UTC",
    region: "europe-west2",
    secrets: [TMDB_API_KEY],
  },
  async () => {
    const apiKey = TMDB_API_KEY.value();
    if (!apiKey) {
      logger.error("refreshUpNextWidget: TMDB_API_KEY secret unset; skipping");
      return;
    }
    const today = todayUtcIso();
    const db = admin.firestore();
    const hhSnap = await db.collection("households").get();
    let totalPushed = 0;
    let totalErrors = 0;
    for (const hh of hhSnap.docs) {
      const { pushed, errors } = await refreshHousehold(db, hh.id, apiKey, today);
      totalPushed += pushed;
      totalErrors += errors;
    }
    logger.info(
      `refreshUpNextWidget: pushed=${totalPushed} errors=${totalErrors}`,
    );
  },
);
