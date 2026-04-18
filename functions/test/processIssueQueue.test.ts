import { processIssueQueue } from "../src/processIssueQueue";

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
    }),
  };
});

jest.mock("firebase-functions/logger", () => ({
  info: jest.fn(),
  error: jest.fn(),
  warn: jest.fn(),
}));

function makeDoc(overrides: Partial<{
  id: string;
  items: any[];
  submitter: string;
  dispatchAtMs: number;
}> = {}) {
  const id = overrides.id ?? "batch1";
  const update = jest.fn().mockResolvedValue(undefined);
  return {
    id,
    ref: { update, id },
    data: () => ({
      uid: "u1",
      submitter: overrides.submitter ?? "Zach",
      status: "pending",
      items: overrides.items ?? [
        { title: "Bug", description: "it broke", submittedAt: { toMillis: () => 1700000000000 } },
      ],
      dispatchAt: { toMillis: () => overrides.dispatchAtMs ?? 0 },
    }),
    update,
  };
}

function makeDb(docs: any[]) {
  return {
    collectionGroup: (_name: string) => ({
      where: () => ({
        where: () => ({
          get: jest.fn().mockResolvedValue({ docs, size: docs.length }),
        }),
      }),
    }),
  } as any;
}

beforeEach(() => {
  FAKE_NOW = 2_000_000_000_000;
  (globalThis as any).__FAKE_NOW = FAKE_NOW;
});

describe("processIssueQueue", () => {
  test("dispatches each due batch and marks it dispatched", async () => {
    const doc = makeDoc({ id: "b1" });
    const poster = jest
      .fn()
      .mockResolvedValue({ number: 42, url: "https://example/42" });

    const result = await processIssueQueue(poster, makeDb([doc]));

    expect(result).toEqual({ scanned: 1, dispatched: 1, errors: 0 });
    expect(poster).toHaveBeenCalledTimes(1);
    const call = poster.mock.calls[0][0];
    expect(call.title).toBe("Bug");
    expect(call.body).toContain("it broke");
    expect(call.labels).toEqual(["from-app"]);
    expect(doc.ref.update).toHaveBeenCalledWith(
      expect.objectContaining({
        status: "dispatched",
        dispatchResult: { issueNumber: 42, url: "https://example/42" },
      }),
    );
  });

  test("bundles multi-item batch into one issue", async () => {
    const doc = makeDoc({
      id: "b2",
      items: [
        { title: "First", description: "alpha", submittedAt: { toMillis: () => 0 } },
        { title: "Second", description: "beta", submittedAt: { toMillis: () => 0 } },
      ],
    });
    const poster = jest.fn().mockResolvedValue({ number: 7, url: "u" });

    await processIssueQueue(poster, makeDb([doc]));

    const { title, body } = poster.mock.calls[0][0];
    expect(title).toBe("First (+1 more)");
    expect(body).toContain("### 1. First");
    expect(body).toContain("### 2. Second");
  });

  test("backs off dispatchAt on GitHub error instead of marking dispatched", async () => {
    const doc = makeDoc({ id: "b3" });
    const poster = jest.fn().mockRejectedValue(new Error("rate limit"));

    const result = await processIssueQueue(poster, makeDb([doc]));

    expect(result).toEqual({ scanned: 1, dispatched: 0, errors: 1 });
    expect(doc.ref.update).toHaveBeenCalledWith(
      expect.objectContaining({ lastError: "rate limit" }),
    );
    expect(doc.ref.update.mock.calls[0][0].status).toBeUndefined();
  });

  test("empty queue is a no-op", async () => {
    const poster = jest.fn();
    const result = await processIssueQueue(poster, makeDb([]));
    expect(result).toEqual({ scanned: 0, dispatched: 0, errors: 0 });
    expect(poster).not.toHaveBeenCalled();
  });

  test("coerces malformed items into safe strings", async () => {
    const doc = makeDoc({
      id: "b4",
      items: [{ title: undefined, description: null, submittedAt: undefined }] as any,
    });
    const poster = jest.fn().mockResolvedValue({ number: 1, url: "u" });

    await processIssueQueue(poster, makeDb([doc]));

    expect(poster).toHaveBeenCalled();
    expect(poster.mock.calls[0][0].body).toContain("_(no description)_");
  });

  test("mixed success + failure in a single drain tick", async () => {
    const ok = makeDoc({ id: "ok" });
    const bad = makeDoc({ id: "bad" });
    const poster = jest
      .fn()
      .mockResolvedValueOnce({ number: 1, url: "u1" })
      .mockRejectedValueOnce(new Error("500"));

    const result = await processIssueQueue(poster, makeDb([ok, bad]));

    expect(result).toEqual({ scanned: 2, dispatched: 1, errors: 1 });
    expect(ok.ref.update).toHaveBeenCalledWith(
      expect.objectContaining({ status: "dispatched" }),
    );
    expect(bad.ref.update).toHaveBeenCalledWith(
      expect.objectContaining({ lastError: "500" }),
    );
  });

  test("batch with missing items array still dispatches (as empty placeholder)", async () => {
    const doc = makeDoc({ id: "nomitems" });
    // Force data() to return without items key.
    doc.data = (() => ({
      uid: "u1",
      submitter: "x",
      status: "pending",
      dispatchAt: { toMillis: () => 0 },
    })) as any;
    const poster = jest.fn().mockResolvedValue({ number: 9, url: "u" });

    const result = await processIssueQueue(poster, makeDb([doc]));

    expect(result.dispatched).toBe(1);
    expect(poster.mock.calls[0][0].body).toContain("empty batch");
  });

  test("falls back to uid when submitter field is missing", async () => {
    const doc = makeDoc({ id: "nousername" });
    doc.data = (() => ({
      uid: "user-uid-abc",
      status: "pending",
      items: [{ title: "x", description: "y", submittedAt: { toMillis: () => 0 } }],
      dispatchAt: { toMillis: () => 0 },
    })) as any;
    const poster = jest.fn().mockResolvedValue({ number: 1, url: "u" });

    await processIssueQueue(poster, makeDb([doc]));

    expect(poster.mock.calls[0][0].body).toContain("**user-uid-abc**");
  });
});
