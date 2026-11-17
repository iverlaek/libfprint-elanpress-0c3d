#!/bin/bash
# Wire the (now working) fingerprint reader into PAM, replicating exactly what
# omarchy-setup-security-fingerprint's setup_pam_config() does -- without the
# package reinstall or the re-enrollment it would also attempt.
#
# Run as root:  sudo /tmp/opencode/pam-fingerprint.sh
set -e

# A clamshell gate runs before pam_fprintd: when the lid is shut the reader is
# unreachable, so the gate succeeds (success=1) and PAM skips straight to the
# password prompt instead of blocking on the reader until it times out.
fprintd_gate="auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed"

add_to() {
  local f=$1

  if ! grep -q pam_fprintd.so "$f"; then
    echo "Adding pam_fprintd to $f"
    sed -i '1i auth      sufficient pam_fprintd.so' "$f"
  fi

  if ! grep -q 'omarchy-hw-laptop-closed' "$f"; then
    echo "Adding clamshell gate to $f"
    sed -i "/pam_fprintd\.so/i $fprintd_gate" "$f"
  fi
}

add_to /etc/pam.d/sudo

if [[ -f /etc/pam.d/polkit-1 ]]; then
  add_to /etc/pam.d/polkit-1
else
  echo "Creating /etc/pam.d/polkit-1 with fingerprint authentication"
  cat > /etc/pam.d/polkit-1 <<'EOF'
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth      include system-auth

account   include system-auth
password  include system-auth
session   include system-auth
EOF
  chmod 644 /etc/pam.d/polkit-1
fi

# Lock screen (creates /etc/pam.d/omarchy-lock-fingerprint, resume hook, etc.).
# It reads fprintd's enrollment as the invoking user, which sudo passes through.
echo "Configuring lock screen authentication..."
OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy} /usr/bin/omarchy-apply-lock

echo
echo "Done. Fingerprint is now wired into sudo, polkit and the lock screen."
