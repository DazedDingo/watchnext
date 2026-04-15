import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  deleteDoc,
  serverTimestamp,
  setLogLevel,
} from "firebase/firestore";
import * as fs from "fs";
import * as path from "path";

/**
 * End-to-end security rules tests. The rules file is loaded directly from the
 * repo so any edit to firestore.rules is reflected on the next `npm test` run.
 *
 * Every collection the Flutter client can touch is exercised from three
 * angles: the owner member, the partner member, and an unauthenticated /
 * outside caller. Missing rules → default-deny → test fails loudly.
 */

setLogLevel("error");

const PROJECT_ID = "watchnext-rules-test";
const HH = "hh1";
const U1 = "u1"; // household member
const U2 = "u2"; // household member
const U3 = "u3"; // stranger

let env: RulesTestEnvironment;

beforeAll(async () => {
  env = await initializeTestEnvironment({
    projectId: PROJECT_ID,
    firestore: {
      rules: fs.readFileSync(
        path.resolve(__dirname, "..", "firestore.rules"),
        "utf8",
      ),
    },
  });
});

afterAll(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
  // Seed a 2-member household so isMember() returns true for U1 and U2 but
  // not U3. Writes happen with the security rules bypassed.
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, `households/${HH}`), {
      createdBy: U1,
      invite_code: "abc" + "0".repeat(29),
    });
    await setDoc(doc(db, `households/${HH}/members/${U1}`), {
      display_name: "Alice",
    });
    await setDoc(doc(db, `households/${HH}/members/${U2}`), {
      display_name: "Bob",
    });
  });
});

function member(uid: string) {
  return env.authenticatedContext(uid).firestore();
}

function stranger() {
  return env.unauthenticatedContext().firestore();
}

// ---------------------------------------------------------------------------
// /households/{id}
// ---------------------------------------------------------------------------
describe("households/{id}", () => {
  test("any authed user can create a household", async () => {
    const db = member(U3);
    await assertSucceeds(
      setDoc(doc(db, "households/brand-new"), {
        createdBy: U3,
        created_at: serverTimestamp(),
        invite_code: "z".repeat(32),
      }),
    );
  });

  test("unauth'd user cannot create a household", async () => {
    await assertFails(
      setDoc(doc(stranger(), "households/x"), { createdBy: "x" }),
    );
  });

  test("member can read household doc", async () => {
    await assertSucceeds(getDoc(doc(member(U1), `households/${HH}`)));
    await assertSucceeds(getDoc(doc(member(U2), `households/${HH}`)));
  });

  test("stranger cannot read household doc", async () => {
    await assertFails(getDoc(doc(member(U3), `households/${HH}`)));
    await assertFails(getDoc(doc(stranger(), `households/${HH}`)));
  });

  test("member can update, stranger cannot", async () => {
    await assertSucceeds(
      updateDoc(doc(member(U1), `households/${HH}`), { invite_code: "new" + "0".repeat(29) }),
    );
    await assertFails(
      updateDoc(doc(member(U3), `households/${HH}`), { createdBy: "hacker" }),
    );
  });

  test("nobody can delete a household", async () => {
    await assertFails(deleteDoc(doc(member(U1), `households/${HH}`)));
    await assertFails(deleteDoc(doc(member(U2), `households/${HH}`)));
  });
});

// ---------------------------------------------------------------------------
// /households/{id}/members/{uid}
// ---------------------------------------------------------------------------
describe("members/{uid}", () => {
  test("member can read both members", async () => {
    await assertSucceeds(getDoc(doc(member(U1), `households/${HH}/members/${U1}`)));
    await assertSucceeds(getDoc(doc(member(U1), `households/${HH}/members/${U2}`)));
  });

  test("stranger cannot read any member", async () => {
    await assertFails(getDoc(doc(member(U3), `households/${HH}/members/${U1}`)));
  });

  test("user can create/update their own member doc", async () => {
    await assertSucceeds(
      setDoc(doc(member(U1), `households/${HH}/members/${U1}`), {
        display_name: "Alice 2",
      }),
    );
  });

  test("user cannot create a member doc with someone else's uid", async () => {
    await assertFails(
      setDoc(doc(member(U1), `households/${HH}/members/${U2}`), {
        display_name: "hijack",
      }),
    );
  });

  test("nobody can delete a member doc", async () => {
    await assertFails(deleteDoc(doc(member(U1), `households/${HH}/members/${U1}`)));
  });
});

// ---------------------------------------------------------------------------
// Household sub-collections — all use the isMember(householdId) predicate
// ---------------------------------------------------------------------------
const sharedCollections = [
  "watchEntries",
  "ratings",
  "watchlist", // REGRESSION GUARD — missing rule silently broke the feature
  "predictions",
  "recommendations",
  "decisionHistory",
  "conciergeHistory",
] as const;

