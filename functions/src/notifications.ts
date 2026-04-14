import * as admin from "firebase-admin";
import { onDocumentCreated } from "firebase-functions/v2/firestore";

/**
 * Reveal-ready push notification (Phase 10).
 *
 * Fires when a movie/show rating is written. If a prediction document
 * exists for that title and the partner has an outstanding prediction they
 * haven't revealed yet, we send them an FCM push.
 *
 * Token storage: /households/{hh}/members/{uid}.fcm_token (written by Flutter).
 * Notification payload is data-only so the Flutter handler can route to
 * /reveal/:mediaType/:tmdbId.
 */
export const onRatingCreated = onDocumentCreated(
  {
    document: "households/{hh}/ratings/{ratingId}",
    region: "europe-west2",
  },
  async (event) => {
    const data = event.data?.data();
    if (!data) return;

    const { uid, level, target_id: targetId } = data as {
      uid: string;
      level: string;
      target_id: string;
    };

    // Only care about movie/show-level ratings.
    if (level !== "movie" && level !== "show") return;

    const hh = event.params.hh;
    const db = admin.firestore();

    // Check for a matching prediction document.
    const predRef = db.doc(`households/${hh}/predictions/${targetId}`);
    const predSnap = await predRef.get();
    if (!predSnap.exists) return;

    const pred = predSnap.data()!;
    const entries = pred.entries as Record<string, unknown> | undefined;
    const revealSeen = pred.reveal_seen as Record<string, boolean> | undefined;

    // Rater must have predicted (otherwise there's nothing to reveal).
    if (!entries?.[uid]) return;

    // Find the partner: load members and pick the one who isn't the rater.
    const membersSnap = await db
      .collection(`households/${hh}/members`)
      .get();

    if (membersSnap.size < 2) return; // solo household — no partner to notify

    const partnerDoc = membersSnap.docs.find((d) => d.id !== uid);
    if (!partnerDoc) return;

    const partnerUid = partnerDoc.id;

    // Partner must also have a prediction entry (not just skipped).
    const partnerEntry = entries?.[partnerUid] as { skipped?: boolean } | undefined;
    if (!partnerEntry || partnerEntry.skipped) return;

    // Skip if partner already saw the reveal.
    if (revealSeen?.[partnerUid] === true) return;

    // Get the partner's FCM token.
    const fcmToken = partnerDoc.data().fcm_token as string | undefined;
    if (!fcmToken) return;

    // Parse targetId into mediaType + tmdbId (format: "movie:12345" or "tv:67890").
    const colonIdx = targetId.indexOf(":");
    if (colonIdx === -1) return;
    const mediaType = targetId.slice(0, colonIdx);
    const tmdbId = targetId.slice(colonIdx + 1);
    const title = pred.title as string | undefined ?? "a title";

    // Send data-only FCM message so Flutter handles routing.
    try {
      await admin.messaging().send({
        token: fcmToken,
        data: {
          type: "reveal_ready",
          media_type: mediaType,
          tmdb_id: tmdbId,
          title,
        },
        notification: {
          title: "Reveal time!",
          body: `See how well you predicted ${title}`,
        },
        android: {
          priority: "normal",
        },
      });
    } catch (err) {
      // Token may be stale — log and move on, don't fail the trigger.
      console.warn(`onRatingCreated: FCM send failed for ${partnerUid}:`, err);
    }
  },
);
