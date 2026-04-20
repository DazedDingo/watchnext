import { onRequest } from "firebase-functions/v2/https";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";
import * as admin from "firebase-admin";
import * as crypto from "crypto";
import * as logger from "firebase-functions/logger";

/**
 * Stremio addon endpoint.
 *
 * Stremio expects an HTTP service that returns JSON per
 * https://github.com/Stremio/stremio-addon-sdk/blob/master/docs/README.md.
 *
 * This addon is private per-household: the user provisions a token via the
 * `provisionStremioToken` callable, then installs a URL of the form
 *     https://<cf-host>/stremio/{token}/manifest.json
 * into Stremio. Every subsequent request carries the token in its path, which
 * we look up in `/stremioTokens/{token}` to find the household.
 *
 * Scope shipped today: one catalog — "WatchNext Watchlist" — surfacing the
 * household's shared watchlist. Recommendations + in-progress catalogs are
 * roadmapped as a follow-up (see ROADMAP.md → Stremio integration track).
 */

// TMDB key — watchlist items don't store imdb_id, and Stremio keys everything
// by imdb_id, so we resolve missing ids via TMDB's `/movie/:id/external_ids`
// and `/tv/:id/external_ids` endpoints. The ids are cached back onto the
// watchlist doc after first lookup to avoid re-hitting TMDB.
const TMDB_API_KEY = defineSecret("TMDB_API_KEY");

const CATALOG_ID_WATCHLIST = "wn_watchlist";

type Household = {
  id: string;
  uid: string;
};

type WatchlistDoc = {
  media_type?: string;
  tmdb_id?: number;
  title?: string;
  year?: number;
  poster_path?: string;
  backdrop_path?: string;
  overview?: string;
  genres?: string[];
  imdb_id?: string | null;
  scope?: string;
  owner_uid?: string;
};

// ─── Manifest ───────────────────────────────────────────────────────────────

function buildManifest(householdId: string) {
  return {
    id: `dingo.watchnext.${householdId}`,
    version: "1.0.0",
    name: "WatchNext Watchlist",
    description:
      "Your household's shared WatchNext watchlist, browsable inside Stremio.",
    resources: ["catalog", "meta"],
    types: ["movie", "series"],
    catalogs: [
      { type: "movie", id: CATALOG_ID_WATCHLIST, name: "WatchNext — Movies" },
      { type: "series", id: CATALOG_ID_WATCHLIST, name: "WatchNext — Shows" },
    ],
    idPrefixes: ["tt"],
    behaviorHints: { configurable: false, configurationRequired: false },
  };
}

// A bare manifest returned by the unauthenticated /manifest.json. Tells users
// they need to provision a household-specific URL from the app first.
const PUBLIC_MANIFEST = {
  id: "dingo.watchnext.unconfigured",
  version: "1.0.0",
  name: "WatchNext (configure required)",
  description:
    "Open the WatchNext app → Profile → Stremio addon to get your private install URL.",
  resources: [],
  types: [],
  catalogs: [],
};

// ─── Token lookup ───────────────────────────────────────────────────────────

async function lookupToken(
  db: admin.firestore.Firestore,
  token: string,
): Promise<Household | null> {
  const snap = await db.collection("stremioTokens").doc(token).get();
  if (!snap.exists) return null;
  const d = snap.data() ?? {};
  const householdId = d.household_id as string | undefined;
  const uid = d.uid as string | undefined;
  if (!householdId || !uid) return null;
  // Touch last-used for debugging. Not critical — swallow failures.
  snap.ref.update({ last_used_at: admin.firestore.FieldValue.serverTimestamp() })
    .catch(() => {});
  return { id: householdId, uid };
}

// ─── TMDB imdb_id resolution ────────────────────────────────────────────────

async function fetchImdbId(
  apiKey: string,
  mediaType: "movie" | "tv",
  tmdbId: number,
): Promise<string | null> {
  const url =
    `https://api.themoviedb.org/3/${mediaType}/${tmdbId}/external_ids?api_key=${apiKey}`;
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    const j = (await res.json()) as { imdb_id?: string | null };
    const id = j.imdb_id;
    return id && id.startsWith("tt") ? id : null;
  } catch (e) {
    logger.warn("tmdb external_ids failed", { mediaType, tmdbId, err: String(e) });
    return null;
  }
}

