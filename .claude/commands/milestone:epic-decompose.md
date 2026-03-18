# /epic-decompose

**Purpose:** Decompose epic issues into structured child issues using AI-powered analysis.

**Usage:**
```
/epic-decompose <epic_number>              # Decompose epic with confirmation
/epic-decompose <epic_number> --dry-run    # Preview decomposition without creating issues
/epic-decompose <epic_number> --interactive # Review each phase before creating
```

**Examples:**
```
/epic-decompose 580
/epic-decompose 580 --dry-run
/epic-decompose 580 --interactive
```

## How It Works

This skill wraps the `epic-decompose.sh` script to provide a user-friendly interface for decomposing epic issues into structured child issues.

### Process Flow

1. **Fetch Epic Data**: Retrieves epic issue details from GitHub
2. **AI Analysis**: Uses Claude to analyze and decompose the epic into logical phases
3. **Review**: Shows the decomposition plan (all modes show the plan)
4. **Create Issues**: Creates child issues on GitHub (unless `--dry-run`)
5. **Update Epic**: Links all child issues to the parent epic

### Modes

- **Default**: Show plan, confirm once, create all issues
- **--dry-run**: Show plan only, don't create any issues
- **--interactive**: Show plan, confirm each phase individually before creating

## Instructions

You are helping the user decompose an epic issue into structured child issues.

### Step 1: Parse Arguments

Extract the epic number and mode from the user's command:
- Epic number (required): First numeric argument
- Mode flags (optional): `--dry-run` or `--interactive`

### Step 2: Validate Prerequisites

Before proceeding, verify:
1. The `scripts/epic-decompose.sh` script exists
2. Required environment variables are set:
   - `GITHUB_TOKEN` or `GH_TOKEN`
   - Repository is a GitHub repository

If prerequisites are missing, inform the user and provide setup instructions.

### Step 3: Execute the Script

Run the decomposition script with appropriate flags:

```bash
# Default mode
./scripts/epic-decompose.sh <epic_number>

# Dry-run mode
./scripts/epic-decompose.sh <epic_number> --dry-run

# Interactive mode
./scripts/epic-decompose.sh <epic_number> --interactive
```

### Step 4: Handle Interactive Mode

If `--interactive` mode is specified:
1. The script will display each phase's details
2. For each phase, ask the user: "Create this phase? (y/n)"
3. Pass the user's response to the script
4. Continue until all phases are processed or user declines

### Step 5: Report Results

After execution, summarize:
- Number of child issues created (or would be created in dry-run)
- Links to created issues
- Any errors or warnings encountered
- Reminder to check the epic issue for linked children

### Example Output Format

```
🔍 Analyzing epic #580...

📋 Decomposition Plan:
  Phase 1: Foundation Setup (3 tasks)
  Phase 2: Core Implementation (5 tasks)
  Phase 3: Testing & Documentation (2 tasks)

Total: 10 child issues across 3 phases

✅ Creating issues...
  ✓ Created #601: Foundation Setup - Initialize repository structure
  ✓ Created #602: Foundation Setup - Configure build system
  ✓ Created #603: Foundation Setup - Setup CI/CD pipeline
  ...

🎉 Successfully created 10 child issues for epic #580
View epic: https://github.com/owner/repo/issues/580
```

## Error Handling

Handle common errors gracefully:

1. **Epic not found**: Verify the epic number exists in the repository
2. **Permission denied**: Check GitHub token has appropriate permissions
3. **Script not found**: Inform user that `epic-decompose.sh` must be implemented first
4. **Network errors**: Suggest checking internet connection and GitHub API status

## Notes

- The decomposition uses AI (Claude) to intelligently break down epic requirements
- Child issues are created with appropriate labels and milestone links
- All child issues are automatically linked back to the parent epic
- The script preserves the epic's context and requirements in child issues
- In dry-run mode, you can review the plan multiple times without side effects

## Related

- Epic decomposition concept: Issue #580
- Decomposition script: `scripts/epic-decompose.sh`
