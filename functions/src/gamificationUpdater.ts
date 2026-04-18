import * as admin from "firebase-admin";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";

/**
 * Server-side badge evaluation + persistence.
 *
 * The Flutter client already derives badge state for display (see
 * `computeBadges` in `lib/providers/stats_provider.dart`). This module
 * persists that state to `/households/{hh}/badges/{badgeId}` so we can:
 *
 *   - Stamp an authoritative `earned_at` timestamp the first time a badge
 *     unlocks (for "Earned on ..." UI and activity feeds).
 *   - Fire FCM push notifications the moment a badge flips from locked
 *     to earned. Unlocks feel flat if they only show up next time the user
 *     opens Stats.
 *
 * Triggers run inline — both watchEntries (drives Century Club + Genre
 * Explorer) and member docs (drives Prediction Machine). If the first-sync
 * burst proves expensive we can swap to a marker-doc debounce like
 * `rescoreQueue`, but badge unlocks feel better when instant.
 *
 * IMPORTANT: `evaluateBadges` must mirror `computeBadges` on the client. If
 * you change the threshold or add a badge, update both sides.
 */

export type BadgeState = {
  id: string;
  name: string;
  progress: number;
  target: number;
  earned: boolean;
  member_uid: string | null;
};

export type MemberDoc = {
  uid: string;
  display_name?: string;
  fcm_token?: string;
  predict_total?: number;
  predict_wins?: number;
  predict_total_solo?: number;
  predict_wins_solo?: number;
  predict_total_together?: number;
  predict_wins_together?: number;
};

export type EntryDoc = {
  media_type?: string;
  genres?: string[];
  /// Last-watched timestamp in millis since epoch. Used by Marathon Mode to
  /// bucket entries by UTC day. Null/undefined entries are skipped rather than
  /// defaulting to "today" — we don't want a backfill to fake a marathon.
  last_watched_at_ms?: number | null;
  /// Populated only for TV entries that have been explicitly marked finished
  /// (`'watching' | 'completed' | 'dropped' | null`). Drives Show Finisher.
  in_progress_status?: string | null;
};

export type RatingDoc = {
  uid: string;
  level: string;
  stars: number;
  note?: string | null;
  tags?: string[];
};

export type DecisionDoc = {
  was_compromise: boolean;
};

/**
 * Derives badge state from raw household inputs. Pure — exposed for unit
 * tests. Order matches client: First Watch, Century Club, Genre Explorer,
 * Binge Master, Perfect Sync, then one Prediction Machine per member.
 *
 * `compatibilityPct` is the taste-profile-computed agreement score (0-1).
 * Pass -1 when the profile hasn't been generated yet — Perfect Sync will
 * read that as zero progress.
 */
