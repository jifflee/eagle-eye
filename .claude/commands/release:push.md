---
description: Push current branch to remote with state verification and auto-fix
argument-hint: "[--force] [--dry-run]"
---

# Push

Standardized git push with pre-flight state verification. Eliminates common friction from wrong git root, missing remotes, email privacy errors, and ambiguous push/merge/PR intent.

## Usage

```bash
/release:push              # Verify state and push
/release:push --dry-run    # Show what would be pushed without pushing
/release:push --force      # Force push (with confirmation)
```

## Steps

### 1. Gather State

Run the data script to collect git state:

```bash
STATE=$(./scripts/release:push-data.sh)
```

If the script exits non-zero, report the error and stop.

### 2. Pre-flight Checks

From the JSON state, verify:

1. **Git root** — Confirm we're in a git repository
2. **Branch** — Show current branch name (warn if detached HEAD)
3. **Remote** — Confirm remote exists and show URL
4. **Working tree** — Warn if staged/unstaged changes exist (uncommitted work won't be pushed)
5. **Unpushed commits** — Show count and commit summaries

If there are no unpushed commits and the remote branch exists, report "Already up to date" and stop.

### 3. Email Privacy Check

If `email_is_noreply` is false and the remote URL contains `github.com`:

```bash
# Auto-fix GitHub email privacy
git config user.email "${gh_id}+${gh_username}@users.noreply.github.com"
```

Report the fix to the user. This prevents GitHub push rejections from email privacy settings.

### 4. Push

If `remote_branch_exists` is false, push with `-u` to set upstream:

```bash
git push -u ${remote} ${branch}
```

Otherwise, standard push:

```bash
git push ${remote} ${branch}
```

If `--force` flag is provided, ask for user confirmation first, then:

```bash
git push --force-with-lease ${remote} ${branch}
```

### 5. Report

Output a clear summary:

```
## Push Complete

**Branch:** ${branch}
**Remote:** ${remote_url}
**Commits pushed:** ${unpushed_count}

| Hash | Subject |
|------|---------|
| abc1234 | feat: Add new feature |
| def5678 | fix: Resolve edge case |
```

If the push set up a new upstream tracking branch, note that.

## Error Handling

| Error | Auto-Fix |
|-------|----------|
| Email privacy rejection | Switch to noreply email, retry push |
| No remote configured | Show `git remote add origin <url>` |
| Detached HEAD | Warn user, suggest `git checkout -b <name>` |
| Diverged branches | Show `git pull --rebase` suggestion |
| Force push to main/dev | Block and warn (protected branches) |

## Notes

- WRITE operation — pushes to remote
- Does NOT create PRs (use `/pr-to-qa` or `gh pr create` for that)
- Does NOT merge branches
- Force push uses `--force-with-lease` (safer than `--force`)
- Protected branch check: blocks force push to main, master, dev, qa
