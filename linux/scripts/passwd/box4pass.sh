#!/usr/bin/env bash
set -euo pipefail

HOST="${BOX4_HOST:-192.168.1.4}"
SSH_USER="${SSH_USER:-blueteam}"
PASSWORD_DIR="${PASSWORD_DIR:-./passwords_box4}"

echo "=== CDE Box 4 Password Changer ==="
echo "Target: $SSH_USER@$HOST"
echo

read -r -p "Linux username whose password should be changed: " TARGET_USER

if [[ -z "$TARGET_USER" ]]; then
  echo "Error: username cannot be empty."
  exit 1
fi

# Only permit normal Linux usernames.
if [[ ! "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "Error: invalid Linux username."
  exit 1
fi

# CDE-protected/out-of-scope accounts.
case "$TARGET_USER" in
root | scorebot | blackteam | red_scoring)
  echo "Error: refusing to modify protected/out-of-scope account: $TARGET_USER"
  exit 1
  ;;
esac

mkdir -p "$PASSWORD_DIR"
chmod 700 "$PASSWORD_DIR"

PASSWORD_FILE="$PASSWORD_DIR/$TARGET_USER"

if [[ -e "$PASSWORD_FILE" ]]; then
  echo "Warning: $PASSWORD_FILE already exists."
  read -r -p "Overwrite it with a new password? [y/N]: " ANSWER
  [[ "$ANSWER" =~ ^[Yy]$ ]] || exit 0
fi

# Generate a 24-character random password.
NEW_PASSWORD="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9_@%+=-' | head -c 24)"

if [[ ${#NEW_PASSWORD} -lt 20 ]]; then
  echo "Error: password generation failed."
  exit 1
fi

# Save the password locally.
printf '%s\n' "$NEW_PASSWORD" >"$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

echo
echo "Changing password for '$TARGET_USER' on Box 4..."
echo "You may be prompted for your SSH/sudo credentials."

# Send the username/password pair through SSH stdin.
# The remote command uses sudo when necessary.
ssh -tt "$SSH_USER@$HOST" \
  "sudo -S chpasswd" <<<"$(printf '%s\n%s\n' "$NEW_PASSWORD" "$NEW_PASSWORD")" 2>/dev/null || {
  echo
  echo "The password change failed."
  echo "Removing the locally stored password because the remote change was not confirmed."
  rm -f "$PASSWORD_FILE"
  exit 1
}

echo
echo "Password change command completed."
echo "Password saved to: $PASSWORD_FILE"
echo "Permissions: 600"
