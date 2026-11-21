---
name: verify-everboard-change
description: Checklist to run before calling any Everboard change done - tests, leak check, Core/UI split, generic-app review, docs, and a look at the UI in demo mode. Use before committing, before saying a feature is finished, or when asked to verify or review a change in this repo.
---

# Verify an Everboard change

Everboard is an open-source app for anyone (see `AGENTS.md`). A change is done when all of these hold. Run them, don't assume.

## 1. It builds and the tests pass

```bash
make build
make test
```

New logic in `EverboardCore` has tests in `Tests/EverboardCoreTests` that cover the main path and the edge cases you thought about while writing it. Parsing of another tool's output (hook payloads, CLI JSON, API responses) has fixtures in the test file, with placeholder data.

## 2. Nothing personal or organisation-specific

```bash
make leakcheck
scripts/check-core.sh
```

Then read your diff (`git diff --stat`, then the files) and ask, for every new string, default and branch:

- Would this make sense for someone at a different company with different tools? If it only fits one setup, make it a setting or remove it.
- Are hosts, names, paths, project keys and emails coming from config or secrets, never from code?
- Are tests, demo data and docs using placeholders (`example.com`, `acme`, `PROJ-123`)?
- Does anything write outside Everboard's own folders? If so, only on an explicit user action, with a way to undo it.
- Is a new feature off, or harmless, until the user sets it up, with an empty state that says what it needs?

## 3. Config stays compatible

A new `AppConfig` field has a default, a `CodingKeys` case and a lenient line in `init(from:)`. An old `config.json` without the field still loads (the existing tests in `ParsingTests` show how to check).

## 4. The UI looks right

For any change under `Sources/EverboardMac/Views`:

```bash
make app
build/Everboard.app/Contents/MacOS/Everboard --demo --snapshot /tmp/evb-shots --appearance light
build/Everboard.app/Contents/MacOS/Everboard --demo --snapshot /tmp/evb-shots-dark --appearance dark
```

Open the PNGs for the screens you touched and look at them in both modes. If the page is new, add it to `DemoData.snapshot` and the `--resize-test` list, and give it demo data in `DemoData`.

## 5. Docs match

Update `docs/` (and the README feature list if it's user-visible) for new behaviour, settings, files or commands. `docs/extending.md` if you added an extension point.

## 6. Report

Say what you ran and what it showed, including anything you could not check (for example a flow that needs a real account).
