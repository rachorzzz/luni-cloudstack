#!/usr/bin/env bash
# Opens a tmux session with one window per host from the inventory.

SESSION="cloudstack"

HOSTS=(
  "hp-01:100.93.75.19"
  "hp-02:100.124.102.103"
  "main-hp:100.68.102.106"
  "main-1:100.117.99.12"
  "main-2:100.99.132.72"
)

SSH_OPTS="-i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no"
SSH_USER="root"

# Kill existing session if it exists
tmux kill-session -t "$SESSION" 2>/dev/null

for entry in "${HOSTS[@]}"; do
  name="${entry%%:*}"
  host="${entry##*:}"

  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION" -n "$name"
    tmux send-keys -t "$SESSION:$name" "ssh $SSH_OPTS ${SSH_USER}@${host}" Enter
  else
    tmux new-window -t "$SESSION" -n "$name"
    tmux send-keys -t "$SESSION:$name" "ssh $SSH_OPTS ${SSH_USER}@${host}" Enter
  fi
done

# Select the first window
tmux select-window -t "$SESSION:hp-01"
tmux attach-session -t "$SESSION"
