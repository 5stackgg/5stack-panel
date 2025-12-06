#!/bin/bash

update_env_var() {
    local file=$1
    local key=$2
    local value=$3
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|^$key=.*|$key=$value|" "$file"
    else
        sed -i "s|^$key=.*|$key=$value|" "$file"
    fi
}

