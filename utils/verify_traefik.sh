#!/bin/bash

verify_traefik_installation() {
    echo "Verifying Traefik installation..."
    echo ""

    CHECKS_PASSED=0
    CHECKS_FAILED=0

    # Check 1: Traefik pod running
    echo "[ 1/6 ] Checking Traefik pod status..."
    if kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik 2>/dev/null | grep -q "Running"; then
        echo "        ✓ Traefik pod is running"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo "        ✗ Traefik pod is not running"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi

    # Check 2: IngressRoutes created
    echo "[ 2/6 ] Checking IngressRoutes..."
    ROUTE_COUNT=$(kubectl get ingressroute -n 5stack --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$ROUTE_COUNT" -ge 10 ]; then
        echo "        ✓ Found $ROUTE_COUNT IngressRoutes"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo "        ✗ Only found $ROUTE_COUNT IngressRoutes (expected at least 10)"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi

    # Check 3: Middlewares created
    echo "[ 3/6 ] Checking Middlewares..."
    MIDDLEWARE_COUNT=$(kubectl get middleware -n 5stack --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$MIDDLEWARE_COUNT" -ge 6 ]; then
        echo "        ✓ Found $MIDDLEWARE_COUNT Middlewares"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo "        ✗ Only found $MIDDLEWARE_COUNT Middlewares (expected at least 6)"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi

    # Check 4: Traefik service accessible
    echo "[ 4/6 ] Checking Traefik service..."
    if kubectl get svc -n kube-system traefik 2>/dev/null | grep -q "LoadBalancer"; then
        echo "        ✓ Traefik LoadBalancer service exists"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo "        ✗ Traefik LoadBalancer service not found"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi

    # Check 5: Old nginx resources removed
    echo "[ 5/6 ] Checking for old nginx resources..."
    if kubectl get namespace ingress-nginx 2>/dev/null >/dev/null; then
        echo "        ⚠ nginx-ingress namespace still exists (cleanup needed)"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    else
        echo "        ✓ nginx-ingress namespace removed"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    fi

    # Check 6: Configuration marker
    echo "[ 6/6 ] Checking configuration marker..."
    if [ -f .5stack-env.config ] && grep -q "INGRESS_CONTROLLER=traefik" .5stack-env.config; then
        echo "        ✓ Configuration marker set correctly"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo "        ✗ Configuration marker not set"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi

    echo ""
    echo "=========================================="
    echo "Verification Summary"
    echo "=========================================="
    echo "Checks passed: $CHECKS_PASSED/6"
    echo "Checks failed: $CHECKS_FAILED/6"
    echo ""

    if [ $CHECKS_FAILED -eq 0 ]; then
        echo "✅ All checks passed! Traefik migration successful."
        echo ""
        echo "Next steps:"
        echo "  1. Test your endpoints to ensure proper routing"
        echo "  2. Check the IngressRoutes: kubectl get ingressroute -n 5stack"
        echo "  3. Check the Middlewares: kubectl get middleware -n 5stack"
        echo ""
        return 0
    else
        echo "❌ Some checks failed. Please review the errors above."
        echo ""
        echo "Troubleshooting:"
        echo "  - Check Traefik logs: kubectl logs -n kube-system -l app.kubernetes.io/name=traefik"
        echo "  - List IngressRoutes: kubectl get ingressroute -n 5stack"
        echo "  - List Middlewares: kubectl get middleware -n 5stack"
        echo ""
        return 1
    fi
}

# If script is run directly (not sourced), execute the function
if [ "${BASH_SOURCE[0]}" -ef "$0" ]; then
    verify_traefik_installation
fi
