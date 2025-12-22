#!/bin/bash

source setup-env.sh "$@"

namespace="5stack"
debug_file="debug_output_$(date +%Y%m%d_%H%M%S).txt"

echo "(KUBECONFIG: $KUBECONFIG, REVERSE_PROXY: $REVERSE_PROXY)" | tee -a "$debug_file"

echo "Domains and Hosts Configuration:" | tee -a "$debug_file"
echo "--------------------------------" | tee -a "$debug_file"
echo "WEB_DOMAIN: $WEB_DOMAIN" | tee -a "$debug_file"
echo "WS_DOMAIN: $WS_DOMAIN" | tee -a "$debug_file"
echo "API_DOMAIN: $API_DOMAIN" | tee -a "$debug_file"
echo "RELAY_DOMAIN: $RELAY_DOMAIN" | tee -a "$debug_file"
echo "DEMOS_DOMAIN: $DEMOS_DOMAIN" | tee -a "$debug_file"
echo "MAIL_FROM: $MAIL_FROM" | tee -a "$debug_file"
echo "S3_CONSOLE_HOST: $S3_CONSOLE_HOST" | tee -a "$debug_file"
echo "TYPESENSE_HOST: $TYPESENSE_HOST" | tee -a "$debug_file"
echo "--------------------------------" | tee -a "$debug_file"  

echo "Checking pod status and restarts in namespace $namespace..." | tee -a "$debug_file"
echo "---------------------------------------" | tee -a "$debug_file"

# Get all pods in the namespace
kubectl --kubeconfig=$KUBECONFIG get pods -n "$namespace" --no-headers | while read -r pod; do
    pod_name=$(echo "$pod" | awk '{print $1}')
    restarts=$(echo "$pod" | awk '{print $4}')
    
    echo "Pod: $pod_name" | tee -a "$debug_file"
    echo "Total restarts: $restarts" | tee -a "$debug_file"
    
    echo "Last restart reason:" | tee -a "$debug_file"
    kubectl --kubeconfig=$KUBECONFIG get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' | tee -a "$debug_file"
    echo -e "\n" | tee -a "$debug_file"
    
    kubectl --kubeconfig=$KUBECONFIG logs "$pod_name" -n "$namespace" --tail=100 | tee -a "$debug_file"
    
    echo "---------------------------------------" | tee -a "$debug_file"
done

echo "Checking certificates in namespace $namespace..." | tee -a "$debug_file"
echo "---------------------------------------" | tee -a "$debug_file"

# Loop through all certificates in all namespaces
for cert in $(kubectl --kubeconfig=$KUBECONFIG get certificates -A -o custom-columns=NAME:.metadata.name --no-headers | awk '{print $1}'); do
  name=$(echo "$cert" | cut -d'/' -f2)

  # Get the Ready condition status for the certificate
  status=$(kubectl --kubeconfig=$KUBECONFIG get certificate "$name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

  # If the certificate is valid, skip to the next
  if [[ "$status" == "True" ]]; then
    echo "Certificate $name in namespace $namespace is valid." | tee -a "$debug_file"
  else
    echo "Certificate $name in namespace $namespace is not valid. Fetching details..." | tee -a "$debug_file"

    # Get details of the certificate
    kubectl --kubeconfig=$KUBECONFIG describe certificate "$name" -n "$namespace" | tee -a "$debug_file"

    # Find associated challenges for this certificate
    echo "Checking challenges for certificate $name..." | tee -a "$debug_file"

    # Get all challenges in the same namespace and filter by the certificate name
    kubectl --kubeconfig=$KUBECONFIG get challenges -n "$namespace" --no-headers | grep "$name" | while read -r challenge; do
      challenge_name=$(echo "$challenge" | awk '{print $1}')

      # Check if the challenge is valid
      challenge_status=$(kubectl --kubeconfig=$KUBECONFIG get challenge "$challenge_name" -n "$namespace" -o jsonpath='{.status.state}')

      # Only fetch details if the challenge is not valid
      if [[ "$challenge_status" != "valid" ]]; then
        echo "Challenge $challenge_name for certificate $name is not valid. Fetching details..." | tee -a "$debug_file"
        kubectl --kubeconfig=$KUBECONFIG describe challenge "$challenge_name" -n "$namespace" | tee -a "$debug_file"
      else
        echo "Challenge $challenge_name for certificate $name is valid." | tee -a "$debug_file"
      fi
    done
  fi

  echo "---------------------------------------" | tee -a "$debug_file"
done

echo -e "\033[32mDebug log saved to: $debug_file\033[0m"
