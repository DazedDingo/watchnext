#!/usr/bin/env python3
"""
Turns git commits into human-readable release notes.

Invoked from .github/workflows/release.yml. Reads `git log` between the
previous tag and HEAD, converts conventional-commit subjects into plain
bullets, and drops internal-only types (docs, chore, test, ci, build,
refactor) so the release page shows what actually changed *for users*.

Per-commit overrides:
  If a commit body contains `Release-note: <text>`, that text replaces
  the auto-translated bullet. Use this when the commit message itself is
  too jargon-heavy for a user-facing changelog.

  If a commit body contains `Release-skip:` (any value), the commit is
  omitted from the notes. Use for mid-stream fixes that rolled into a
  bigger feature.
"""

import re
import subprocess
import sys

# Types we drop outright — these are internal concerns, not user-facing.
SKIP_TYPES = {"docs", "chore", "test", "ci", "build", "style"}

# Types whose messages get a friendly prefix.
PREFIXES = {
    "fix": "**Fixed:** ",
    "perf": "**Faster:** ",
}

CONVENTIONAL_RE = re.compile(r"^(\w+)(?:\([^)]+\))?!?:\s*(.+)$")
RELEASE_NOTE_RE = re.compile(r"^Release-note:\s*(.+)$", re.IGNORECASE)
RELEASE_SKIP_RE = re.compile(r"^Release-skip:", re.IGNORECASE)


def previous_tag() -> str | None:
    """Closest tag before HEAD, or None on first-ever release."""
    try:
        out = subprocess.run(
            ["git", "describe", "--tags", "--abbrev=0", "HEAD^"],
            capture_output=True, text=True, check=True,
        )
        return out.stdout.strip() or None
    except subprocess.CalledProcessError:
        return None


def commits_since(prev: str | None) -> list[tuple[str, str]]:
    """List of (subject, body) pairs for commits between `prev` and HEAD."""
    rng = f"{prev}..HEAD" if prev else "HEAD"
    # Separator-driven format so multi-line bodies survive the shell hop.
    # SUBJ\x1f BODY \x1e next commit
    fmt = "%s%x1f%b%x1e"
    out = subprocess.run(
        ["git", "log", "--no-merges", f"--pretty=format:{fmt}", rng],
        capture_output=True, text=True, check=True,
    )
    commits = []
    for raw in out.stdout.split("\x1e"):
        raw = raw.strip()
        if not raw:
            continue
        if "\x1f" in raw:
            subject, body = raw.split("\x1f", 1)
        else:
            subject, body = raw, ""
        commits.append((subject.strip(), body.strip()))
    return commits


def humanize(msg: str) -> str:
    """Lightly clean up a commit message for a changelog bullet."""
    msg = msg.strip().rstrip(".")
    if msg and msg[0].islower():
        msg = msg[0].upper() + msg[1:]
    return msg


def commit_to_bullet(subject: str, body: str) -> str | None:
    """None ⇒ omit this commit from the changelog."""
    # Release-skip override: omit entirely.
    for line in body.splitlines():
        if RELEASE_SKIP_RE.match(line.strip()):
            return None

    # Release-note override: use the body-provided text verbatim.
    for line in body.splitlines():
        m = RELEASE_NOTE_RE.match(line.strip())
        if m:
            return f"- {m.group(1).strip()}"

    m = CONVENTIONAL_RE.match(subject)
    if not m:
        # Non-conventional subject — show it as-is, the author probably
        # wrote it plain-English already.
        return f"- {humanize(subject)}"

    ctype, msg = m.group(1).lower(), m.group(2)
    if ctype in SKIP_TYPES:
        return None
    prefix = PREFIXES.get(ctype, "")
    return f"- {prefix}{humanize(msg)}"


def main() -> int:
    prev = previous_tag()
    commits = commits_since(prev)
    bullets = []
    for subject, body in commits:
        bullet = commit_to_bullet(subject, body)
        if bullet:
            bullets.append(bullet)

    if not bullets:
        # Surface *something* so the release doesn't look empty. A silent
        # maintenance release is still a release.
        bullets.append("- Small maintenance release — no user-facing changes.")

    sys.stdout.write("\n".join(bullets) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
