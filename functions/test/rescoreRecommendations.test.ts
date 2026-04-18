import { selectDirtyHouseholds } from "../src/rescoreRecommendations";

type Ts = { toMillis: () => number };
const ts = (ms: number): Ts => ({ toMillis: () => ms });

describe("selectDirtyHouseholds", () => {
  test("returns households where dirty_since > last_scored_at", () => {
    const out = selectDirtyHouseholds([
      {
        household_id: "hh1",
        dirty_since: ts(200) as unknown as FirebaseFirestore.Timestamp,
        last_scored_at: ts(100) as unknown as FirebaseFirestore.Timestamp,
      },
      {
        household_id: "hh2",
        dirty_since: ts(100) as unknown as FirebaseFirestore.Timestamp,
        last_scored_at: ts(200) as unknown as FirebaseFirestore.Timestamp,
      },
    ]);
    expect(out).toEqual(["hh1"]);
  });

  test("missing last_scored_at means household is dirty", () => {
    const out = selectDirtyHouseholds([
      {
        household_id: "hh1",
        dirty_since: ts(100) as unknown as FirebaseFirestore.Timestamp,
      },
    ]);
    expect(out).toEqual(["hh1"]);
  });

  test("equal timestamps are not dirty (strict >)", () => {
    const out = selectDirtyHouseholds([
      {
        household_id: "hh1",
        dirty_since: ts(100) as unknown as FirebaseFirestore.Timestamp,
        last_scored_at: ts(100) as unknown as FirebaseFirestore.Timestamp,
      },
    ]);
    expect(out).toEqual([]);
  });

  test("returns all dirty households in input order", () => {
    const out = selectDirtyHouseholds([
      {
        household_id: "hh1",
        dirty_since: ts(200) as unknown as FirebaseFirestore.Timestamp,
        last_scored_at: ts(100) as unknown as FirebaseFirestore.Timestamp,
      },
      {
        household_id: "hh2",
        dirty_since: ts(300) as unknown as FirebaseFirestore.Timestamp,
      },
      {
        household_id: "hh3",
        dirty_since: ts(50) as unknown as FirebaseFirestore.Timestamp,
        last_scored_at: ts(500) as unknown as FirebaseFirestore.Timestamp,
      },
    ]);
    expect(out).toEqual(["hh1", "hh2"]);
  });

  test("empty input → empty output", () => {
    expect(selectDirtyHouseholds([])).toEqual([]);
  });

  test("missing dirty_since (shouldn't happen — defensive) → not dirty", () => {
    const out = selectDirtyHouseholds([
      {
        household_id: "hh1",
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        dirty_since: undefined as any,
        last_scored_at: ts(100) as unknown as FirebaseFirestore.Timestamp,
      },
    ]);
    expect(out).toEqual([]);
  });
});
