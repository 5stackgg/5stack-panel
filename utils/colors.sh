#!/bin/bash

if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_STEP=$'\033[1;36m'
  C_OK=$'\033[0;32m'
  C_WARN=$'\033[1;33m'
  C_ERR=$'\033[0;31m'
  C_DIM=$'\033[2m'
else
  C_RESET=''; C_STEP=''; C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''
fi

step() { echo; echo "${C_STEP}==> $1${C_RESET}"; }
ok()   { echo "${C_OK}    $1${C_RESET}"; }
warn() { echo "${C_WARN}    $1${C_RESET}"; }
err()  { echo "${C_ERR}    $1${C_RESET}" >&2; }

banner() {
  echo
  echo "${C_OK}=================================${C_RESET}"
  echo "${C_OK}  $1${C_RESET}"
  echo "${C_OK}=================================${C_RESET}"
}

# read_masked PROMPT VARNAME — read a secret, echoing '*' for each char.
# Handles backspace. Reads from /dev/tty so it works under curl|bash too.
read_masked() {
  local __prompt="$1" __outvar="$2"
  local __value="" __char
  echo -en "$__prompt"
  while IFS= read -r -s -n 1 __char </dev/tty; do
    if [ -z "$__char" ]; then
      break
    fi
    if [ "$__char" = $'\x7f' ] || [ "$__char" = $'\b' ]; then
      if [ -n "$__value" ]; then
        __value="${__value%?}"
        echo -en "\b \b"
      fi
    else
      __value+="$__char"
      echo -n "*"
    fi
  done
  echo
  printf -v "$__outvar" '%s' "$__value"
}
