#!/bin/bash

update_env_var() {
    local file=$1
    local key=$2
    local value=$3
    
    if grep -q "^$key=" "$file" 2>/dev/null; then
        # Key exists, update it
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^$key=.*|$key=$value|" "$file"
        else
            sed -i "s|^$key=.*|$key=$value|" "$file"
        fi
    else
        echo "$key=$value" >> "$file"
    fi
}

