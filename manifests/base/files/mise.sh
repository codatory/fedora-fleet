# mise, for every user on the machine.
#
# mise is installed as a system package, so this is system-wide rather than a line appended
# to each user's dotfile. Fedora sources /etc/profile.d/*.sh exactly once per shell, from
# /etc/profile for a login shell, from /etc/bashrc for an interactive bash that is not one,
# and from /etc/zshrc for the same case in zsh. Because it is one file either way, it has to
# tell the two apart itself rather than living in a "login" file and an "interactive" one.
#
# The two get different things, as upstream recommends:
#
#   - A login shell gets shims on PATH (`mise activate --shims`). Programs started from it,
#     such as an editor or anything else that never sources a shell startup file, can then
#     find mise's tools. It costs one PATH entry and no per-prompt work.
#   - An interactive shell gets full activation, which follows the directory as you `cd` and
#     exports the project's `[env]` variables.
#
# Activation cannot be pasted in here: `mise activate` names the calling user's own shims
# directory, so output generated once would point every user at the account that happened to
# run the manifest. Each shell also gets code of its own, so one cannot use the other's.
#
# zsh needs `emulate -L zsh` for the full activation only: Fedora sources this file from
# /etc/zprofile and /etc/zshrc inside `emulate -L ksh`, where mise's `(( $+functions[...] ))`
# is not arithmetic test syntax. Without it each zsh startup prints `bad output format
# specification` five times and still activates, so the mistake survives. `--shims` is a plain
# export and needs no such care.
if command -v mise >/dev/null 2>&1; then
    interactive=false
    login=false

    if [ -n "${BASH_VERSION-}" ]; then
        shell=bash
        case "$-" in *i*) interactive=true ;; esac
        shopt -q login_shell && login=true
    elif [ -n "${ZSH_VERSION-}" ]; then
        shell=zsh
        [[ -o interactive ]] && interactive=true
        [[ -o login ]] && login=true
    fi

    if [ -n "${shell-}" ]; then
        if [ "$login" = true ] || [ "$interactive" = false ]; then
            eval "$(mise activate "$shell" --shims)"
        fi

        if [ "$interactive" = true ]; then
            [ "$shell" = zsh ] && emulate -L zsh
            eval "$(mise activate "$shell")"
        fi

        unset shell interactive login
    fi
fi
