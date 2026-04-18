import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { buildBundledBody, buildBundledTitle, FlattenedItem } from "./issueQueue";

const REPO_OWNER = "DazedDingo";
const REPO_NAME = "watchnext";

export interface ProcessResult {
  scanned: number;
  dispatched: number;
  errors: number;
}

type GitHubPoster = (payload: {
  title: string;
  body: string;
  labels: string[];
}) => Promise<{ number: number; url: string }>;

/**
 * Processes any pending batches whose debounce window has closed. Each batch
 * becomes one GitHub issue; the doc is marked `dispatched` with the resulting
 * issue number + URL.
 *
 * The GitHub poster is injected so tests don't need to stub `fetch`.
 */
export async function processIssueQueue(
  postToGitHub: GitHubPoster,
  db: admin.firestore.Firestore = admin.firestore(),
): Promise<ProcessResult> {
  const now = admin.firestore.Timestamp.now();
  const snap = await db
    .collectionGroup("issueBatches")
    .where("status", "==", "pending")
    .where("dispatchAt", "<=", now)
    .get();

  let dispatched = 0;
  let errors = 0;
  for (const doc of snap.docs) {
    const data = doc.data();
    const rawItems = Array.isArray(data.items) ? data.items : [];
    const items: FlattenedItem[] = rawItems.map((it: any) => ({
      title: String(it?.title ?? ""),
      description: String(it?.description ?? ""),
      submittedAtMs: it?.submittedAt?.toMillis?.() ?? Date.now(),
    }));

    const submitter = String(data.submitter ?? data.uid ?? "unknown");
    const title = buildBundledTitle(items);
    const body = buildBundledBody(items, submitter);

    try {
      const res = await postToGitHub({ title, body, labels: ["from-app"] });
      await doc.ref.update({
        status: "dispatched",
        dispatchedAt: admin.firestore.Timestamp.now(),
        dispatchResult: { issueNumber: res.number, url: res.url },
      });
      logger.info("Batch dispatched", {
        batchId: doc.id,
        issueNumber: res.number,
        itemCount: items.length,
      });
      dispatched++;
    } catch (e) {
      errors++;
      logger.error("Batch dispatch failed", {
        batchId: doc.id,
        error: (e as Error).message,
      });
      const retryAt = admin.firestore.Timestamp.fromMillis(
        Date.now() + 5 * 60 * 1000,
      );
      await doc.ref.update({
        dispatchAt: retryAt,
        lastError: (e as Error).message,
      });
    }
  }

  return { scanned: snap.size, dispatched, errors };
}

export function makeGitHubPoster(pat: string): GitHubPoster {
  return async ({ title, body, labels }) => {
    const res = await fetch(
      `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/issues`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${pat}`,
          Accept: "application/vnd.github+json",
          "X-GitHub-Api-Version": "2022-11-28",
          "Content-Type": "application/json",
          "User-Agent": "watchnext",
        },
        body: JSON.stringify({ title, body, labels }),
      },
    );
    if (!res.ok) {
      const text = await res.text();
      throw new Error(`GitHub API ${res.status}: ${text}`);
    }
    const issue = (await res.json()) as { number: number; html_url: string };
    return { number: issue.number, url: issue.html_url };
  };
}
