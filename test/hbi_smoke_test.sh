#!/bin/bash

# HBI Smoke Test
# Validates SpiceDB schema, demo hosts, and RBAC → Kessel replication

set -e

echo "Starting HBI Smoke Test"
echo "======================"
echo ""

echo "Setting up SpiceDB connection..."

# Setup - connect to the actual SpiceDB pod
SPICEDB_POD=$(oc get pods | grep relations-spicedb-spicedb | awk '{print $1}' | head -1)
if [[ -z "$SPICEDB_POD" ]]; then
    echo "❌ ERROR: Could not find SpiceDB pod"
    exit 1
fi
echo "Found SpiceDB pod: $SPICEDB_POD"

echo "Starting port forward..."
oc port-forward pod/$SPICEDB_POD 50051:50051 &
PORT_FORWARD_PID=$!

# Wait for port forward to establish
sleep 3

SPICEDB_TOKEN=$(oc get secret dev-spicedb-config -o jsonpath='{.data.preshared_key}' | base64 -d)
SPICEDB_ENDPOINT="localhost:50051"

if [[ -z "$SPICEDB_TOKEN" ]]; then
    echo "❌ ERROR: Could not retrieve SpiceDB preshared key from secret"
    exit 1
fi

export SPICEDB_TOKEN="$SPICEDB_TOKEN"
echo "SpiceDB endpoint: $SPICEDB_ENDPOINT"
echo ""

