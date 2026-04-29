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
