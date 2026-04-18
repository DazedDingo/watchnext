import * as admin from "firebase-admin";
import { setGlobalOptions } from "firebase-functions/v2";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineSecret } from "firebase-functions/params";
import * as logger from "firebase-functions/logger";
import { processIssueQueue, makeGitHubPoster } from "./processIssueQueue";

// Firestore lives in europe-west2 (London). Co-locate all CFs so the
// client round-trip and CF→Firestore hops stay intra-region.
setGlobalOptions({ region: "europe-west2" });

admin.initializeApp();

export { generateTasteProfile } from "./tasteProfile";
export { scoreRecommendations } from "./scoreRecommendations";
export { redditScraper } from "./redditScraper";
export { concierge } from "./concierge";
export { onRatingCreated } from "./notifications";
export { submitIssue } from "./submitIssue";
export {
  onRatingWritten,
  processRescoreQueue,
} from "./rescoreRecommendations";
export {
  onWatchEntryWrittenBadges,
  onMemberWrittenBadges,
  onTasteProfileWrittenBadges,
  onRatingWrittenBadges,
} from "./gamificationUpdater";

const GITHUB_PAT = defineSecret("GITHUB_PAT");

// Drains the debounced issue queue every 2 minutes — files bundled batches
// to GitHub.
export const drainIssueQueue = onSchedule(
  {
    schedule: "every 2 minutes",
    region: "europe-west2",
    secrets: [GITHUB_PAT],
  },
  async () => {
    const result = await processIssueQueue(makeGitHubPoster(GITHUB_PAT.value()));
    if (result.dispatched > 0 || result.errors > 0) {
      logger.info("Issue queue drained", result);
    }
  },
);

/**
 * Trakt OAuth proxy.
 *
 * Why this exists: Trakt's `client_secret` must stay off-device. The app calls
 * these three callables instead of hitting /oauth/token or /oauth/revoke
 * directly. The client_id is not a secret (Trakt uses it as the
 * `trakt-api-key` request header on every call, so it must ship with the
 * client anyway) and remains in the Flutter app.
 */

const TRAKT_CLIENT_ID = defineSecret("TRAKT_CLIENT_ID");
const TRAKT_CLIENT_SECRET = defineSecret("TRAKT_CLIENT_SECRET");

const TRAKT_TOKEN_URL = "https://api.trakt.tv/oauth/token";
const TRAKT_REVOKE_URL = "https://api.trakt.tv/oauth/revoke";

type TraktTokenResponse = {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  created_at: number;
  token_type: string;
  scope: string;
};

function requireAuth(authUid: string | undefined): string {
  if (!authUid) {
    throw new HttpsError("unauthenticated", "Sign in required.");
  }
  return authUid;
}

function requireString(v: unknown, field: string): string {
  if (typeof v !== "string" || v.length === 0) {
    throw new HttpsError("invalid-argument", `Missing or invalid '${field}'.`);
  }
  return v;
}

async function postTraktToken(body: Record<string, string>): Promise<TraktTokenResponse> {
  const res = await fetch(TRAKT_TOKEN_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Accept": "application/json",
      "User-Agent": "watchnext/1.0 (+https://github.com/DazedDingo/watchnext)",
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new HttpsError(
      "internal",
      `Trakt token endpoint ${res.status}: ${text.slice(0, 500)}`,
    );
  }
  return (await res.json()) as TraktTokenResponse;
}

export const traktExchangeCode = onCall(
  { secrets: [TRAKT_CLIENT_ID, TRAKT_CLIENT_SECRET] },
  async (request) => {
    const uid = requireAuth(request.auth?.uid);
    const code = requireString(request.data?.code, "code");
    const redirectUri = requireString(request.data?.redirectUri, "redirectUri");

    const json = await postTraktToken({
      code,
      client_id: TRAKT_CLIENT_ID.value(),
      client_secret: TRAKT_CLIENT_SECRET.value(),
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    });

    return {
      access_token: json.access_token,
      refresh_token: json.refresh_token,
      expires_at_seconds: (json.created_at ?? Math.floor(Date.now() / 1000)) +
        (json.expires_in ?? 7776000),
      uid,
    };
  },
);

export const traktRefreshToken = onCall(
  { secrets: [TRAKT_CLIENT_ID, TRAKT_CLIENT_SECRET] },
  async (request) => {
    requireAuth(request.auth?.uid);
    const refreshToken = requireString(request.data?.refreshToken, "refreshToken");
    const redirectUri = requireString(request.data?.redirectUri, "redirectUri");

    const json = await postTraktToken({
      refresh_token: refreshToken,
      client_id: TRAKT_CLIENT_ID.value(),
      client_secret: TRAKT_CLIENT_SECRET.value(),
      redirect_uri: redirectUri,
      grant_type: "refresh_token",
    });

    return {
      access_token: json.access_token,
      refresh_token: json.refresh_token,
      expires_at_seconds: (json.created_at ?? Math.floor(Date.now() / 1000)) +
        (json.expires_in ?? 7776000),
    };
  },
);

export const traktRevoke = onCall(
  { secrets: [TRAKT_CLIENT_ID, TRAKT_CLIENT_SECRET] },
  async (request) => {
    requireAuth(request.auth?.uid);
    const token = requireString(request.data?.token, "token");

    const res = await fetch(TRAKT_REVOKE_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "watchnext/1.0 (+https://github.com/DazedDingo/watchnext)",
      },
      body: JSON.stringify({
        token,
        client_id: TRAKT_CLIENT_ID.value(),
        client_secret: TRAKT_CLIENT_SECRET.value(),
      }),
    });
    return { ok: res.ok, status: res.status };
  },
);
