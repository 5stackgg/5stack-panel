#!/bin/bash

# Utility function to replace $(RAND32) placeholders with random base64 encoded strings
replace_rand32_in_env_files() {
    local secrets_dir=$1
    
    if [ ! -d "$secrets_dir" ]; then
        echo "Warning: Secrets directory $secrets_dir not found, skipping RAND32 replacement..."
        return
    fi
    
    # Replace $(RAND32) with a random base64 encoded string in all non-example env files
    for env_file in "$secrets_dir"/*.env; do
        if [[ -f "$env_file" && ! "$env_file" == *.example ]]; then
            # Generate a random base64 encoded string
            random_string=$(openssl rand -base64 32 | tr '/' '_' | tr '=' '_')
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s/\$(RAND32)/$random_string/g" "$env_file"
            else
                sed -i "s/\$(RAND32)/$random_string/g" "$env_file"
            fi
        fi
    done
}