// ─── Catalog / meta builders ────────────────────────────────────────────────

const TMDB_IMG = "https://image.tmdb.org/t/p";

function posterUrl(path: string | null | undefined): string | undefined {
  return path ? `${TMDB_IMG}/w500${path}` : undefined;
}

function backgroundUrl(path: string | null | undefined): string | undefined {
  return path ? `${TMDB_IMG}/w1280${path}` : undefined;
}

function stremioType(mt: string): "movie" | "series" {
  return mt === "tv" ? "series" : "movie";
}

async function loadWatchlist(
  db: admin.firestore.Firestore,
  householdId: string,
  filterType: "movie" | "series",
  apiKey: string,
): Promise<Array<WatchlistDoc & { imdbId: string; docRef: admin.firestore.DocumentReference }>> {
  // Only shared items go into Stremio — the addon is per-household, and solo
  // items shouldn't leak between members.
  const snap = await db
    .collection(`households/${householdId}/watchlist`)
    .where("scope", "==", "shared")
    .get();

  const out: Array<
    WatchlistDoc & { imdbId: string; docRef: admin.firestore.DocumentReference }
  > = [];

  for (const doc of snap.docs) {
    const d = doc.data() as WatchlistDoc;
    const mt = d.media_type ?? "movie";
    if (stremioType(mt) !== filterType) continue;
    if (!d.tmdb_id) continue;

    let imdb = d.imdb_id ?? null;
    if (!imdb) {
      imdb = await fetchImdbId(apiKey, mt === "tv" ? "tv" : "movie", d.tmdb_id);
      if (imdb) {
        // Cache back onto the doc so we don't re-fetch next time. Fire-and-
        // forget: a missed write just costs a repeat TMDB call later.
        doc.ref.update({ imdb_id: imdb }).catch(() => {});
      }
    }
    if (!imdb) continue;

    out.push({ ...d, imdbId: imdb, docRef: doc.ref });
  }

  return out;
}

function toCatalogMeta(
  row: WatchlistDoc & { imdbId: string },
  type: "movie" | "series",
) {
  return {
    id: row.imdbId,
    type,
    name: row.title ?? "Untitled",
    poster: posterUrl(row.poster_path ?? null),
    posterShape: "poster" as const,
    background: backgroundUrl(row.backdrop_path ?? null),
    description: row.overview ?? undefined,
    releaseInfo: row.year ? String(row.year) : undefined,
    genres: row.genres ?? [],
  };
}

function toFullMeta(
  row: WatchlistDoc & { imdbId: string },
  type: "movie" | "series",
) {
  // Stremio's meta object — slightly richer than the catalog preview. We have
  // nothing extra to offer today; Cinemeta fills in cast/runtime on the
  // client side once the imdb id lands.
  return toCatalogMeta(row, type);
}

// ─── HTTP handler ───────────────────────────────────────────────────────────

