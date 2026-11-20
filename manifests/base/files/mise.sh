# mise, for every user on the machine.
#
# mise is installed as a system package, so its activation is system-wide rather than
# appended to each user's dotfile. Fedora sources /etc/profile.d/*.sh from /etc/profile for
# login shells and from /etc/bashrc for interactive bash and /etc/zshrc for interactive zsh,
# which together cover a terminal.
#
# The activation has to run at login rather than being pasted in here: `mise activate` names
# the calling user's own shims directory, so a file generated once would point every user at
# the account that happened to run the manifest. Each shell also gets code of its own, so the
# output for one cannot be used by another.
#
# zsh needs `emulate -L zsh` first: Fedora sources this file from /etc/zprofile and
# /etc/zshrc inside `emulate -L ksh`, where mise's `(( $+functions[...] ))` is not arithmetic
# test syntax. Without it each zsh startup prints `bad output format specification` five times
# and still activates, so the mistake survives.
if command -v mise >/dev/null 2>&1; then
    if [ -n "${BASH_VERSION-}" ]; then
        eval "$(mise activate bash)"
    elif [ -n "${ZSH_VERSION-}" ]; then
        emulate -L zsh
        eval "$(mise activate zsh)"
    fi
fi
