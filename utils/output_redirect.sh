#!/bin/bash

output_redirect() {
    if [ "$DEBUG" = true ]; then
        "$@"
    else
        "$@" >/dev/null
    fi
}