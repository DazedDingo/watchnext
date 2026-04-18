/**
 * Shared helpers for the "Fix this" issue queue.
 *
 * Submissions debounce: a user's first item opens a 10-minute window; any
 * further submission from the same user while the window is open appends to
 * the same batch and resets the clock. When the window closes, the whole
 * batch gets filed as a single GitHub issue.
 *
 * Pure helpers live here so the TS test suite can cover body/title formatting
 * without mocking Firestore or the GitHub API.
 */

export const MAX_TITLE = 200;
export const MAX_BODY = 4000;
export const DEBOUNCE_WINDOW_MS = 10 * 60 * 1000;

export type BatchStatus = "pending" | "dispatched" | "cancelled";

export interface FlattenedItem {
  title: string;
  description: string;
  submittedAtMs: number;
}

export function buildBundledTitle(items: Array<{ title: string }>): string {
  if (items.length === 0) return "Issue report";
  if (items.length === 1) return items[0].title;
  return `${items[0].title} (+${items.length - 1} more)`;
}

export function buildBundledBody(items: FlattenedItem[], submitter: string): string {
  if (items.length === 0) {
    return `_(empty batch submitted by **${submitter}**)_`;
  }
  if (items.length === 1) {
    const it = items[0];
    return [
      it.description.trim() || "_(no description)_",
      "",
      "---",
      `_Submitted from app by **${submitter}**_`,
    ].join("\n");
  }

  const lines: string[] = [];
  lines.push(
    `_${items.length} issues submitted from app by **${submitter}**, bundled together._`,
  );
  lines.push("");
  items.forEach((it, i) => {
    const when = new Date(it.submittedAtMs).toISOString();
    lines.push("---");
    lines.push("");
    lines.push(`### ${i + 1}. ${it.title}`);
    lines.push(`_Submitted at ${when}_`);
    lines.push("");
    lines.push(it.description.trim() || "_(no description)_");
    lines.push("");
  });
  return lines.join("\n").trimEnd();
}

export function validateInput(
  rawTitle: unknown,
  rawDescription: unknown,
): { title: string; description: string } {
  const title = String(rawTitle ?? "").trim();
  const description = String(rawDescription ?? "").trim();
  if (title.length === 0 || title.length > MAX_TITLE) {
    throw new Error(`Title must be 1–${MAX_TITLE} characters`);
  }
  if (description.length > MAX_BODY) {
    throw new Error(`Description must be ≤${MAX_BODY} characters`);
  }
  return { title, description };
}
