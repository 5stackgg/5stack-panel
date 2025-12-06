#!/bin/bash

# Utility function to copy config or secrets files from source to destination
copy_config_or_secrets() {
    local source_dir=$1
    local dest_dir=$2
    
    if [ ! -d "$source_dir" ]; then
        echo "Warning: Source directory $source_dir not found, skipping..."
        return
    fi
    
    # Create destination directory if it doesn't exist
    mkdir -p "$dest_dir"
    
    # Copy .env.example files and kustomization.yaml from source to destination (only if source and dest are different)
    if [ "$source_dir" != "$dest_dir" ]; then
        # Copy .env.example files
        for file in "$source_dir"/*.env.example; do
            if [ -f "$file" ]; then
                cp "$file" "$dest_dir/"
            fi
        done
    fi
    
    # Ensure all .example files have corresponding non-example files
    for file in "$dest_dir"/*.env.example; do
        if [ -f "$file" ]; then
            env_file="${file%.example}"
            if [ ! -f "$env_file" ]; then
                cp "$file" "$env_file"
            fi
        fi
    done
}

