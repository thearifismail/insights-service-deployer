#!/bin/bash

# Okteto Development Environment Wrapper
set -e

# Configuration - can be overridden by environment variables
INSIGHTS_REPO_PATH="${INSIGHTS_REPO_PATH:-/Users/mmclaugh/go/src/github.com/RedHatInsights/insights-host-inventory}"

# Default services (hardcoded based on deployment discovery)
DEFAULT_SERVICES=("host-inventory-service" "host-inventory-service-reads" "host-inventory-service-secondary-reads" "host-inventory-service-writes" "host-inventory-export-service")

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[okteto-dev]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[okteto-dev]${NC} $1" >&2; }
error() { echo -e "${RED}[okteto-dev]${NC} $1" >&2; }

# Check if development containers are active
check_dev_status() {
    local services=("${@:-${DEFAULT_SERVICES[@]}}")
    local active=() inactive=()
    
    for service in "${services[@]}"; do
        if oc get deployment "$service" >/dev/null 2>&1 && oc get deployment "${service}-okteto" >/dev/null 2>&1; then
            active+=("$service")
        elif oc get deployment "$service" >/dev/null 2>&1; then
            inactive+=("$service")
        fi
    done
    
    echo "${active[@]}|${inactive[@]}"
}

# Show development status
show_status() {
    local services=("${@:-${DEFAULT_SERVICES[@]}}")
    log "Current development status:"
    log "Repo path: $INSIGHTS_REPO_PATH"
    
    local active_count=0 total_count=0
    for service in "${services[@]}"; do
        if ! oc get deployment "$service" >/dev/null 2>&1; then
            echo "  ❌ $service (not found)" >&2
            continue
        fi
        total_count=$((total_count + 1))
        if oc get deployment "${service}-okteto" >/dev/null 2>&1; then
            echo "  🚀 $service (development)" >&2
            active_count=$((active_count + 1))
        else
            echo "  📦 $service (production)" >&2
        fi
    done
    
    echo "" >&2
    if [[ $active_count -eq 0 ]]; then
        echo "  All services in production mode" >&2
    elif [[ $active_count -eq $total_count ]]; then
        echo "  All services in development mode" >&2
    else
        echo "  Mixed mode ($active_count/$total_count in development)" >&2
    fi
}

# Main okteto commands
okteto_up() {
    local services=("${@:-${DEFAULT_SERVICES[@]}}")
    local status=$(check_dev_status "${services[@]}")
    local active=$(echo "$status" | cut -d'|' -f1)
    local inactive=$(echo "$status" | cut -d'|' -f2)
    
    if [[ -n "$active" && -z "$inactive" ]]; then
        log "All services already in development mode (idempotent)"
        return 0
    fi
    
    [[ -n "$active" ]] && log "Already active: $active"
    [[ -n "$inactive" ]] && log "Starting development for: $inactive"
    
    # Set the repo path for okteto
    export INSIGHTS_REPO_PATH
    okteto up --namespace "$(oc project -q)" "$@"
}

okteto_down() {
    local status=$(check_dev_status "${DEFAULT_SERVICES[@]}")
    local active=$(echo "$status" | cut -d'|' -f1)
    
    if [[ -z "$active" ]]; then
        log "No development containers active (idempotent)"
        return 0
    fi
    
    log "Stopping development containers: $active"
    okteto down --namespace "$(oc project -q)" --all
    
    # Verify cleanup
    local remaining=$(check_dev_status "${DEFAULT_SERVICES[@]}" | cut -d'|' -f1)
    if [[ -n "$remaining" ]]; then
        warn "Cleanup failed for: $remaining"
        warn "Okteto bug - manually run:"
        for service in $remaining; do
            warn "  oc delete deployment ${service}-okteto secret okteto-${service} pvc ${service}-okteto"
        done
    else
        log "All development containers cleaned up"
    fi
}

okteto_exec() {
    [[ -z "$1" ]] && { error "Service name required"; exit 1; }
    local service="$1"; shift
    
    if ! oc get deployment "${service}-okteto" >/dev/null 2>&1; then
        error "Service '$service' not in development mode"
        error "Run: $0 up $service"
        exit 1
    fi
    
    okteto exec --namespace "$(oc project -q)" "$service" "$@"
}

show_help() {
    cat >&2 << EOF
Usage: okteto-dev.sh {up|down|check|exec} [services...]

Configuration:
  Set INSIGHTS_REPO_PATH environment variable to your local repo path
  Current: $INSIGHTS_REPO_PATH

Commands:
  up [services...]     - Start development (default: all host-inventory services)
  down                 - Stop all development containers  
  check [services...]  - Show development status
  exec <service> [cmd] - Execute command in development container

Examples:
  INSIGHTS_REPO_PATH=/path/to/repo okteto-dev.sh up     # Use custom repo path
  okteto-dev.sh up host-inventory-service               # Start specific service
  okteto-dev.sh check                                   # Show status
  okteto-dev.sh exec host-inventory-service             # Connect to container
  okteto-dev.sh down                                    # Stop all development
EOF
}

# Main function
main() {
    # Basic checks
    if ! oc whoami >/dev/null 2>&1; then
        error "Not logged into OpenShift"
        exit 1
    fi
    
    if ! command -v okteto >/dev/null 2>&1; then
        error "Okteto CLI not found"
        exit 1
    fi
    
    if [[ ! -f "okteto.yaml" ]]; then
        error "okteto.yaml not found in current directory"
        exit 1
    fi
    
    # Verify repo path exists
    if [[ ! -d "$INSIGHTS_REPO_PATH" ]]; then
        error "Insights repo path not found: $INSIGHTS_REPO_PATH"
        error "Set INSIGHTS_REPO_PATH environment variable to your local insights-host-inventory path"
        exit 1
    fi
    
    # Handle commands
    case "${1:-up}" in
        up)     shift; okteto_up "$@" ;;
        down)   okteto_down ;;
        check)  shift; show_status "$@" ;;
        exec)   shift; okteto_exec "$@" ;;
        -h|--help|help) show_help ;;
        *) error "Unknown command: $1"; show_help; exit 1 ;;
    esac
}

main "$@" 