export function evaluateBadges(params: {
  entries: EntryDoc[];
  members: MemberDoc[];
  ratings?: RatingDoc[];
  decisions?: DecisionDoc[];
  compatibilityPct?: number;
}): BadgeState[] {
  const { entries, members } = params;
  const ratings = params.ratings ?? [];
  const decisions = params.decisions ?? [];
  const compatibilityPct = params.compatibilityPct ?? -1;
  const result: BadgeState[] = [];

  const total = entries.length;

  result.push({
    id: "first_watch",
    name: "First Watch",
    progress: total === 0 ? 0 : 1,
    target: 1,
    earned: total >= 1,
    member_uid: null,
  });

  result.push({
    id: "century_club",
    name: "Century Club",
    progress: Math.min(total, 100),
    target: 100,
    earned: total >= 100,
    member_uid: null,
  });

  const genres = new Set<string>();
  for (const e of entries) {
    for (const g of e.genres ?? []) genres.add(g);
  }
  result.push({
    id: "genre_explorer",
    name: "Genre Explorer",
    progress: Math.min(genres.size, 5),
    target: 5,
    earned: genres.size >= 5,
    member_uid: null,
  });

  const tvCount = entries.filter((e) => e.media_type === "tv").length;
  result.push({
    id: "binge_master",
    name: "Binge Master",
    progress: Math.min(tvCount, 10),
    target: 10,
    earned: tvCount >= 10,
    member_uid: null,
  });

  // Marathon Mode — max watches in a single UTC day. Entries with no
  // last_watched_at_ms don't contribute; same rule as the client.
  const dayCounts = new Map<number, number>();
  for (const e of entries) {
    const ts = e.last_watched_at_ms;
    if (ts == null) continue;
    const dayKey = Math.floor(ts / 86_400_000);
    dayCounts.set(dayKey, (dayCounts.get(dayKey) ?? 0) + 1);
  }
  let maxPerDay = 0;
  for (const v of dayCounts.values()) {
    if (v > maxPerDay) maxPerDay = v;
  }
  result.push({
    id: "marathon_mode",
    name: "Marathon Mode",
    progress: Math.min(maxPerDay, 5),
    target: 5,
    earned: maxPerDay >= 5,
    member_uid: null,
  });

  const compromiseWins = decisions.filter((d) => d.was_compromise).length;
  result.push({
    id: "compromise_champ",
    name: "Compromise Champ",
    progress: Math.min(compromiseWins, 5),
    target: 5,
    earned: compromiseWins >= 5,
    member_uid: null,
  });

  const finishedShows = entries.filter(
    (e) => e.media_type === "tv" && e.in_progress_status === "completed",
  ).length;
  result.push({
    id: "show_finisher",
    name: "Show Finisher",
    progress: Math.min(finishedShows, 5),
    target: 5,
    earned: finishedShows >= 5,
    member_uid: null,
  });

  // Perfect Sync — same integer rounding as the client so the progress bar
  // renders identically once the CF persists state.
  const compatInt =
    compatibilityPct < 0 ? 0 : Math.round(compatibilityPct * 100);
  result.push({
    id: "perfect_sync",
    name: "Perfect Sync",
    progress: Math.min(compatInt, 90),
    target: 90,
    earned: compatInt >= 90,
    member_uid: null,
  });

  // Pre-filter ratings to movie/show level — episode/season ratings would
  // inflate Five Star Fan and Critic well past what the user intended.
  const movieShowRatings = ratings.filter(
    (r) => r.level === "movie" || r.level === "show",
  );

  for (const m of members) {
    // Match `HouseholdMember.predictTotal` getter on the client — legacy +
    // per-mode counters all roll up into the badge threshold.
    const totalPred =
      (m.predict_total ?? 0) +
      (m.predict_total_solo ?? 0) +
      (m.predict_total_together ?? 0);
    const winsPred =
      (m.predict_wins ?? 0) +
      (m.predict_wins_solo ?? 0) +
      (m.predict_wins_together ?? 0);
    const accuracy = totalPred === 0 ? 0 : winsPred / totalPred;
    const earned = totalPred >= 20 && accuracy >= 0.8;
    const progress = totalPred >= 20 ? 20 : totalPred;
    result.push({
      id: `prediction_machine_${m.uid}`,
      name: "Prediction Machine",
      progress,
      target: 20,
      earned,
      member_uid: m.uid,
    });

    const fiveStars = movieShowRatings.filter(
      (r) => r.uid === m.uid && r.stars === 5,
    ).length;
    result.push({
      id: `five_star_fan_${m.uid}`,
      name: "Five Star Fan",
      progress: Math.min(fiveStars, 10),
      target: 10,
      earned: fiveStars >= 10,
      member_uid: m.uid,
    });

    const withNotes = movieShowRatings.filter(
      (r) => r.uid === m.uid && typeof r.note === "string" && r.note.trim() !== "",
    ).length;
    result.push({
      id: `critic_${m.uid}`,
      name: "Critic",
      progress: Math.min(withNotes, 10),
      target: 10,
      earned: withNotes >= 10,
      member_uid: m.uid,
    });

    const tagged = movieShowRatings.filter(
      (r) =>
        r.uid === m.uid && Array.isArray(r.tags) && r.tags.length > 0,
    ).length;
    result.push({
      id: `tagger_${m.uid}`,
      name: "Tagger",
      progress: Math.min(tagged, 10),
      target: 10,
      earned: tagged >= 10,
      member_uid: m.uid,
    });
  }

  return result;
}

/**
 * Diffs computed badge state against what's already persisted. Returns:
 *   - `writes`: badges whose progress or earned state changed — those need
 *     to be upserted. Unchanged rows are skipped so we don't spam writes
 *     on every trigger fire.
 *   - `newlyEarned`: full badge state objects that flipped locked → earned
 *     this pass. The caller uses these to stamp `earned_at` and send FCM.
 */
export function diffBadgeUnlocks(params: {
  computed: BadgeState[];
  existing: Map<string, { earned: boolean; progress: number }>;
}): { writes: BadgeState[]; newlyEarned: BadgeState[] } {
  const writes: BadgeState[] = [];
  const newlyEarned: BadgeState[] = [];
  for (const state of params.computed) {
    const prev = params.existing.get(state.id);
    const wasEarned = prev?.earned ?? false;
    const progressChanged = (prev?.progress ?? -1) !== state.progress;
    const earnedChanged = wasEarned !== state.earned;
    if (!prev || progressChanged || earnedChanged) writes.push(state);
    if (state.earned && !wasEarned) newlyEarned.push(state);
  }
  return { writes, newlyEarned };
}

