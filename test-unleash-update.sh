#!/bin/bash

# Test script to run just the Unleash token update function

# Source the auto-deploy.sh to get the functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set required variables
HBI_DIR="/Users/aarif/Documents/dev-ws/insights/insights-host-inventory"
TMP_DIR="$HBI_DIR/tmp"
PROJECT_NAMESPACE=$(oc project -q)

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Log functions (copied from auto-deploy.sh)
log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] ✓${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ✗${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] ⚠${NC} $1"
}

# Source the functions from auto-deploy.sh
source "$SCRIPT_DIR/auto-deploy.sh"

# Run just the Unleash token update
log "Testing Unleash token update..."
log "Environment file: $HBI_DIR/.env"
log "Current namespace: $PROJECT_NAMESPACE"
echo ""

update_unleash_token_in_env "$HBI_DIR/.env"

echo ""
log "Test complete. Check your .env file:"
log "  UNLEASH_TOKEN: $(grep '^UNLEASH_TOKEN=' "$HBI_DIR/.env" | cut -d= -f2- | cut -c1-50)..."
log "  UNLEASH_URL: $(grep '^UNLEASH_URL=' "$HBI_DIR/.env" | cut -d= -f2-)"
