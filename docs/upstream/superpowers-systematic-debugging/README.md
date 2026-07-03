# Upstream contribution: systematic-debugging += "reducing the trigger"

A proposed contribution to `obra/superpowers`, skill
`skills/systematic-debugging`. Distilled from the no-AVX2 startup-spin
investigation (see `../../RETROSPECTIVE.md`): the bug was gated by a
configuration (trusted project -> plugin -> a one-character payload), and
mechanical bisection of that chain would have localized it in a day, but the
skill only taught *additive* root-causing (instrument and trace), so the
investigation spent weeks profiling the mechanism instead.

## What this adds

The skill's Phase-1 techniques are all additive: add logging at component
boundaries, trace a bad value backward up the stack (`root-cause-tracing.md`).
Missing was the *subtractive* strategy - reduce the failing case toward a minimal
trigger (delta debugging / bisect the input and environment). This contribution
adds that as a first-class peer, plus a handful of general debugging principles
the investigation proved the hard way.

## Files

- **`reducing-the-trigger.md`** - NEW supporting-technique doc, a peer to
  `root-cause-tracing.md`. Drop into `skills/systematic-debugging/`.
- **`SKILL.md.patch`** - unified diff against `skills/systematic-debugging/SKILL.md`.
  Adds, in the skill's own voice and structure:
  - Phase 1.2 (Reproduce): intermittency-means-a-hidden-input; magnitude sanity check.
  - Phase 1.4 (Gather Evidence): validate the instrument before trusting it
    (especially null results).
  - Phase 1.5 (Trace Data Flow): inspect the DATA, not just the path.
  - Phase 1.6 (NEW: Reduce the Trigger): pointer to `reducing-the-trigger.md`.
  - Phase 3.2 (Test Minimally): A/B rigor for noisy/perf bugs (control must
    reproduce; interleave; replicate).
  - "No Root Cause" section: make the tool say WHY before accepting "environmental."
  - Red Flags + Common Rationalizations: three rows each for the toggle-is-noise,
    profile-before-reduce, and "environmental, ignore" traps.
  - Supporting Techniques list: link the new doc.

## Applying / verifying

```bash
# from a clone of obra/superpowers:
cp reducing-the-trigger.md skills/systematic-debugging/
git apply /path/to/SKILL.md.patch
```

The patch was verified to apply cleanly against superpowers 5.1.0's SKILL.md and
produce the intended result.

## Notes for the PR

- Both files are deliberately ASCII-only (no em-dashes/arrows in the added
  content). That is thematically apt - a wide character in a hook payload is the
  exact bug this technique found - and avoids re-triggering it for anyone reading
  the skill on an affected platform. The existing SKILL.md already contains `→`
  glyphs; the patch does not touch them.
- The worked example in `reducing-the-trigger.md` is genericized (no product,
  host, or vendor names) so it stands on its own.
