import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { DEBOUNCE_WINDOW_MS, validateInput } from "./issueQueue";

export interface EnqueueInput {
  householdId: string;
  uid: string;
  submitter: string;
  title: string;
  description: string;
}

export interface EnqueueResult {
  batchId: string;
  appended: boolean;
  itemCount: number;
  dispatchAtMs: number;
}

/**
 * Core enqueue logic extracted from the onCall wrapper so unit tests can
 * exercise the append-vs-create branch without firebase-functions-test.
 *
 * Contract:
 * - Caller is already authenticated and has been verified as a household member.
 * - If a pending batch for this uid already exists, append + reset window.
 * - Otherwise create a new batch with a single item.
 */
export async function enqueueIssue(
  db: admin.firestore.Firestore,
  input: EnqueueInput,
): Promise<EnqueueResult> {
  const batchesCol = db.collection(
    `households/${input.householdId}/issueBatches`,
  );

  const pendingSnap = await batchesCol
    .where("uid", "==", input.uid)
    .where("status", "==", "pending")
    .limit(1)
    .get();

  const now = admin.firestore.Timestamp.now();
  const dispatchAt = admin.firestore.Timestamp.fromMillis(
    now.toMillis() + DEBOUNCE_WINDOW_MS,
  );
  const newItem = {
    title: input.title,
    description: input.description,
    submittedAt: now,
  };

  return db.runTransaction(async (tx) => {
    if (!pendingSnap.empty) {
      const ref = pendingSnap.docs[0].ref;
      const fresh = await tx.get(ref);
      const data = fresh.data();
      if (fresh.exists && data?.status === "pending") {
        tx.update(ref, {
          items: admin.firestore.FieldValue.arrayUnion(newItem),
          dispatchAt,
          updatedAt: now,
        });
        return {
          batchId: ref.id,
          appended: true,
          itemCount: (data.items?.length ?? 0) + 1,
          dispatchAtMs: dispatchAt.toMillis(),
        };
      }
    }
    const ref = batchesCol.doc();
    tx.set(ref, {
      uid: input.uid,
      submitter: input.submitter,
      items: [newItem],
      createdAt: now,
      dispatchAt,
      status: "pending",
    });
    return {
      batchId: ref.id,
      appended: false,
      itemCount: 1,
      dispatchAtMs: dispatchAt.toMillis(),
    };
  });
}

/**
 * Enqueues an issue report. First submission opens a 10-minute window; any
 * further submissions from the same uid while the window is open append to
 * that batch and reset the clock. `drainIssueQueue` picks up batches once
 * their dispatch time has passed and files them on GitHub.
 */
export const submitIssue = onCall(async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in required");
  }

  const householdId = String(request.data?.householdId ?? "").trim();
  if (householdId.length === 0) {
    throw new HttpsError("invalid-argument", "householdId is required");
  }

  let title: string;
  let description: string;
  try {
    const v = validateInput(request.data?.title, request.data?.description);
    title = v.title;
    description = v.description;
  } catch (e) {
    throw new HttpsError("invalid-argument", (e as Error).message);
  }

  const uid = request.auth.uid;
  const submitter =
    (request.auth.token.name as string | undefined) ||
    (request.auth.token.email as string | undefined) ||
    uid;

  const db = admin.firestore();

  const memberSnap = await db
    .doc(`households/${householdId}/members/${uid}`)
    .get();
  if (!memberSnap.exists) {
    throw new HttpsError("permission-denied", "Not a member of this household");
  }

  const result = await enqueueIssue(db, {
    householdId,
    uid,
    submitter,
    title,
    description,
  });

  logger.info("Issue enqueued", {
    householdId,
    batchId: result.batchId,
    appended: result.appended,
    itemCount: result.itemCount,
  });

  return result;
});