# Cleanup function
cleanup() {
    echo "Cleaning up port forward..."
    kill $PORT_FORWARD_PID 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Schema Validation ==="

# Get schema
SCHEMA_OUTPUT=$(zed schema read --endpoint $SPICEDB_ENDPOINT --token "$SPICEDB_TOKEN" --insecure 2>/dev/null)
if [[ -z "$SCHEMA_OUTPUT" ]]; then
    echo "❌ ERROR: No schema found in SpiceDB!"
    exit 1
fi

echo "✅ Schema is loaded and accessible"
echo ""

echo "Available object types:"
echo "$SCHEMA_OUTPUT" | grep "definition " | awk '{print "  - " $2}'
echo ""

# Test required schema definitions
REQUIRED_TYPES=("hbi/host" "rbac/group" "rbac/workspace")
SCHEMA_TESTS_PASSED=0

for type in "${REQUIRED_TYPES[@]}"; do
    if echo "$SCHEMA_OUTPUT" | grep -q "definition $type"; then
        echo "✅ $type definition found in schema"
        SCHEMA_TESTS_PASSED=$((SCHEMA_TESTS_PASSED + 1))
    else
        echo "❌ ERROR: $type definition not found in schema"
    fi
done

echo ""
echo "=== Data Validation ==="

echo "Fetching relationship data..."

HOST_RELATIONSHIPS=$(zed relationship read "hbi/host:" --endpoint $SPICEDB_ENDPOINT --token "$SPICEDB_TOKEN" --insecure 2>/dev/null || echo "")
GROUP_RELATIONSHIPS=$(zed relationship read "rbac/group:" --endpoint $SPICEDB_ENDPOINT --token "$SPICEDB_TOKEN" --insecure 2>/dev/null || echo "")
WORKSPACE_RELATIONSHIPS=$(zed relationship read "rbac/workspace:" --endpoint $SPICEDB_ENDPOINT --token "$SPICEDB_TOKEN" --insecure 2>/dev/null || echo "")

# Count relationships
HOST_COUNT=0
GROUP_COUNT=0
WORKSPACE_COUNT=0

if [[ -n "$HOST_RELATIONSHIPS" ]]; then
    HOST_COUNT=$(echo "$HOST_RELATIONSHIPS" | grep -c "^hbi/host:" || echo "0")
fi

if [[ -n "$GROUP_RELATIONSHIPS" ]]; then
    GROUP_COUNT=$(echo "$GROUP_RELATIONSHIPS" | grep -c "^rbac/group:" || echo "0")
fi

if [[ -n "$WORKSPACE_RELATIONSHIPS" ]]; then
    WORKSPACE_COUNT=$(echo "$WORKSPACE_RELATIONSHIPS" | grep -c "^rbac/workspace:" || echo "0")
fi

echo ""
echo "Data Summary:"
echo "  • Hosts: $HOST_COUNT"
echo "  • RBAC Groups: $GROUP_COUNT"
echo "  • RBAC Workspaces: $WORKSPACE_COUNT"
echo ""

# Show detailed data
if [[ $HOST_COUNT -gt 0 ]]; then
    echo "Host Details:"
    echo "$HOST_RELATIONSHIPS" | while read -r line; do
        if [[ -n "$line" ]]; then
            HOST_ID=$(echo "$line" | awk '{print $1}' | cut -d':' -f2)
            WORKSPACE=$(echo "$line" | awk '{print $3}' | cut -d':' -f2)
            echo "  • Host: $HOST_ID → Workspace: $WORKSPACE"
        fi
    done
    echo ""
fi

if [[ $GROUP_COUNT -gt 0 ]]; then
    echo "RBAC Group Details:"
    echo "$GROUP_RELATIONSHIPS" | head -10 | while read -r line; do
        if [[ -n "$line" ]]; then
            GROUP_ID=$(echo "$line" | awk '{print $1}' | cut -d':' -f2)
            RELATION=$(echo "$line" | awk '{print $2}')
            SUBJECT=$(echo "$line" | awk '{print $3}')
            echo "  • Group: $GROUP_ID → $RELATION → $SUBJECT"
        fi
    done
    if [[ $GROUP_COUNT -gt 10 ]]; then
        echo "  ... and $((GROUP_COUNT - 10)) more groups"
    fi
    echo ""
fi

if [[ $WORKSPACE_COUNT -gt 0 ]]; then
    echo "RBAC Workspace Details:"
    echo "$WORKSPACE_RELATIONSHIPS" | head -10 | while read -r line; do
        if [[ -n "$line" ]]; then
            WORKSPACE_ID=$(echo "$line" | awk '{print $1}' | cut -d':' -f2)
            RELATION=$(echo "$line" | awk '{print $2}')
            SUBJECT=$(echo "$line" | awk '{print $3}')
            echo "  • Workspace: $WORKSPACE_ID → $RELATION → $SUBJECT"
        fi
    done
    if [[ $WORKSPACE_COUNT -gt 10 ]]; then
        echo "  ... and $((WORKSPACE_COUNT - 10)) more workspaces"
    fi
    echo ""
fi

echo "=== Full Schema ==="
echo "$SCHEMA_OUTPUT"
echo ""

echo "=== Test Results ==="

# Validate results
DATA_TESTS_PASSED=0
ISSUES=0

# Host validation
if [[ $HOST_COUNT -eq 10 ]]; then
    echo "✅ Exactly 10 demo hosts found (HBI → SpiceDB working)"
    DATA_TESTS_PASSED=$((DATA_TESTS_PASSED + 1))
elif [[ $HOST_COUNT -gt 10 ]]; then
    echo "⚠️  More than 10 hosts found ($HOST_COUNT) - may have leftover data"
elif [[ $HOST_COUNT -gt 0 ]]; then
    echo "⚠️  Only $HOST_COUNT hosts found (expected 10)"
    ISSUES=$((ISSUES + 1))
else
    echo "❌ No hosts found in SpiceDB"
    ISSUES=$((ISSUES + 1))
fi

# RBAC groups validation
if [[ $GROUP_COUNT -gt 0 ]]; then
    echo "✅ RBAC groups present ($GROUP_COUNT) - RBAC → Kessel replication working"
    DATA_TESTS_PASSED=$((DATA_TESTS_PASSED + 1))
else
    echo "⚠️  No RBAC groups found - may indicate replication issue"
    ISSUES=$((ISSUES + 1))
fi

# RBAC workspaces validation
if [[ $WORKSPACE_COUNT -gt 0 ]]; then
    echo "✅ RBAC workspaces present ($WORKSPACE_COUNT) - RBAC → Kessel replication working"
    DATA_TESTS_PASSED=$((DATA_TESTS_PASSED + 1))
else
    echo "⚠️  No RBAC workspaces found - may indicate replication issue"
    ISSUES=$((ISSUES + 1))
fi

echo ""
echo "Summary:"
echo "Schema Tests: $SCHEMA_TESTS_PASSED/3 passed"
echo "Data Tests: $DATA_TESTS_PASSED/3 passed"
echo "Issues: $ISSUES"
echo ""

# Final assessment
if [[ $SCHEMA_TESTS_PASSED -eq 3 && $DATA_TESTS_PASSED -eq 3 && $ISSUES -eq 0 ]]; then
    echo "🎉 HBI SMOKE TEST PASSED! HBI and RBAC integration working correctly."
    echo ""
    echo "✅ Schema loaded with required object types"
    echo "✅ Demo hosts present (HBI → SpiceDB pipeline working)"
    echo "✅ RBAC groups replicated (RBAC → Kessel pipeline working)"
    echo "✅ RBAC workspaces replicated (RBAC → Kessel pipeline working)"
    exit 0
elif [[ $ISSUES -eq 0 ]]; then
    echo "✅ Core functionality working - minor data count variations"
    exit 0
else
    echo "❌ Issues found with HBI deployment"
    echo ""
    echo "Check the following:"
    echo "  • SpiceDB is running and accessible"
    echo "  • Schema has been loaded properly"
    echo "  • Debezium connectors are running (for HBI → SpiceDB)"
    echo "  • RBAC service is running and connected (for RBAC → Kessel)"
    exit 1
fi 