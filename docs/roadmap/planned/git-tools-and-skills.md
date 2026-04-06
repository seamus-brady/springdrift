# Git Tools and Skills — Version Control Integration

**Status**: Planned
**Priority**: Medium — natural extension of coder agent
**Effort**: Medium (~300-500 lines)

## Problem

The agent has no git awareness beyond its own `.springdrift/` backup repo.
It cannot inspect, commit to, or reason about the project repository it
lives in. For a knowledge worker agent that writes code and manages
projects, this is a significant capability gap.

Common use cases:

- Review recent commits to understand what changed
- Create branches and commits for code the coder agent produces
- Check diff before committing (safety review)
- Read git log to understand project history and context
- Check git status to understand working tree state
- Create pull requests or merge requests (via forge APIs)

## Proposed Solution

### 1. Git Tools

New tool set in `tools/git.gleam`, available to the coder agent (and
potentially the cognitive loop for project awareness):

**Read-only tools** (low risk, minimal D' concern):
- `git_status` — working tree status (staged, unstaged, untracked)
- `git_log(n)` — recent N commits with messages, authors, dates
- `git_diff(ref?)` — diff of working tree or between refs
- `git_show(ref)` — show a specific commit
- `git_blame(file, lines?)` — blame for a file or line range

**Write tools** (higher risk, D' gated):
- `git_add(files)` — stage files
- `git_commit(message)` — commit staged changes
- `git_branch(name)` — create a branch
- `git_checkout(ref)` — switch branches
- `git_stash` / `git_stash_pop` — stash management

**Forge tools** (external-facing, strongest D' gating):
- `git_push(remote?, branch?)` — push to remote
- `create_pull_request(title, body, base, head)` — via GitHub/GitLab API

### 2. D' Safety

Git write operations are external-facing and potentially destructive.
Safety layers:

- **Deterministic rules**: block `git push --force`, `git reset --hard`,
  branch deletion on main/master
- **Agent override**: coder agent git tools get tighter D' thresholds
  (similar to comms agent)
- **Forge operations**: require D' evaluation with features for
  `credential_exposure`, `scope_appropriateness`, `destructive_operation`

Read-only git tools should be D'-exempt (same as `get_current_datetime`).

### 3. Git Skills

A `git-workflow` skill teaching the agent:

- When to branch vs commit directly
- Commit message conventions
- How to review diffs before committing
- When to ask the operator before pushing
- How to use git log for project context gathering

### 4. Project Awareness

The cognitive loop could use read-only git tools to build project context:

- Recent commits feed into the sensorium (what changed recently)
- Git status informs the Curator about uncommitted work
- Branch information helps the agent understand the development context

## Open Questions

- Should git tools execute in the sandbox container or on the host?
  Host is more useful (access to the real repo) but raises safety
  concerns. Sandbox is safer but can only work with cloned repos.
- Which forge API to support first? GitHub (gh CLI), GitLab, or abstract?
- Should the agent auto-commit its own code changes, or always ask?
- How to handle merge conflicts?
- Interaction with the `.springdrift/` backup repo — the agent should
  NOT be able to modify its own memory store via git tools
