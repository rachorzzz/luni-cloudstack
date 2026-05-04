#!/usr/bin/env bash
# Opens a tmux session with one window per host from the inventory.

SESSION="cloudstack"

HOSTS=(
  "main-hp"
  "main-1"
  "main-2"
)

SSH_OPTS="-i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no"

# Kill existing session if it exists
tmux kill-session -t "$SESSION" 2>/dev/null

for name in "${HOSTS[@]}"; do
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n "$name"
    tmux send-keys -t "$SESSION:$name" "ssh $SSH_OPTS root@${name}" Enter
  else
    tmux new-window -t "$SESSION" -n "$name"
    tmux send-keys -t "$SESSION:$name" "ssh $SSH_OPTS root@${name}" Enter
  fi
done

# Select the first window
tmux select-window -t "$SESSION:hp-01"
tmux attach-session -t "$SESSION"
