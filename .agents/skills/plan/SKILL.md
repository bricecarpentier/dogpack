---
name: plan
description: Manage the implementation plan. Log new plan entries, update status, and keep <REPOSITORY_OR_WORKTREE_ROOT>/plan/README.md in sync with individual plan markdown files. Load this skill whenever the user asks to plan work, log a bug/feature, or update plan status.
---

# Plan Skill

## Overview

The plan lives in `<REPOSITORY_OR_WORKTREE_ROOT>/plan/`. Each unit of work has:
- A numbered markdown file: `<REPOSITORY_OR_WORKTREE_ROOT>/plan/NN-name.md`
- A row in the index: `<REPOSITORY_OR_WORKTREE_ROOT>/plan/README.md`

Both must always stay in sync.

## Index format

`<REPOSITORY_OR_WORKTREE_ROOT>/plan/README.md` is a markdown table:

```markdown
| # | Kind | Unit | Status | Depends on |
|---|------|------|--------|------------|
| NN | feature | Short Title | not started | MM |
```

### Columns

| Column | Values | Notes |
|--------|--------|-------|
| # | `01`, `02`, ... | Zero-padded, increments from the last row |
| Kind | `feature`, `bug` | Ask the user if unclear |
| Unit | Free text | Short descriptive title |
| Status | `not started`, `in progress`, `done` | |
| Depends on | `—`, `08`, `06, 07` | Plan numbers this depends on |

## Plan file template

`<REPOSITORY_OR_WORKTREE_ROOT>/plan/NN-name.md`:

```markdown
# NN — Short Title

## Status: not started

## Depends on
MM (Short Title of Dependency)

## Problem
What is wrong or missing. Be specific — reference file names, function names,
error messages.

## Scope
One-line summary of what will be done.

## Files
| File | Action |
|------|--------|
| `path/to/file` | Modify / Create / Delete — one-line description |

## Design
<!-- Detailed design goes here. Sections vary by plan. -->

## Acceptance criteria
- [ ] Criterion 1
- [ ] Criterion 2
```

## Operations

### Log a new plan entry

1. Read `<REPOSITORY_OR_WORKTREE_ROOT>/plan/README.md` to find the last plan number.
2. Determine the next number (zero-padded).
3. If the kind (feature/bug) is unclear, ask the user.
4. Gather from the user: title, problem description, scope, affected files.
5. Create `<REPOSITORY_OR_WORKTREE_ROOT>/plan/NN-slug.md` from the template above, filling in all sections.
6. Append a row to `<REPOSITORY_OR_WORKTREE_ROOT>/plan/README.md` with status `not started`.
7. Both files must be committed together (see Committing below).

### Update plan status

When the user says to mark a plan as `in progress` or `done`:

1. Update the `## Status:` line in `<REPOSITORY_OR_WORKTREE_ROOT>/plan/NN-name.md`.
2. Update the matching row in `<REPOSITORY_OR_WORKTREE_ROOT>/plan/README.md`.
3. If status is `done`, check all acceptance criteria boxes in the plan file.
4. Both files must be committed together.

### Add implementation details

When the user wants to add a design, migration checklist, or execution plan to an existing plan file:

1. Read the current plan file.
2. Append the new section(s) at the bottom.
3. Commit the change.

## Committing

Always commit both the plan file and `README.md` together in a single commit:

```
docs(plan): <verb> <short description> (NN)
```

Where `<verb>` is one of: `add`, `update`, `start`, `complete`.

Examples:
- `docs(plan): add ArgumentParser refactor (10)`
- `docs(plan): start streaming display (09)`
- `docs(plan): complete CLI test client (08)`

Follow the git-commit skill for trailers and formatting.

## Rules

- Never modify a plan file without also updating `README.md`, and vice versa.
- Plan numbers never change once assigned. If a plan is cancelled, mark it in the Status column — do not renumber.
- The slug in the filename uses kebab-case (e.g. `10-argument-parser.md`).
- Keep the Unit title in README.md short (under 50 chars).
