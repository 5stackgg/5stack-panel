#!/bin/bash
# Pure-bash interactive single-select menu and multi-select checklist.
# No external dependencies — works wherever bash + an ANSI-capable TTY exists.
# ESC sequences and cursor control use raw ANSI so we don't depend on tput
# or terminfo (works on minimal containers with TERM=dumb).

_isel_hide_cursor() { printf '\033[?25l'; }
_isel_show_cursor() { printf '\033[?25h'; }
_isel_clear_lines() { printf '\033[%dA\033[J' "$1"; }

# interactive_menu OUT_VAR PROMPT DEFAULT_INDEX OPTION1 OPTION2 ...
# Sets OUT_VAR to the 0-based index of the chosen option.
interactive_menu() {
    local out_var="$1" prompt="$2" cursor="$3"
    shift 3
    local options=("$@")
    local n=${#options[@]}
    if [ "$n" -eq 0 ]; then
        printf -v "$out_var" "%s" ""
        return 1
    fi

    trap '_isel_show_cursor; exit 130' INT
    _isel_hide_cursor

    local first=1 key seq i
    while true; do
        if [ "$first" -eq 1 ]; then
            first=0
        else
            _isel_clear_lines $((n + 2))
        fi
        printf '%s\n' "$prompt"
        printf '(↑/↓ to move, Enter to confirm)\n'
        for ((i=0; i<n; i++)); do
            if [ "$i" -eq "$cursor" ]; then
                printf '> %s\n' "${options[i]}"
            else
                printf '  %s\n' "${options[i]}"
            fi
        done

        IFS= read -rsn1 key
        if [ "$key" = $'\x1b' ]; then
            IFS= read -rsn2 -t 1 seq 2>/dev/null || seq=""
            case "$seq" in
                '[A') (( cursor > 0 )) && (( cursor-- )) ;;
                '[B') (( cursor < n - 1 )) && (( cursor++ )) ;;
            esac
        elif [ -z "$key" ]; then
            break
        fi
    done

    _isel_show_cursor
    trap - INT
    printf -v "$out_var" "%s" "$cursor"
}

# interactive_checklist OUT_VAR PROMPT "PRE_SELECTED_SPACE_SEPARATED" OPTION1 OPTION2 ...
# Sets OUT_VAR to a space-separated list of the selected options.
interactive_checklist() {
    local out_var="$1" prompt="$2" preselected=" $3 "
    shift 3
    local options=("$@")
    local n=${#options[@]}
    if [ "$n" -eq 0 ]; then
        printf -v "$out_var" "%s" ""
        return 1
    fi

    local selected=() i
    for ((i=0; i<n; i++)); do
        if [[ "$preselected" == *" ${options[i]} "* ]]; then
            selected[i]=1
        else
            selected[i]=0
        fi
    done

    local cursor=0 first=1 key seq

    trap '_isel_show_cursor; exit 130' INT
    _isel_hide_cursor

    while true; do
        if [ "$first" -eq 1 ]; then
            first=0
        else
            _isel_clear_lines $((n + 2))
        fi
        printf '%s\n' "$prompt"
        printf '(↑/↓ to move, Space to toggle, Enter to confirm)\n'
        for ((i=0; i<n; i++)); do
            local mark=" "
            [ "${selected[i]}" = "1" ] && mark="x"
            if [ "$i" -eq "$cursor" ]; then
                printf '> [%s] %s\n' "$mark" "${options[i]}"
            else
                printf '  [%s] %s\n' "$mark" "${options[i]}"
            fi
        done

        IFS= read -rsn1 key
        if [ "$key" = $'\x1b' ]; then
            IFS= read -rsn2 -t 1 seq 2>/dev/null || seq=""
            case "$seq" in
                '[A') (( cursor > 0 )) && (( cursor-- )) ;;
                '[B') (( cursor < n - 1 )) && (( cursor++ )) ;;
            esac
        elif [ "$key" = " " ]; then
            if [ "${selected[cursor]}" = "1" ]; then
                selected[cursor]=0
            else
                selected[cursor]=1
            fi
        elif [ -z "$key" ]; then
            break
        fi
    done

    _isel_show_cursor
    trap - INT

    local result=""
    for ((i=0; i<n; i++)); do
        [ "${selected[i]}" = "1" ] && result+="${options[i]} "
    done
    result="${result% }"
    printf -v "$out_var" "%s" "$result"
}
