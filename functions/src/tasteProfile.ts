import * as admin from "firebase-admin";
import { onCall, HttpsError } from "firebase-functions/v2/https";

/**
 * Taste profile builder — reads ratings + watchEntries for a household and
 * derives per-user + combined profiles used by Phase 7's Claude scoring and
 * Phase 5's compromise fallback.
 *
 * Profile lives at /households/{hhid}/tasteProfile (single doc). Client-facing
 * so recalculation is on-demand (after sync, before scoring); a weekly
 * scheduled refresh can be added later if we notice drift.
 */

type Rating = {
  uid: string;
  level: string;
  target_id: string;
  stars: number;
  tags?: string[];
  /**
   * Viewing context the user was in when they rated. 'solo' | 'together'
   * | null/undefined (undefined = legacy / Trakt historical).
   * Null-context ratings flow into both the solo and together profiles as
   * shared backdrop signal.
   */
  context?: "solo" | "together" | null;
};

/**
 * Describes which ratings to fold into a profile.
 *  - null → include everything (cross-context, back-compat shape).
 *  - "solo" → include context='solo' OR null (null = generic backdrop signal).
 *  - "together" → include context='together' OR null.
 */
export type ContextFilter = "solo" | "together" | null;

type WatchEntry = {
  media_type: string;
  tmdb_id: number;
  title: string;
  year?: number;
  runtime?: number;
  genres?: string[];
  watched_by?: Record<string, boolean>;
};

type UserProfile = {
  uid: string;
  avg_rating: number;
  rated_count: number;
  top_genres: { genre: string; weight: number; rated_count: number }[];
  top_tags: { tag: string; count: number }[];
  decades: Record<string, number>;
  liked_titles: {
    title: string;
    tmdb_id: number;
    media_type: string;
    stars: number;
    genres: string[];
  }[];
  disliked_titles: {
    title: string;
    tmdb_id: number;
    media_type: string;
    stars: number;
    genres: string[];
  }[];
  median_runtime: number | null;
};

export function decadeBucket(year: number | undefined): string | null {
  if (!year) return null;
  const d = Math.floor(year / 10) * 10;
  return `${d}s`;
}

/**
 * Returns true iff [r.context] matches the context filter.
 *  - null filter → anything matches (cross-context profile).
 *  - "solo" filter → only solo-stamped or null-context ratings contribute.
 *  - "together" filter → only together-stamped or null-context ratings contribute.
 *
 * Exported so tests and the scorer can reuse the same contract.
 */
export function matchesContextFilter(
  ratingContext: string | null | undefined,
  filter: ContextFilter,
): boolean {
  if (filter === null) return true;
  // null/undefined context = legacy / Trakt-historical = shared backdrop,
  // folded into both solo and together profiles.
  if (ratingContext == null) return true;
  return ratingContext === filter;
}

