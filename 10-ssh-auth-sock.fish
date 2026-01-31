# fish shell configuration snippet - sourced by fish, not executed directly
# SSH agent socket for fish shell sessions
# ~/.config/fish/conf.d/10-ssh-auth-sock.fish
#
# Sets SSH_AUTH_SOCK for terminal sessions using fish shell.
# Complements 10-ssh-auth-sock.conf which handles graphical sessions.
#
# Requires: systemctl --user enable --now ssh-agent.service
# See: https://wiki.archlinux.org/title/SSH_keys#SSH_agents
#
# Only sets the variable if:
#   1. Running in an interactive session (scripts don't need SSH agent)
#   2. XDG_RUNTIME_DIR is defined (should always be set by systemd)
#   3. The socket file actually exists (ssh-agent.service is running)
# This prevents errors when ssh-agent.service is not running or in
# non-systemd environments (e.g., chroot, containers).

if status is-interactive
    if set -q XDG_RUNTIME_DIR; and test -S "$XDG_RUNTIME_DIR/ssh-agent.socket"
        set -gx SSH_AUTH_SOCK "$XDG_RUNTIME_DIR/ssh-agent.socket"
    end
end
