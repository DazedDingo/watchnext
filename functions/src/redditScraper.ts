import * as admin from "firebase-admin";
import { onSchedule } from "firebase-functions/v2/scheduler";

/**
 * Weekly Reddit scraper — every Sunday at 03:00 UTC.
 *
 * Fetches top weekly posts from film/TV subreddits, extracts title candidates
 * from post titles, cross-references against TMDB, and writes aggregated
 * mention counts to /redditMentions/{mediaType:tmdbId}.
 *
 * The per-household RecommendationsService.refresh() picks these up and
 * includes them in the Claude scoring candidate pool with source="reddit".
 *
 * Privacy: no Reddit auth required — only public JSON endpoints.
 */

const SUBREDDITS = [
  "MovieSuggestions",
  "televisionsuggestions",
  "flicks",
  "movies",
  "television",
  "Letterboxd",
];

const TMDB_API_KEY = process.env.TMDB_API_KEY ?? "";
const TMDB_BASE = "https://api.themoviedb.org/3";

type RedditPost = {
  title: string;
  score: number;
  url: string;
};

type TmdbResult = {
  id: number;
  media_type: "movie" | "tv";
  title?: string;
  name?: string;
  poster_path?: string;
  genre_ids?: number[];
  overview?: string;
  release_date?: string;
  first_air_date?: string;
};

// ---------------------------------------------------------------------------
// Title extraction from Reddit post titles
// ---------------------------------------------------------------------------

/**
 * Light heuristic to pull a movie/show title from a Reddit post title.
 *
 * Handles common formats:
 *   "Inception (2010)" → "Inception"
 *   "What are your thoughts on The Bear?" → "The Bear"
 *   "[DISCUSSION] Oppenheimer - was it worth the hype?" → "Oppenheimer"
 *   "Just finished Severance, absolutely loved it" → "Severance"
 */
export function extractTitle(postTitle: string): string | null {
  // Strip leading [TAG] markers.
  const cleaned = postTitle.replace(/^\[.*?\]\s*/, "").trim();

  // Pattern 1: "Title (year)" — most reliable.
  const yearMatch = cleaned.match(/^([^([]+)\s*\(\d{4}\)/);
  if (yearMatch) return yearMatch[1].trim();

  // Pattern 2: "Title - something" or "Title: something".
  const dashMatch = cleaned.match(/^([A-Z][^-:?!,.([\n]{3,60}?)[\s]*[-:?!,]/);
  if (dashMatch) return dashMatch[1].trim();

  // Pattern 3: Short capitalised lead phrase (≤5 words before punctuation).
  const shortMatch = cleaned.match(/^([A-Z][A-Za-z0-9':& ]{2,40})(?:[,!?.]|$)/);
  if (shortMatch && shortMatch[1].split(" ").length <= 6) {
    return shortMatch[1].trim();
  }

  return null;
}

// ---------------------------------------------------------------------------
// TMDB lookup
// ---------------------------------------------------------------------------

async function tmdbSearch(query: string): Promise<TmdbResult | null> {
  if (!TMDB_API_KEY) return null;
  const url = `${TMDB_BASE}/search/multi?api_key=${TMDB_API_KEY}&language=en-US&query=${encodeURIComponent(query)}&page=1`;
  try {
    const res = await fetch(url);
    if (!res.ok) return null;
    const data = (await res.json()) as { results?: TmdbResult[] };
    const results = (data.results ?? []).filter(
      (r) => r.media_type === "movie" || r.media_type === "tv",
    );
    return results[0] ?? null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Reddit fetch
// ---------------------------------------------------------------------------

async function fetchTopPosts(subreddit: string): Promise<RedditPost[]> {
  const url = `https://www.reddit.com/r/${subreddit}/top.json?t=week&limit=50`;
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": "WatchNext/1.0 (firebase cloud function)" },
    });
    if (!res.ok) return [];
    const data = await res.json() as {
      data?: { children?: { data: { title: string; score: number; url: string } }[] };
    };
    return (data.data?.children ?? []).map((c) => ({
      title: c.data.title,
      score: c.data.score,
      url: c.data.url,
    }));
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// Scheduled job
// ---------------------------------------------------------------------------

export const redditScraper = onSchedule(
  { schedule: "every sunday 03:00", region: "europe-west2", timeZone: "UTC", timeoutSeconds: 540 },
  async () => {
    const db = admin.firestore();

    // Fetch posts from all subreddits in parallel.
    const allPostsArrays = await Promise.all(SUBREDDITS.map(fetchTopPosts));
    const allPosts = allPostsArrays.flat();

    // Extract titles and deduplicate by candidate string.
    const titleScores = new Map<string, number>();
    for (const post of allPosts) {
      const title = extractTitle(post.title);
      if (!title || title.length < 3) continue;
      const key = title.toLowerCase().trim();
      titleScores.set(key, (titleScores.get(key) ?? 0) + post.score);
    }

    // Take the top 60 by combined score (avoids burning TMDB quota).
    const topTitles = Array.from(titleScores.entries())
      .sort((a, b) => b[1] - a[1])
      .slice(0, 60)
      .map(([title]) => title);

    // TMDB lookup — rate-limit to one request per 250ms to stay within free tier.
    const resolved = new Map<
      string,
      { result: TmdbResult; mentionScore: number }
    >();

    for (const [i, title] of topTitles.entries()) {
      if (i > 0) await new Promise((r) => setTimeout(r, 250));
      const result = await tmdbSearch(title);
      if (!result || !result.id) continue;
      const key = `${result.media_type}:${result.id}`;
      const score = titleScores.get(title) ?? 1;
      const existing = resolved.get(key);
      if (!existing || existing.mentionScore < score) {
        resolved.set(key, { result, mentionScore: score });
      }
    }

    if (resolved.size === 0) {
      console.log("redditScraper: no results resolved");
      return;
    }

    // Write to /redditMentions in a bulk writer.
    const writer = db.bulkWriter();
    const now = admin.firestore.FieldValue.serverTimestamp();

    for (const [key, { result, mentionScore }] of resolved) {
      const date = result.release_date ?? result.first_air_date;
      const year = date && date.length >= 4 ? parseInt(date.slice(0, 4)) : null;
      writer.set(
        db.doc(`redditMentions/${key}`),
        {
          media_type: result.media_type,
          tmdb_id: result.id,
          title: (result.title ?? result.name) || "Untitled",
          year,
          poster_path: result.poster_path ?? null,
          overview: result.overview ?? null,
          mention_score: mentionScore,
          last_updated: now,
        },
        { merge: true },
      );
    }
    await writer.close();
    console.log(`redditScraper: wrote ${resolved.size} docs to /redditMentions`);
  },
);