/**
 * Reads entries + members + stored badges, computes current state, persists
 * deltas, and fires FCM for newly-earned badges. Exposed for end-to-end
 * testing if we ever spin up `fake_cloud_firestore` on the TS side.
 */
export async function evaluateAndPersistBadges(
  db: admin.firestore.Firestore,
  householdId: string,
): Promise<{ written: number; newlyEarned: string[] }> {
  const [
    entriesSnap,
    membersSnap,
    ratingsSnap,
    decisionsSnap,
    existingSnap,
    tasteSnap,
  ] = await Promise.all([
    db.collection(`households/${householdId}/watchEntries`).get(),
    db.collection(`households/${householdId}/members`).get(),
    db.collection(`households/${householdId}/ratings`).get(),
    db.collection(`households/${householdId}/decisionHistory`).get(),
    db.collection(`households/${householdId}/badges`).get(),
    db.doc(`households/${householdId}/tasteProfile/default`).get(),
  ]);

  const entries: EntryDoc[] = entriesSnap.docs.map((d) => {
    const data = d.data();
    const ts = data.last_watched_at;
    const millis =
      ts && typeof ts.toMillis === "function" ? ts.toMillis() : null;
    return {
      media_type: typeof data.media_type === "string"
        ? data.media_type
        : undefined,
      genres: Array.isArray(data.genres) ? (data.genres as string[]) : [],
      last_watched_at_ms: millis,
      in_progress_status:
        typeof data.in_progress_status === "string"
          ? data.in_progress_status
          : null,
    };
  });

  const members: MemberDoc[] = membersSnap.docs.map((d) => ({
    uid: d.id,
    ...(d.data() as Omit<MemberDoc, "uid">),
  }));

  const ratings: RatingDoc[] = ratingsSnap.docs.map((d) => {
    const data = d.data();
    return {
      uid: typeof data.uid === "string" ? data.uid : "",
      level: typeof data.level === "string" ? data.level : "movie",
      stars: typeof data.stars === "number" ? data.stars : 0,
      note: typeof data.note === "string" ? data.note : null,
      tags: Array.isArray(data.tags) ? (data.tags as string[]) : [],
    };
  });

  const decisions: DecisionDoc[] = decisionsSnap.docs.map((d) => ({
    was_compromise: d.data().was_compromise === true,
  }));

  const existing = new Map<string, { earned: boolean; progress: number }>();
  for (const d of existingSnap.docs) {
    const data = d.data();
    existing.set(d.id, {
      earned: (data.earned_at ?? null) !== null,
      progress: typeof data.progress === "number" ? data.progress : -1,
    });
  }

  const tasteData = tasteSnap.data() ?? {};
  const combined = (tasteData.combined ?? null) as
    | Record<string, unknown>
    | null;
  const compatibilityRaw =
    (combined?.compatibility as Record<string, unknown> | undefined)
      ?.within_1_star_pct;
  const compatibilityPct =
    typeof compatibilityRaw === "number" ? compatibilityRaw : -1;

  const computed = evaluateBadges({
    entries,
    members,
    ratings,
    decisions,
    compatibilityPct,
  });
  const { writes, newlyEarned } = diffBadgeUnlocks({ computed, existing });

  if (writes.length > 0) {
    const batch = db.batch();
    const now = admin.firestore.FieldValue.serverTimestamp();
    for (const state of writes) {
      const ref = db.doc(`households/${householdId}/badges/${state.id}`);
      const wasEarned = existing.get(state.id)?.earned ?? false;
      const shouldStampEarnedAt = state.earned && !wasEarned;
      batch.set(
        ref,
        {
          id: state.id,
          name: state.name,
          progress: state.progress,
          target: state.target,
          earned: state.earned,
          member_uid: state.member_uid,
          updated_at: now,
          ...(shouldStampEarnedAt ? { earned_at: now } : {}),
        },
        { merge: true },
      );
    }
    await batch.commit();
  }

  if (newlyEarned.length > 0) {
    await sendBadgeUnlockFcm(members, newlyEarned);
  }

  return {
    written: writes.length,
    newlyEarned: newlyEarned.map((b) => b.id),
  };
}

/**
 * Fires one FCM push per (badge × recipient). Household-level badges go to
 * both members; per-user badges go only to the member that earned them. Any
 * FCM error (stale token, network) is logged and swallowed — we don't want
 * a bad token to block the badge write.
 */
