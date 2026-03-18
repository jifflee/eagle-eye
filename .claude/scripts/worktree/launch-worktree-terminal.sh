#!/bin/bash
set -euo pipefail
# launch-worktree-terminal.sh
# Automatically launches a new terminal in a worktree directory
#
# Usage:
#   ./scripts/launch-worktree-terminal.sh /path/to/worktree [ISSUE_NUMBER]
#
# Supported environments (in priority order):
#   1. tmux - Creates new window (if in tmux session)
#   2. iTerm2 - Opens new tab (macOS)
#   3. Terminal.app - Opens new window (macOS)
#   4. Clipboard - Copies command to clipboard (fallback)
#
# Exit codes:
#   0 = Success (terminal launched or clipboard copied)
#   1 = No worktree path provided
#   2 = Worktree path does not exist

set -e

WORKTREE_PATH="${1:-}"
ISSUE_NUMBER="${2:-}"

if [ -z "$WORKTREE_PATH" ]; then
  echo "Error: Worktree path required" >&2
  exit 1
fi

if [ ! -d "$WORKTREE_PATH" ]; then
  echo "Error: Worktree path does not exist: $WORKTREE_PATH" >&2
  exit 2
fi

# Build the command to run in the new terminal
if [ -n "$ISSUE_NUMBER" ]; then
  LAUNCH_CMD="cd '$WORKTREE_PATH' && claude '/sprint-work --issue $ISSUE_NUMBER'"
else
  LAUNCH_CMD="cd '$WORKTREE_PATH' && claude"
fi

# Detect and use the best available method
launch_method=""

# Check if we're in tmux
is_in_tmux() {
  [ -n "$TMUX" ]
}

# Check if iTerm2 is available (macOS)
has_iterm2() {
  [ "$(uname)" = "Darwin" ] && osascript -e 'application "iTerm2" exists' 2>/dev/null | grep -q "true"
}

# Check if Terminal.app is available (macOS)
has_terminal_app() {
  [ "$(uname)" = "Darwin" ] && [ -d "/Applications/Utilities/Terminal.app" ]
}

# Check clipboard availability
has_clipboard() {
  command -v pbcopy >/dev/null 2>&1 || command -v xclip >/dev/null 2>&1
}

# Launch in tmux
launch_tmux() {
  echo "Launching in tmux new window..." >&2
  tmux new-window -c "$WORKTREE_PATH" -n "issue-$ISSUE_NUMBER" "bash -c '$LAUNCH_CMD; exec bash'"
  launch_method="tmux"
}

# Launch in iTerm2
launch_iterm2() {
  echo "Launching in iTerm2 new tab..." >&2
  osascript <<EOF
tell application "iTerm2"
  tell current window
    create tab with default profile
    tell current session
      write text "cd '$WORKTREE_PATH' && claude '/sprint-work --issue $ISSUE_NUMBER'"
    end tell
  end tell
end tell
EOF
  launch_method="iterm2"
}

# Launch in Terminal.app
launch_terminal_app() {
  echo "Launching in Terminal.app new window..." >&2
  osascript <<EOF
tell application "Terminal"
  do script "cd '$WORKTREE_PATH' && claude '/sprint-work --issue $ISSUE_NUMBER'"
  activate
end tell
EOF
  launch_method="terminal_app"
}

# Copy to clipboard
copy_to_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then
    echo "$LAUNCH_CMD" | pbcopy
    echo "Command copied to clipboard (pbcopy)" >&2
    launch_method="clipboard_pbcopy"
  elif command -v xclip >/dev/null 2>&1; then
    echo "$LAUNCH_CMD" | xclip -selection clipboard
    echo "Command copied to clipboard (xclip)" >&2
    launch_method="clipboard_xclip"
  else
    echo "No clipboard tool available" >&2
    launch_method="none"
    return 1
  fi
}

# Try launch methods in priority order
try_launch() {
  # 1. tmux (if in tmux session)
  if is_in_tmux; then
    if launch_tmux 2>/dev/null; then
      return 0
    fi
    echo "tmux launch failed, trying fallback..." >&2
  fi

  # 2. iTerm2 (macOS)
  if has_iterm2; then
    if launch_iterm2 2>/dev/null; then
      return 0
    fi
    echo "iTerm2 launch failed, trying fallback..." >&2
  fi

  # 3. Terminal.app (macOS)
  if has_terminal_app; then
    if launch_terminal_app 2>/dev/null; then
      return 0
    fi
    echo "Terminal.app launch failed, trying fallback..." >&2
  fi

  # 4. Clipboard fallback
  if has_clipboard; then
    if copy_to_clipboard; then
      return 0
    fi
  fi

  # No method worked
  return 1
}

# Execute launch
if try_launch; then
  # Output JSON result
  cat <<EOF
{"success": true, "method": "$launch_method", "worktree": "$WORKTREE_PATH", "issue": "$ISSUE_NUMBER"}
EOF
else
  # All methods failed - print manual instructions
  echo "" >&2
  echo "Auto-launch not available. Run manually:" >&2
  echo "" >&2
  echo "  $LAUNCH_CMD" >&2
  echo "" >&2
  cat <<EOF
{"success": false, "method": "manual", "worktree": "$WORKTREE_PATH", "issue": "$ISSUE_NUMBER", "command": "$LAUNCH_CMD"}
EOF
fi
