import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";

const OMDB_API_KEY = defineSecret("OMDB_API_KEY");

export const CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
const OMDB_URL = "https://www.omdbapi.com/";

export interface ExternalRatings {
  imdbId: string;
  imdbRating: number | null;
  imdbVotes: number | null;
  rtRating: number | null;
  metascore: number | null;
  fetchedAtMs: number;
  source: "omdb";
  notFound?: boolean;
}

/**
 * Parse OMDb's quirky response shapes:
 * - imdbRating:  "7.8"    → 7.8     (or "N/A" → null)
 * - imdbVotes:   "1,234,567" → 1234567
 * - Metascore:   "82"     → 82
 * - Ratings:     [{Source: "Rotten Tomatoes", Value: "92%"}] → 92
 *
 * Exported for unit tests.
 */
export function parseOmdbPayload(
  raw: Record<string, unknown>,
  imdbId: string,
): ExternalRatings {
  const parseNum = (v: unknown): number | null => {
    if (typeof v !== "string" || v === "N/A" || v.length === 0) return null;
    const cleaned = v.replace(/,/g, "").replace(/%/g, "").trim();
    const n = Number(cleaned);
    return Number.isFinite(n) ? n : null;
  };

  const ratings = Array.isArray(raw.Ratings) ? raw.Ratings : [];
  let rtRating: number | null = null;
  for (const r of ratings) {
    if (r && typeof r === "object" &&
        (r as { Source?: string }).Source === "Rotten Tomatoes") {
      rtRating = parseNum((r as { Value?: string }).Value);
      break;
    }
  }

  return {
    imdbId,
    imdbRating: parseNum(raw.imdbRating),
    imdbVotes: parseNum(raw.imdbVotes),
    rtRating,
    metascore: parseNum(raw.Metascore),
    fetchedAtMs: Date.now(),
    source: "omdb",
  };
}

async function fetchFromOmdb(
  imdbId: string,
  apiKey: string,
): Promise<ExternalRatings> {
  if (!apiKey || apiKey.length < 4) {
    // Guard against misconfigured secret — throw a recognizable error rather
    // than a cryptic OMDb 401 when the key is empty.
    throw new HttpsError(
      "failed-precondition",
      `OMDB_API_KEY not configured (len=${apiKey?.length ?? 0})`,
    );
  }

  const url = new URL(OMDB_URL);
  url.searchParams.set("i", imdbId);
  url.searchParams.set("apikey", apiKey);
  url.searchParams.set("tomatoes", "true");

  let res: Response;
  try {
    res = await fetch(url.toString(), {
      headers: { "User-Agent": "watchnext/1.0" },
    });
  } catch (err) {
    throw new HttpsError(
      "internal",
      `OMDb fetch threw: ${(err as Error).message}`,
    );
  }

  if (!res.ok) {
    throw new HttpsError(
      "internal",
      `OMDb ${res.status}: ${(await res.text()).slice(0, 200)}`,
    );
  }

  const payload = (await res.json()) as Record<string, unknown>;

  // OMDb returns `{Response: "False", Error: "..."}` for unknown ids AND
  // for auth/config errors (invalid key, rate limit, etc). Distinguish
  // the two — an invalid-key response should NOT be cached as notFound,
  // otherwise the 7-day TTL will mask the problem long after the user
  // activates their key. Match on "API key" / "limit" / "Daily" to catch
  // the auth + quota errors OMDb emits; everything else is a genuine
  // "no entry for this imdb id" which IS safe to cache.
  if (payload.Response === "False") {
    const error = String(payload.Error ?? "");
    if (/API key|daily limit|request limit/i.test(error)) {
      throw new HttpsError("internal", `OMDb auth/quota: ${error}`);
    }
    return {
      imdbId,
      imdbRating: null,
      imdbVotes: null,
      rtRating: null,
      metascore: null,
      fetchedAtMs: Date.now(),
      source: "omdb",
      notFound: true,
    };
  }

  return parseOmdbPayload(payload, imdbId);
}

function isFresh(doc: ExternalRatings, now: number): boolean {
  return now - doc.fetchedAtMs < CACHE_TTL_MS;
}

/**
 * Client callable — returns external ratings for an IMDb id, backed by a
 * 7-day Firestore cache at /externalRatings/{imdbId}. Any authenticated user
 * can call; the result is public metadata, not household-scoped.
 *
 * Cache semantics:
 * - Hit + fresh  → return immediately (no OMDb call).
 * - Hit + stale  → refetch, overwrite, return.
 * - Miss         → fetch, write, return.
 * - OMDb 404     → cached as `notFound: true` for the TTL so we don't hammer
 *                  OMDb for titles it doesn't track.
 */
export const fetchExternalRatings = onCall(
  { secrets: [OMDB_API_KEY] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign in required");
    }

    const imdbId = String(request.data?.imdbId ?? "").trim();
    if (!/^tt\d{6,10}$/.test(imdbId)) {
      throw new HttpsError(
        "invalid-argument",
        "imdbId must match /^tt\\d{6,10}$/",
      );
    }

    const db = admin.firestore();
    const ref = db.doc(`externalRatings/${imdbId}`);
    const snap = await ref.get();
    const now = Date.now();

    if (snap.exists) {
      const cached = snap.data() as ExternalRatings;
      if (cached.fetchedAtMs && isFresh(cached, now)) {
        return cached;
      }
    }

    let fresh: ExternalRatings;
    try {
      fresh = await fetchFromOmdb(imdbId, OMDB_API_KEY.value());
    } catch (err) {
      // If OMDb is down but we have stale cache, serve stale rather than fail.
      if (snap.exists) {
        logger.warn("OMDb failed, serving stale cache", {
          imdbId,
          error: (err as Error).message,
        });
        return snap.data();
      }
      // No stale cache: degrade to `notFound` instead of 500-ing the whole
      // call. A transient OMDb outage or auth/quota error shouldn't break
      // the title-detail render. We do NOT persist this negative response
      // — next call retries from scratch so a real fix (rotate key,
      // refresh quota) heals automatically.
      logger.error("OMDb fetch failed (no cache fallback)", {
        imdbId,
        error: (err as Error).message,
      });
      return {
        imdbId,
        imdbRating: null,
        imdbVotes: null,
        rtRating: null,
        metascore: null,
        fetchedAtMs: 0,
        source: "omdb" as const,
        notFound: true,
      } satisfies ExternalRatings;
    }

    await ref.set(fresh);
    return fresh;
  },
);
