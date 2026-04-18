import { enqueueIssue } from "../src/submitIssue";

let FAKE_NOW = 0;

jest.mock("firebase-admin", () => {
  class FakeTimestamp {
    constructor(public ms: number) {}
    toMillis() { return this.ms; }
    static now() { return new FakeTimestamp((globalThis as any).__FAKE_NOW); }
    static fromMillis(ms: number) { return new FakeTimestamp(ms); }
  }
  return {
    firestore: Object.assign(() => ({}), {
      Timestamp: FakeTimestamp,
      FieldValue: { arrayUnion: (...args: any[]) => ({ __arrayUnion: args }) },
    }),
  };
});

function makeDb(opts: {
  pendingDocs?: any[];
  autoGenId?: string;
} = {}) {
  const set = jest.fn();
  const update = jest.fn();

  // "runTransaction" just invokes its callback with a tx stub.
  const runTransaction = jest
    .fn()
    .mockImplementation(async (fn: (tx: any) => Promise<any>) => {
      const tx = {
        get: jest.fn().mockImplementation(async (ref: any) => {
          // Echo back the matching pending doc's data.
          const match = (opts.pendingDocs ?? []).find((d) => d.ref === ref);
          return {
            exists: !!match,
            data: () => match?.data(),
          };
        }),
        set,
        update,
      };
      return fn(tx);
    });

  const newDocRef = { id: opts.autoGenId ?? "newBatch" };

  const collection = jest.fn().mockImplementation((_path: string) => ({
    where: () => ({
      where: () => ({
        limit: () => ({
          get: jest.fn().mockResolvedValue({
            empty: (opts.pendingDocs ?? []).length === 0,
            docs: opts.pendingDocs ?? [],
          }),
        }),
      }),
    }),
    doc: () => newDocRef,
  }));

  return {
    collection,
    runTransaction,
    // Exposed so assertions can reach into the mocks.
    _set: set,
    _update: update,
  } as any;
}

beforeEach(() => {
  FAKE_NOW = 2_000_000_000_000;
  (globalThis as any).__FAKE_NOW = FAKE_NOW;
});

describe("enqueueIssue", () => {
  const baseInput = {
    householdId: "h1",
    uid: "u1",
    submitter: "Zach",
    title: "Bug",
    description: "broke",
  };

  test("creates a new batch when no pending batch exists", async () => {
    const db = makeDb({ pendingDocs: [], autoGenId: "b-new" });

    const res = await enqueueIssue(db, baseInput);

    expect(res.appended).toBe(false);
    expect(res.itemCount).toBe(1);
    expect(res.batchId).toBe("b-new");
    expect(db._set).toHaveBeenCalledTimes(1);
    expect(db._update).not.toHaveBeenCalled();
    const setPayload = db._set.mock.calls[0][1];
    expect(setPayload.uid).toBe("u1");
    expect(setPayload.submitter).toBe("Zach");
    expect(setPayload.items).toHaveLength(1);
    expect(setPayload.items[0].title).toBe("Bug");
    expect(setPayload.status).toBe("pending");
  });

  test("appends to existing pending batch and resets dispatchAt", async () => {
    const existingRef = { id: "b-existing" };
    const existingDoc = {
      ref: existingRef,
      data: () => ({
        uid: "u1",
        status: "pending",
        items: [{ title: "first", description: "", submittedAt: {} }],
      }),
    };
    const db = makeDb({ pendingDocs: [existingDoc] });

    const res = await enqueueIssue(db, baseInput);

    expect(res.appended).toBe(true);
    expect(res.itemCount).toBe(2);
    expect(res.batchId).toBe("b-existing");
    expect(db._set).not.toHaveBeenCalled();
    expect(db._update).toHaveBeenCalledTimes(1);
    const updatePayload = db._update.mock.calls[0][1];
    expect(updatePayload.items).toEqual({ __arrayUnion: [expect.any(Object)] });
    expect(updatePayload.dispatchAt.toMillis()).toBe(
      FAKE_NOW + 10 * 60 * 1000,
    );
  });

  test("dispatchAtMs is now + 10 minutes", async () => {
    const db = makeDb({ pendingDocs: [] });
    const res = await enqueueIssue(db, baseInput);
    expect(res.dispatchAtMs).toBe(FAKE_NOW + 10 * 60 * 1000);
  });

  test("falls back to creating when the pending doc has mutated status mid-flight", async () => {
    // Query returned a doc, but by the time tx.get runs, status is no
    // longer 'pending' — we must NOT append to a dispatched/cancelled batch.
    const staleRef = { id: "b-stale" };
    const staleDoc = {
      ref: staleRef,
      data: () => ({ uid: "u1", status: "dispatched", items: [{}] }),
    };
    const db = makeDb({ pendingDocs: [staleDoc], autoGenId: "b-fresh" });

    const res = await enqueueIssue(db, baseInput);

    expect(res.appended).toBe(false);
    expect(res.batchId).toBe("b-fresh");
    expect(db._set).toHaveBeenCalledTimes(1);
    expect(db._update).not.toHaveBeenCalled();
  });

  test("item count increments from existing batch length", async () => {
    const existingRef = { id: "b-long" };
    const threeItems = [
      { title: "a" },
      { title: "b" },
      { title: "c" },
    ];
    const existingDoc = {
      ref: existingRef,
      data: () => ({ uid: "u1", status: "pending", items: threeItems }),
    };
    const db = makeDb({ pendingDocs: [existingDoc] });

    const res = await enqueueIssue(db, baseInput);

    expect(res.itemCount).toBe(4);
  });

  test("creates fresh batch when existing doc has no items array", async () => {
    // Guards against undefined.items.length blowing up.
    const weirdDoc = {
      ref: { id: "weird" },
      data: () => ({ uid: "u1", status: "pending" }),
    };
    const db = makeDb({ pendingDocs: [weirdDoc] });

    const res = await enqueueIssue(db, baseInput);

    expect(res.appended).toBe(true);
    expect(res.itemCount).toBe(1);
  });
});
