#!/bin/bash

# Utility function to choose and set Kubernetes context
choose_k8s_context() {
  echo "Detecting available Kubernetes contexts..."
  contexts=($(kubectl config get-contexts -o name))

  if [ ${#contexts[@]} -eq 0 ]; then
    echo "No Kubernetes contexts found in kubeconfig."
    exit 1
  fi

  echo "Available contexts:"
  for i in "${!contexts[@]}"; do
    echo "  $((i+1))) ${contexts[$i]}"
  done

  # Save current terminal settings
  if [ -t 0 ]; then
    stty_save=$(stty -g)
    # Configure terminal to handle input properly on macOS
    stty icrnl
  fi

  # Build comma-separated list of numbers
  numbers=()
  for ((i=1; i<=${#contexts[@]}; i++)); do
    numbers+=("$i")
  done
  numbers_list=$(IFS=','; echo "${numbers[*]}")

  while true; do
    echo -n "Select a context to use (${numbers_list}): "
    if [ -t 0 ]; then
      read -r choice </dev/tty
    else
      read -r choice
    fi
    # Convert carriage return to newline and trim
    choice=$(echo "$choice" | tr -d '\r' | tr -d '\n' | xargs)
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#contexts[@]} ]; then
      selected="${contexts[$((choice-1))]}"
      echo "Using context: $selected"
      kubectl config use-context "$selected"
      echo "Checking cluster connectivity..."
      if kubectl get nodes >/dev/null 2>&1; then
        echo "Successfully connected to cluster."
        break
      else
        echo "Cannot connect to cluster using this context."
        echo "Please choose another context."
        echo ""
      fi
    else
      if [ -n "$choice" ]; then
        echo "Invalid selection. Please enter a number between 1 and ${#contexts[@]}."
      fi
    fi
  done

  # Restore terminal settings
  if [ -t 0 ] && [ -n "$stty_save" ]; then
    stty "$stty_save" 2>/dev/null || true
  fi
}

