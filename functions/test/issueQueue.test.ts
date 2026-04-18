import {
  buildBundledBody,
  buildBundledTitle,
  validateInput,
  MAX_TITLE,
  MAX_BODY,
  DEBOUNCE_WINDOW_MS,
} from "../src/issueQueue";

describe("buildBundledTitle", () => {
  test("single item passes title through", () => {
    expect(buildBundledTitle([{ title: "Crash on startup" }])).toBe(
      "Crash on startup",
    );
  });

  test("multiple items → first title + '(+N more)'", () => {
    expect(
      buildBundledTitle([{ title: "A" }, { title: "B" }, { title: "C" }]),
    ).toBe("A (+2 more)");
  });

  test("empty → generic fallback", () => {
    expect(buildBundledTitle([])).toBe("Issue report");
  });
});

describe("buildBundledBody", () => {
  test("single item renders description + submitter footer", () => {
    const body = buildBundledBody(
      [{ title: "T", description: "does X", submittedAtMs: 1700000000000 }],
      "Zach",
    );
    expect(body).toContain("does X");
    expect(body).toContain("**Zach**");
    expect(body).not.toContain("### 1.");
  });

  test("single item with blank description → placeholder", () => {
    const body = buildBundledBody(
      [{ title: "T", description: "  ", submittedAtMs: 0 }],
      "user",
    );
    expect(body).toContain("_(no description)_");
  });

  test("multi-item body numbers sections + shows timestamp", () => {
    const body = buildBundledBody(
      [
        { title: "A", description: "alpha", submittedAtMs: 1700000000000 },
        { title: "B", description: "beta", submittedAtMs: 1700000600000 },
      ],
      "Zach",
    );
    expect(body).toContain("2 issues submitted from app by **Zach**");
    expect(body).toContain("### 1. A");
    expect(body).toContain("### 2. B");
    expect(body).toContain("alpha");
    expect(body).toContain("beta");
    expect(body).toMatch(/Submitted at 2023-\d\d-\d\dT/);
  });

  test("multi-item with blank description still renders placeholder", () => {
    const body = buildBundledBody(
      [
        { title: "A", description: "", submittedAtMs: 0 },
        { title: "B", description: "has text", submittedAtMs: 0 },
      ],
      "s",
    );
    expect(body).toContain("### 1. A");
    expect(body).toContain("_(no description)_");
    expect(body).toContain("has text");
  });

  test("empty items returns a placeholder without crashing", () => {
    expect(buildBundledBody([], "u")).toContain("empty batch");
  });
});

describe("validateInput", () => {
  test("accepts a normal title + description", () => {
    const v = validateInput("Hello", "World");
    expect(v.title).toBe("Hello");
    expect(v.description).toBe("World");
  });

  test("trims whitespace", () => {
    expect(validateInput("  a  ", "  b  ")).toEqual({
      title: "a",
      description: "b",
    });
  });

  test("rejects empty title", () => {
    expect(() => validateInput("", "desc")).toThrow(/Title must/);
    expect(() => validateInput("   ", "desc")).toThrow(/Title must/);
  });

  test("rejects over-length title", () => {
    expect(() => validateInput("x".repeat(MAX_TITLE + 1), "")).toThrow(
      /Title must/,
    );
  });

  test("rejects over-length description", () => {
    expect(() => validateInput("ok", "x".repeat(MAX_BODY + 1))).toThrow(
      /Description must/,
    );
  });

  test("coerces non-string inputs before checking", () => {
    expect(() => validateInput(undefined, "")).toThrow(/Title must/);
    expect(() => validateInput(null, "")).toThrow(/Title must/);
    expect(validateInput(42, "").title).toBe("42");
  });
});

describe("DEBOUNCE_WINDOW_MS", () => {
  test("is 10 minutes", () => {
    expect(DEBOUNCE_WINDOW_MS).toBe(10 * 60 * 1000);
  });
});