export const stremio = onRequest(
  {
    region: "europe-west2",
    secrets: [TMDB_API_KEY],
    cors: true, // Stremio web loads the addon in a browser sandbox.
    invoker: "public",
  },
  async (req, res) => {
    // Path shapes we accept (all optionally suffixed with `.json`):
    //   /manifest
    //   /{token}/manifest
    //   /{token}/catalog/{type}/{id}
    //   /{token}/catalog/{type}/{id}/{extra}   (search=, skip=, genre=)
    //   /{token}/meta/{type}/{id}
    const parts = req.path
      .replace(/^\/+/, "")
      .replace(/\.json$/, "")
      .split("/")
      .filter((p) => p.length > 0);

    // Always JSON. Stremio treats non-JSON responses as addon errors.
    res.set("Content-Type", "application/json; charset=utf-8");
    // Long-cache immutable responses. Stremio hammers the catalog on every
    // app open; we revalidate via stream ETags anyway.
    res.set("Cache-Control", "public, max-age=60");

    const db = admin.firestore();

    try {
      if (parts.length === 0 || (parts.length === 1 && parts[0] === "manifest")) {
        res.status(200).json(PUBLIC_MANIFEST);
        return;
      }

      const token = parts[0];
      const household = await lookupToken(db, token);
      if (!household) {
        res.status(404).json({ err: "invalid or expired token" });
        return;
      }

      const route = parts[1];
      if (route === "manifest") {
        res.status(200).json(buildManifest(household.id));
        return;
      }

      if (route === "catalog" && parts.length >= 4) {
        const type = parts[2] as "movie" | "series";
        const catalogId = parts[3];
        if (type !== "movie" && type !== "series") {
          res.status(400).json({ err: "unknown type" });
          return;
        }
        if (catalogId !== CATALOG_ID_WATCHLIST) {
          res.status(404).json({ err: "unknown catalog" });
          return;
        }
        const rows = await loadWatchlist(
          db, household.id, type, TMDB_API_KEY.value(),
        );
        res.status(200).json({
          metas: rows.map((r) => toCatalogMeta(r, type)),
        });
        return;
      }

      if (route === "meta" && parts.length >= 4) {
        const type = parts[2] as "movie" | "series";
        const imdbId = parts[3];
        if (type !== "movie" && type !== "series") {
          res.status(400).json({ err: "unknown type" });
          return;
        }
        const rows = await loadWatchlist(
          db, household.id, type, TMDB_API_KEY.value(),
        );
        const hit = rows.find((r) => r.imdbId === imdbId);
        if (!hit) {
          res.status(404).json({ err: "not in watchlist" });
          return;
        }
        res.status(200).json({ meta: toFullMeta(hit, type) });
        return;
      }

      res.status(404).json({ err: "unknown route" });
    } catch (e) {
      logger.error("stremio handler failed", {
        path: req.path,
        err: String(e),
      });
      res.status(500).json({ err: "internal" });
    }
  },
);

// ─── Provision callable ─────────────────────────────────────────────────────

/**
 * Mints a Stremio addon token for the caller's household (or returns the
 * existing one if already provisioned). Idempotent — calling twice returns the
 * same token so the install URL is stable across devices.
 *
 * Returns `{ token, installUrl }`. Clients should surface `installUrl` as both
 * a copyable string and a `stremio://` deep link (which the Stremio app
 * registers on install).
 */
export const provisionStremioToken = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }

  const db = admin.firestore();

  // Resolve the user's household via the `users/{uid}.householdId` pointer —
  // same shape the app reads via HouseholdService.getHouseholdIdForUser.
  const pointerSnap = await db.doc(`users/${uid}`).get();
  const householdId = pointerSnap.data()?.householdId as string | undefined;
  if (!householdId) {
    throw new HttpsError("failed-precondition", "No household on record.");
  }

  // Check for an existing token first. Tokens are indexed by token value, not
  // by household, so we use a collection query. Per household there should be
  // at most one per (uid, household) pair.
  const existing = await db
    .collection("stremioTokens")
    .where("household_id", "==", householdId)
    .where("uid", "==", uid)
    .limit(1)
    .get();

  if (!existing.empty) {
    const token = existing.docs[0].id;
    return { token, installUrl: buildInstallUrl(token) };
  }

  // 32 bytes of entropy → 64 hex chars. Brute forcing this is infeasible;
  // the token grants read of the household's watchlist via the addon.
  const token = crypto.randomBytes(32).toString("hex");
  await db.collection("stremioTokens").doc(token).set({
    household_id: householdId,
    uid,
    created_at: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { token, installUrl: buildInstallUrl(token) };
});

/**
 * Revokes the caller's Stremio addon token. Anyone who had the install URL
 * loses access after this call completes. Use when a user worries their
 * addon URL may have leaked.
 */
export const revokeStremioToken = onCall(async (request) => {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  const db = admin.firestore();
  const snap = await db
    .collection("stremioTokens")
    .where("uid", "==", uid)
    .get();
  const batch = db.batch();
  for (const doc of snap.docs) batch.delete(doc.ref);
  await batch.commit();
  return { revoked: snap.size };
});

function buildInstallUrl(token: string): string {
  // Raw Cloud Functions URL. Could front this with a Firebase Hosting rewrite
  // to get `https://watchnext.web.app/stremio/{token}/manifest.json`; noted
  // as a follow-up in ROADMAP.md.
  return `https://europe-west2-watchnext-9920f.cloudfunctions.net/stremio/${token}/manifest.json`;
}