describe.each(sharedCollections)("%s", (col) => {
  const payload = { title: "X" };
  const docPath = `households/${HH}/${col}/doc1`;

  test("member can write and read", async () => {
    await assertSucceeds(setDoc(doc(member(U1), docPath), payload));
    await assertSucceeds(getDoc(doc(member(U2), docPath)));
  });

  test("stranger cannot write or read", async () => {
    await assertFails(setDoc(doc(member(U3), docPath), payload));
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), docPath), payload);
    });
    await assertFails(getDoc(doc(member(U3), docPath)));
    await assertFails(getDoc(doc(stranger(), docPath)));
  });
});

// ---------------------------------------------------------------------------
// watchEntries episodes sub-collection (nested)
// ---------------------------------------------------------------------------
describe("watchEntries/{entry}/episodes/{ep}", () => {
  const epPath = `households/${HH}/watchEntries/tv:1/episodes/1_1`;

  test("member can write, stranger cannot", async () => {
    await assertSucceeds(setDoc(doc(member(U1), epPath), { number: 1 }));
    await assertFails(setDoc(doc(member(U3), epPath), { number: 1 }));
  });

  test("member can read, stranger cannot", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), epPath), { number: 1 });
    });
    await assertSucceeds(getDoc(doc(member(U1), epPath)));
    await assertFails(getDoc(doc(member(U3), epPath)));
  });
});

// ---------------------------------------------------------------------------
// Single-doc household resources (even-segment path regression guard)
// ---------------------------------------------------------------------------
describe.each(["tasteProfile", "gamification"])("%s/default", (name) => {
  const path = `households/${HH}/${name}/default`;

  test("member can read and write", async () => {
    await assertSucceeds(setDoc(doc(member(U1), path), { foo: "bar" }));
    await assertSucceeds(getDoc(doc(member(U2), path)));
  });

  test("stranger cannot read or write", async () => {
    await assertFails(setDoc(doc(member(U3), path), { foo: "x" }));
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), path), { foo: "x" });
    });
    await assertFails(getDoc(doc(member(U3), path)));
  });
});

// ---------------------------------------------------------------------------
// /users/{uid}
// ---------------------------------------------------------------------------
describe("users/{uid}", () => {
  test("user can read and write their own pointer doc", async () => {
    await assertSucceeds(
      setDoc(doc(member(U1), `users/${U1}`), { householdId: HH }),
    );
    await assertSucceeds(getDoc(doc(member(U1), `users/${U1}`)));
  });

  test("user cannot read or write another user's pointer", async () => {
    await assertFails(
      setDoc(doc(member(U1), `users/${U2}`), { householdId: "evil" }),
    );
    await assertFails(getDoc(doc(member(U1), `users/${U2}`)));
  });

  test("unauth'd cannot touch user pointer docs", async () => {
    await assertFails(getDoc(doc(stranger(), `users/${U1}`)));
    await assertFails(setDoc(doc(stranger(), `users/x`), { a: 1 }));
  });
});

// ---------------------------------------------------------------------------
// /invites/{token}
// ---------------------------------------------------------------------------
describe("invites/{token}", () => {
  test("any authed user can read invites (public lookup)", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), "invites/xyz"), { householdId: HH });
    });
    await assertSucceeds(getDoc(doc(member(U3), "invites/xyz")));
  });

  test("any authed user can create an invite", async () => {
    await assertSucceeds(
      setDoc(doc(member(U1), "invites/new-token"), { householdId: HH }),
    );
  });

  test("unauth'd cannot read or create", async () => {
    await assertFails(getDoc(doc(stranger(), "invites/xyz")));
    await assertFails(
      setDoc(doc(stranger(), "invites/new-token"), { householdId: HH }),
    );
  });

  test("updates and deletes are forbidden for everyone", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), "invites/xyz"), { householdId: HH });
    });
    await assertFails(
      updateDoc(doc(member(U1), "invites/xyz"), { householdId: "evil" }),
    );
    await assertFails(deleteDoc(doc(member(U1), "invites/xyz")));
  });
});

// ---------------------------------------------------------------------------
// /redditMentions/{id}
// ---------------------------------------------------------------------------
describe("redditMentions/{id}", () => {
  test("authed user can read (CF writes these)", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), "redditMentions/tt1"), {
        title: "X",
      });
    });
    await assertSucceeds(getDoc(doc(member(U1), "redditMentions/tt1")));
  });

  test("unauth'd cannot read", async () => {
    await assertFails(getDoc(doc(stranger(), "redditMentions/tt1")));
  });

  test("nobody (even authed) can write — CF admin SDK only", async () => {
    await assertFails(
      setDoc(doc(member(U1), "redditMentions/evil"), { title: "bad" }),
    );
  });
});

// ---------------------------------------------------------------------------
// Server-only paths
// ---------------------------------------------------------------------------
describe("server-only paths", () => {
  test("/sync/** denies client access entirely", async () => {
    await assertFails(setDoc(doc(member(U1), "sync/a/b/c"), { x: 1 }));
    await assertFails(getDoc(doc(member(U1), "sync/a/b/c")));
  });

  test("/_rate_limits/** denies client access entirely", async () => {
    await assertFails(
      setDoc(doc(member(U1), "_rate_limits/abc"), { count: 1 }),
    );
    await assertFails(getDoc(doc(member(U1), "_rate_limits/abc")));
  });
});
