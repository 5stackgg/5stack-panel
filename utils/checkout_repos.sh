#!/bin/bash

checkout_repos() {
    # Get the script directory and determine parent directory (one level up from 5stack-panel)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Go up two levels: from utils/ to 5stack-panel/ to 5stack/
    PARENT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
    
    # Define repos to checkout (format: "name url")
    repos=(
        "api https://github.com/5stackgg/api.git"
        "web https://github.com/5stackgg/web.git"
        "game-server https://github.com/5stackgg/game-server.git"
        "game-server-node-connector https://github.com/5stackgg/game-server-node-connector.git"
    )
    
    echo "Checking for required repositories in: $PARENT_DIR"
    echo ""
    
    # Ask about each repo one by one
    for entry in "${repos[@]}"; do
        name=${entry%% *}
        url=${entry#* }
        repo_name="$name"
        repo_url="$url"
        repo_path="$PARENT_DIR/$repo_name"
        
        if [ -d "$repo_path" ]; then
            continue
        fi
        
        echo "$repo_name does not exist at $repo_path"
        echo -n "Do you want to clone $repo_name? (y/n): "
        read -r response
        
        if [[ "$response" =~ ^[Yy]$ ]]; then
            echo "Cloning $repo_name from $repo_url..."
            if git clone "$repo_url" "$repo_path"; then
                echo "Successfully cloned $repo_name"
            else
                echo "Error: $repo_name is required. Exiting."
                exit 1
            fi
        else
            echo "Error: $repo_name is required. Exiting."
            exit 1
        fi
        echo ""
    done
    
    echo "Repository checkout complete!"
}