export function buildUserProfile(
  uid: string,
  ratings: Rating[],
  entriesById: Map<string, WatchEntry>,
  contextFilter: ContextFilter = null,
): UserProfile {
  const mine = ratings.filter(
    (r) =>
      r.uid === uid &&
      (r.level === "movie" || r.level === "show") &&
      matchesContextFilter(r.context, contextFilter),
  );

  const genreWeights = new Map<string, { weight: number; count: number }>();
  const tagCounts = new Map<string, number>();
  const decades: Record<string, number> = {};
  const runtimes: number[] = [];
  let sum = 0;
  const liked: UserProfile["liked_titles"] = [];
  const disliked: UserProfile["liked_titles"] = [];

  for (const r of mine) {
    sum += r.stars;
    const entry = entriesById.get(r.target_id);
    if (!entry) continue;

    // Genre weights: (stars - 3) makes 3★ neutral, 5★ = +2, 1★ = -2.
    const delta = r.stars - 3;
    for (const g of entry.genres ?? []) {
      const cur = genreWeights.get(g) ?? { weight: 0, count: 0 };
      cur.weight += delta;
      cur.count += 1;
      genreWeights.set(g, cur);
    }

    for (const t of r.tags ?? []) {
      tagCounts.set(t, (tagCounts.get(t) ?? 0) + 1);
    }

    const bucket = decadeBucket(entry.year);
    if (bucket) decades[bucket] = (decades[bucket] ?? 0) + 1;
    if (entry.runtime) runtimes.push(entry.runtime);

    const rec = {
      title: entry.title,
      tmdb_id: entry.tmdb_id,
      media_type: entry.media_type,
      stars: r.stars,
      genres: entry.genres ?? [],
    };
    if (r.stars >= 4) liked.push(rec);
    if (r.stars <= 2) disliked.push(rec);
  }

  const top_genres = Array.from(genreWeights.entries())
    .filter(([, v]) => v.count >= 2)
    .map(([genre, v]) => ({ genre, weight: v.weight, rated_count: v.count }))
    .sort((a, b) => b.weight - a.weight)
    .slice(0, 10);

  const top_tags = Array.from(tagCounts.entries())
    .map(([tag, count]) => ({ tag, count }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 10);

  liked.sort((a, b) => b.stars - a.stars);
  disliked.sort((a, b) => a.stars - b.stars);

  const median_runtime = runtimes.length
    ? runtimes.sort((a, b) => a - b)[Math.floor(runtimes.length / 2)]
    : null;

  return {
    uid,
    avg_rating: mine.length ? sum / mine.length : 0,
    rated_count: mine.length,
    top_genres,
    top_tags,
    decades,
    liked_titles: liked.slice(0, 15),
    disliked_titles: disliked.slice(0, 10),
    median_runtime,
  };
}

export function compatibility(ratings: Rating[], uids: string[]): {
  within_1_star_pct: number;
  rated_both_count: number;
} {
  if (uids.length < 2) return { within_1_star_pct: 0, rated_both_count: 0 };
  const [a, b] = uids;
  const byTarget = new Map<string, { a?: number; b?: number }>();
  for (const r of ratings) {
    if (r.level !== "movie" && r.level !== "show") continue;
    const slot = byTarget.get(r.target_id) ?? {};
    if (r.uid === a) slot.a = r.stars;
    else if (r.uid === b) slot.b = r.stars;
    byTarget.set(r.target_id, slot);
  }
  let both = 0;
  let within = 0;
  for (const { a: sa, b: sb } of byTarget.values()) {
    if (sa != null && sb != null) {
      both += 1;
      if (Math.abs(sa - sb) <= 1) within += 1;
    }
  }
  return {
    within_1_star_pct: both ? within / both : 0,
    rated_both_count: both,
  };
}

/**
 * Pure server-side taste-profile regeneration. Exposed so both the user-facing
 * callable and the scheduled re-score drain can share the same writer without
 * a self-callable round-trip.
 */
export async function buildAndWriteTasteProfile(
  db: admin.firestore.Firestore,
  householdId: string,
): Promise<{ member_count: number; rated_count: number; compatibility_pct: number }> {
  const [ratingsSnap, entriesSnap, membersSnap] = await Promise.all([
    db.collection(`households/${householdId}/ratings`).get(),
    db.collection(`households/${householdId}/watchEntries`).get(),
    db.collection(`households/${householdId}/members`).get(),
  ]);

  const ratings: Rating[] = ratingsSnap.docs.map((d) => d.data() as Rating);
  const entriesById = new Map<string, WatchEntry>();
  for (const d of entriesSnap.docs) {
    entriesById.set(d.id, d.data() as WatchEntry);
  }
  const memberUids = membersSnap.docs.map((d) => d.id);

  const per_user: Record<string, UserProfile> = {};
  const per_user_solo: Record<string, UserProfile> = {};
  const per_user_together: Record<string, UserProfile> = {};
  for (const mUid of memberUids) {
    per_user[mUid] = buildUserProfile(mUid, ratings, entriesById);
    per_user_solo[mUid] = buildUserProfile(mUid, ratings, entriesById, "solo");
    per_user_together[mUid] =
      buildUserProfile(mUid, ratings, entriesById, "together");
  }

  const combinedGenres = new Map<string, { weight: number; count: number }>();
  for (const prof of Object.values(per_user)) {
    for (const g of prof.top_genres) {
      const cur = combinedGenres.get(g.genre) ?? { weight: 0, count: 0 };
      cur.weight += g.weight;
      cur.count += g.rated_count;
      combinedGenres.set(g.genre, cur);
    }
  }
  const combined_top_genres = Array.from(combinedGenres.entries())
    .map(([genre, v]) => ({ genre, weight: v.weight, rated_count: v.count }))
    .sort((a, b) => b.weight - a.weight)
    .slice(0, 10);

  const allLikedIds = memberUids.map(
    (u) => new Set((per_user[u]?.liked_titles ?? []).map((t) => `${t.media_type}:${t.tmdb_id}`)),
  );
  const shared_favorites: UserProfile["liked_titles"] = [];
  if (allLikedIds.length >= 2) {
    for (const t of per_user[memberUids[0]]?.liked_titles ?? []) {
      const key = `${t.media_type}:${t.tmdb_id}`;
      if (allLikedIds.slice(1).every((s) => s.has(key))) {
        shared_favorites.push(t);
      }
    }
  }

  const compat = compatibility(ratings, memberUids);

  const totalRated = Object.values(per_user).reduce(
    (acc, p) => acc + p.rated_count,
    0,
  );
  const combinedAvg = totalRated
    ? Object.values(per_user).reduce(
        (acc, p) => acc + p.avg_rating * p.rated_count,
        0,
      ) / totalRated
    : 0;

  const profile = {
    updated_at: admin.firestore.FieldValue.serverTimestamp(),
    member_uids: memberUids,
    combined: {
      avg_rating: combinedAvg,
      rated_count: totalRated,
      top_genres: combined_top_genres,
      shared_favorites: shared_favorites.slice(0, 10),
      compatibility: compat,
    },
    per_user,
    per_user_solo,
    per_user_together,
  };

  await db.doc(`households/${householdId}/tasteProfile/default`).set(profile);

  return {
    member_count: memberUids.length,
    rated_count: totalRated,
    compatibility_pct: compat.within_1_star_pct,
  };
}

export const generateTasteProfile = onCall({ region: "europe-west2" }, async (request) => {
  const uid = request.auth?.uid;
  if (!uid) throw new HttpsError("unauthenticated", "Sign in required.");
  const householdId = request.data?.householdId;
  if (typeof householdId !== "string" || !householdId) {
    throw new HttpsError("invalid-argument", "Missing householdId.");
  }

  const db = admin.firestore();

  // Gate on membership (rules would block it anyway, but good to fail fast).
  const memberSnap = await db
    .doc(`households/${householdId}/members/${uid}`)
    .get();
  if (!memberSnap.exists) {
    throw new HttpsError("permission-denied", "Not a household member.");
  }

  const result = await buildAndWriteTasteProfile(db, householdId);
  return { ok: true, ...result };
});