async function sendBadgeUnlockFcm(
  members: MemberDoc[],
  newlyEarned: BadgeState[],
): Promise<void> {
  const sends: Array<Promise<unknown>> = [];
  for (const badge of newlyEarned) {
    const recipients = badge.member_uid
      ? members.filter((m) => m.uid === badge.member_uid)
      : members;
    for (const m of recipients) {
      if (!m.fcm_token) continue;
      sends.push(
        admin
          .messaging()
          .send({
            token: m.fcm_token,
            data: {
              type: "badge_unlocked",
              badge_id: badge.id,
              badge_name: badge.name,
            },
            notification: {
              title: "Badge unlocked!",
              body: `You earned ${badge.name}`,
            },
            android: { priority: "normal" },
          })
          .catch((err) => {
            logger.warn("badge FCM send failed", {
              uid: m.uid,
              badgeId: badge.id,
              err,
            });
          }),
      );
    }
  }
  await Promise.all(sends);
}

/**
 * Firestore trigger — re-evaluate badges when a watchEntry is
 * created/updated/deleted. This is the main driver for Century Club
 * (length) and Genre Explorer (distinct genre count).
 */
export const onWatchEntryWrittenBadges = onDocumentWritten(
  {
    document: "households/{householdId}/watchEntries/{entryId}",
    region: "europe-west2",
  },
  async (event) => {
    const householdId = event.params.householdId;
    try {
      const result = await evaluateAndPersistBadges(
        admin.firestore(),
        householdId,
      );
      if (result.written > 0 || result.newlyEarned.length > 0) {
        logger.info("badges evaluated (watchEntry)", {
          householdId,
          ...result,
        });
      }
    } catch (err) {
      logger.error("badge eval failed (watchEntry)", { householdId, err });
    }
  },
);

/**
 * Firestore trigger — re-evaluate badges when the taste profile doc is
 * (re)written by the scorer / rescore pipeline. Drives Perfect Sync, whose
 * value comes from `combined.compatibility.within_1_star_pct`.
 */
export const onTasteProfileWrittenBadges = onDocumentWritten(
  {
    document: "households/{householdId}/tasteProfile/{id}",
    region: "europe-west2",
  },
  async (event) => {
    const householdId = event.params.householdId;
    try {
      const result = await evaluateAndPersistBadges(
        admin.firestore(),
        householdId,
      );
      if (result.written > 0 || result.newlyEarned.length > 0) {
        logger.info("badges evaluated (tasteProfile)", {
          householdId,
          ...result,
        });
      }
    } catch (err) {
      logger.error("badge eval failed (tasteProfile)", {
        householdId,
        err,
      });
    }
  },
);

/**
 * Firestore trigger — re-evaluate badges when a member doc changes. Drives
 * Prediction Machine (counters updated by `PredictionService.markRevealSeen`).
 *
 * We also catch member creation here so the first predict writes unlock the
 * badge even if the watchEntry trigger hasn't fired in between.
 */
export const onMemberWrittenBadges = onDocumentWritten(
  {
    document: "households/{householdId}/members/{uid}",
    region: "europe-west2",
  },
  async (event) => {
    const householdId = event.params.householdId;
    try {
      const result = await evaluateAndPersistBadges(
        admin.firestore(),
        householdId,
      );
      if (result.written > 0 || result.newlyEarned.length > 0) {
        logger.info("badges evaluated (member)", { householdId, ...result });
      }
    } catch (err) {
      logger.error("badge eval failed (member)", { householdId, err });
    }
  },
);

/**
 * Firestore trigger — re-evaluate badges when a rating is written. Drives
 * Five Star Fan (per-user 5-star count) and Critic (per-user rating-with-note
 * count). The `onRatingWritten` trigger in rescoreRecommendations.ts handles
 * profile refresh separately; these run in parallel.
 */
export const onRatingWrittenBadges = onDocumentWritten(
  {
    document: "households/{householdId}/ratings/{ratingId}",
    region: "europe-west2",
  },
  async (event) => {
    const householdId = event.params.householdId;
    try {
      const result = await evaluateAndPersistBadges(
        admin.firestore(),
        householdId,
      );
      if (result.written > 0 || result.newlyEarned.length > 0) {
        logger.info("badges evaluated (rating)", { householdId, ...result });
      }
    } catch (err) {
      logger.error("badge eval failed (rating)", { householdId, err });
    }
  },
);

/**
 * Firestore trigger — re-evaluate badges when a decision lands in
 * decisionHistory. Drives Compromise Champ (count of `was_compromise=true`).
 */
export const onDecisionWrittenBadges = onDocumentWritten(
  {
    document: "households/{householdId}/decisionHistory/{decisionId}",
    region: "europe-west2",
  },
  async (event) => {
    const householdId = event.params.householdId;
    try {
      const result = await evaluateAndPersistBadges(
        admin.firestore(),
        householdId,
      );
      if (result.written > 0 || result.newlyEarned.length > 0) {
        logger.info("badges evaluated (decision)", { householdId, ...result });
      }
    } catch (err) {
      logger.error("badge eval failed (decision)", { householdId, err });
    }
  },
);
