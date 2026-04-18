import * as admin from "firebase-admin";
import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import Anthropic from "@anthropic-ai/sdk";

import {
  Candidate,
  scoreAndWriteCandidates,
  trimProfileForPrompt,
} from "./scoreRecommendations";
import { buildAndWriteTasteProfile } from "./tasteProfile";

/**
 * Scheduled re-scoring pipeline.
 *
 * When a household member rates a title, their taste signal shifts — but the
 * stored /recommendations docs were scored against the *old* signal and will
 * stay stale until the client manually invokes `scoreRecommendations`. This
 * module closes that loop with two CFs:
 *
 *   1. `onRatingWritten` — Firestore trigger on any rating create/update.
 *      Cheap: just stamps a marker at /rescoreQueue/{householdId} so the
 *      household joins the drain backlog. No Claude calls here.
 *
 *   2. `processRescoreQueue` — scheduled drain (every 10 min). For each dirty
 *      household it regenerates the taste profile, reads current /recommendations
 *      as the candidate list, and runs the same Claude batch scorer the on-demand
 *      callable uses — so existing recs get refreshed in place.
 *
 * Natural debounce: many rating writes in a 10-min window collapse into one
 * drain pass because the marker doc is overwritten each time. The drain clears
 * the marker only after a successful run, so transient Claude errors leave the
 * household dirty for the next sweep.
 */

const ANTHROPIC_API_KEY = defineSecret("ANTHROPIC_API_KEY");
const DEFAULT_MODEL = "claude-sonnet-4-6";
const QUEUE_COLLECTION = "rescoreQueue";
/** Cap candidates per drain run to stay within scheduled-function budget. */
const MAX_CANDIDATES_PER_DRAIN = 50;

type QueueDoc = {
  household_id: string;
  dirty_since: admin.firestore.Timestamp;
  last_scored_at?: admin.firestore.Timestamp;
};

/**
 * Firestore trigger — stamps the household's rescore marker whenever a rating
 * doc is created, updated, or deleted. Deliberately idempotent: repeated calls
 * just bump `dirty_since` forward; the drain picks up the latest value.
 */
export const onRatingWritten = onDocumentWritten(
  {
    document: "households/{householdId}/ratings/{ratingId}",
    region: "europe-west2",
  },
  async (event) => {
    const householdId = event.params.householdId;
    await admin
      .firestore()
      .doc(`${QUEUE_COLLECTION}/${householdId}`)
      .set(
        {
          household_id: householdId,
          dirty_since: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
  },
);

/**
 * Reads the household's existing recommendations and returns them in the
 * `Candidate` shape the batch scorer expects. Capped at MAX_CANDIDATES_PER_DRAIN
 * so one household with a huge backlog doesn't starve the scheduler.
 *
 * Sort: most-recent first. The freshest recs matter most to the user, so if
 * we can't get through all of them in one run we at least refresh the ones
 * most likely to be seen on Home.
 */
export async function loadCandidatesFromRecs(
  db: admin.firestore.Firestore,
  householdId: string,
): Promise<Candidate[]> {
  const snap = await db
    .collection(`households/${householdId}/recommendations`)
    .orderBy("generated_at", "desc")
    .limit(MAX_CANDIDATES_PER_DRAIN)
    .get();
  const out: Candidate[] = [];
  for (const d of snap.docs) {
    const data = d.data();
    if (
      typeof data.media_type !== "string" ||
      typeof data.tmdb_id !== "number" ||
      typeof data.title !== "string"
    ) {
      continue;
    }
    out.push({
      media_type: data.media_type,
      tmdb_id: data.tmdb_id,
      title: data.title,
      year: data.year ?? null,
      poster_path: data.poster_path ?? null,
      genres: Array.isArray(data.genres) ? data.genres : [],
      runtime: data.runtime ?? null,
      overview: data.overview ?? null,
      source: data.source ?? "unknown",
    });
  }
  return out;
}

/**
 * Filters a full queue listing down to the households that actually need
 * re-scoring. A household is dirty iff `dirty_since > last_scored_at`
 * (or `last_scored_at` is missing).
 *
 * Extracted for unit testing — the scheduled function just wraps the query
 * around it.
 */
export function selectDirtyHouseholds(docs: QueueDoc[]): string[] {
  const out: string[] = [];
  for (const d of docs) {
    const dirty = d.dirty_since?.toMillis?.() ?? 0;
    const scored = d.last_scored_at?.toMillis?.() ?? 0;
    if (dirty > scored) out.push(d.household_id);
  }
  return out;
}

/**
 * Re-scores one household end-to-end: regenerates taste profile, reads current
 * recs as candidates, runs Claude batch scorer, writes back. Clears the queue
 * marker on success. Transient failures leave the marker dirty so the next
 * sweep retries.
 */
export async function rescoreOneHousehold(params: {
  db: admin.firestore.Firestore;
  anthropic: Anthropic;
  householdId: string;
  model: string;
}): Promise<{ written: number; scored: number; skipped?: string }> {
  const { db, anthropic, householdId, model } = params;

  const candidates = await loadCandidatesFromRecs(db, householdId);
  if (candidates.length === 0) {
    // Nothing to re-score — clear the marker so we don't spin.
    await db
      .doc(`${QUEUE_COLLECTION}/${householdId}`)
      .set(
        { last_scored_at: admin.firestore.FieldValue.serverTimestamp() },
        { merge: true },
      );
    return { written: 0, scored: 0, skipped: "no-candidates" };
  }

  await buildAndWriteTasteProfile(db, householdId);
  const profileSnap = await db
    .doc(`households/${householdId}/tasteProfile/default`)
    .get();
  const profile = trimProfileForPrompt(profileSnap.data());

  const result = await scoreAndWriteCandidates({
    db,
    anthropic,
    householdId,
    candidates,
    profile,
    model,
  });

  await db
    .doc(`${QUEUE_COLLECTION}/${householdId}`)
    .set(
      { last_scored_at: admin.firestore.FieldValue.serverTimestamp() },
      { merge: true },
    );

  return result;
}

/**
 * Scheduled drain — every 10 minutes scan the queue, rescore each dirty
 * household, log a summary. Failures on one household do not abort the rest.
 */
export const processRescoreQueue = onSchedule(
  {
    schedule: "every 10 minutes",
    region: "europe-west2",
    secrets: [ANTHROPIC_API_KEY],
    timeoutSeconds: 540,
  },
  async () => {
    const db = admin.firestore();
    const snap = await db.collection(QUEUE_COLLECTION).get();
    const docs: QueueDoc[] = snap.docs.map((d) => d.data() as QueueDoc);
    const dirty = selectDirtyHouseholds(docs);
    if (dirty.length === 0) return;

    const anthropic = new Anthropic({ apiKey: ANTHROPIC_API_KEY.value() });
    const model = process.env.ANTHROPIC_MODEL || DEFAULT_MODEL;

    let succeeded = 0;
    let failed = 0;
    for (const hh of dirty) {
      try {
        const r = await rescoreOneHousehold({
          db,
          anthropic,
          householdId: hh,
          model,
        });
        logger.info("rescored household", { householdId: hh, ...r });
        succeeded += 1;
      } catch (err) {
        failed += 1;
        logger.error("rescore failed", { householdId: hh, err });
      }
    }
    logger.info("rescore sweep complete", {
      dirty: dirty.length,
      succeeded,
      failed,
    });
  },
);
