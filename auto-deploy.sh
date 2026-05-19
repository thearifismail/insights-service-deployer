#!/bin/bash

#############################################################################
# Auto-Deploy Script for Host Inventory Ephemeral Environment
#############################################################################
# This script automates the following workflow:
# 1. Login to Ephemeral cluster
# 2. Reserve a new namespace
# 3. Deploy host-inventory with its dependencies (Kessel, RBAC)
# 4. Setup port-forwarding for services
# 5. Retrieve database credentials and Unleash token
# 6. Update .env file with database credentials, Unleash token, and Kessel auth
# 7. Update /etc/hosts with Kafka bootstrap server
# 8. Save outputs to tmp directory
#############################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Directories
DEPLOYER_DIR="/Users/aarif/Documents/dev-ws/insights/insights-service-deployer"
HBI_DIR="/Users/aarif/Documents/dev-ws/insights/insights-host-inventory"
TMP_DIR="$HBI_DIR/tmp"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Log function
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

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    local missing_deps=()

    command -v oc >/dev/null 2>&1 || missing_deps+=("oc")
    command -v bonfire >/dev/null 2>&1 || missing_deps+=("bonfire")
    command -v kubectl >/dev/null 2>&1 || missing_deps+=("kubectl")

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please install the missing dependencies and try again."
        exit 1
    fi

    # Try to get token and server from current oc session first
    if [[ -z "${EPHEMERAL_TOKEN}" ]]; then
        log "EPHEMERAL_TOKEN not set, attempting to get from current oc session..."
        EPHEMERAL_TOKEN=$(oc whoami -t 2>/dev/null || true)
        if [[ -n "${EPHEMERAL_TOKEN}" ]]; then
            log_success "Got EPHEMERAL_TOKEN from current oc session"
            export EPHEMERAL_TOKEN
        fi
    fi

    if [[ -z "${EPHEMERAL_SERVER}" ]]; then
        log "EPHEMERAL_SERVER not set, attempting to get from current oc session..."
        EPHEMERAL_SERVER=$(oc whoami --show-server 2>/dev/null || true)
        if [[ -n "${EPHEMERAL_SERVER}" ]]; then
            log_success "Got EPHEMERAL_SERVER from current oc session"
            export EPHEMERAL_SERVER
        fi
    fi

    # Final validation
    if [[ -z "${EPHEMERAL_TOKEN}" ]]; then
        log_error "EPHEMERAL_TOKEN is not set and could not be retrieved from oc session"
        log "Please login to the cluster first, or set EPHEMERAL_TOKEN manually"
        log "Get token from: https://oauth-openshift.apps.crc-eph.r9lp.p1.openshiftapps.com/oauth/token/request"
        exit 1
    fi

    if [[ -z "${EPHEMERAL_SERVER}" ]]; then
        log_error "EPHEMERAL_SERVER is not set and could not be retrieved from oc session"
        log "Please login to the cluster first, or set EPHEMERAL_SERVER manually"
        log "Usually: https://api.crc-eph.r9lp.p1.openshiftapps.com:6443"
        exit 1
    fi

    log_success "All prerequisites satisfied"
    log "Using server: $EPHEMERAL_SERVER"
}

# Function to login to ephemeral cluster
login_to_cluster() {
    log "Logging into Ephemeral cluster..."

    # Check if already logged in
    user="$(oc whoami 2>/dev/null || true)"
    if [[ -n "$user" ]]; then
        log_warning "Already logged in as user: $user"
        return 0
    fi

    if oc login --token="${EPHEMERAL_TOKEN}" --server="${EPHEMERAL_SERVER}"; then
        log_success "Successfully logged into Ephemeral cluster"
    else
        log_error "Failed to login to Ephemeral cluster"
        exit 1
    fi
}

# Function to reserve namespace
reserve_namespace() {
    log "Checking current namespace..."

    NAMESPACE=$(oc project -q 2>/dev/null || true)

    if [[ -z "$NAMESPACE" || "$NAMESPACE" == "default" ]]; then
        log "No bonfire namespace set or using 'default', reserving a new namespace..."

        # Parse duration argument
        DURATION="${1:-10h}"
        log "Reserving namespace for duration: $DURATION"

        if bonfire namespace reserve --duration "$DURATION"; then
            NAMESPACE=$(oc project -q)
            log_success "Reserved namespace: $NAMESPACE"
        else
            log_error "Failed to reserve namespace"
            exit 1
        fi
    else
        log_warning "Using existing namespace: $NAMESPACE"

        # Check if force flag is set
        if [[ "$FORCE_USE_EXISTING" == "true" ]]; then
            log_success "Force flag set, continuing with existing namespace"
        else
            read -p "Do you want to continue with this namespace? (y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log "Aborting deployment"
                exit 0
            fi
        fi
    fi

    # Export namespace for use in other functions
    export PROJECT_NAMESPACE="$NAMESPACE"
}

# Function to deploy services
deploy_services() {
    log "Starting deployment of host-inventory and dependencies..."

    cd "$DEPLOYER_DIR" || {
        log_error "Failed to change to deployer directory: $DEPLOYER_DIR"
        exit 1
    }

    # Run deploy with demo data
    log "Running deployment with demo data (deploy_with_hbi_demo)..."

    if ./deploy.sh deploy_with_hbi_demo "$@"; then
        log_success "Deployment completed successfully"
    else
        log_error "Deployment failed"
        exit 1
    fi
}

# Function to setup port forwarding
setup_port_forwarding() {
    log "Setting up port-forwarding for services..."

    cd "$HBI_DIR" || {
        log_error "Failed to change to HBI directory: $HBI_DIR"
        exit 1
    }

    # Create tmp directory if it doesn't exist
    mkdir -p "$TMP_DIR"

    # Run port-forwarding script
    local port_forward_output="$TMP_DIR/ephemeral_ports.log"

    if bash ./docs/set_hbi_rbac_ports.sh "$PROJECT_NAMESPACE" | tee "$port_forward_output"; then
        log_success "Port-forwarding setup completed"
        log_success "Port-forwarding log saved to: $port_forward_output"
    else
        log_error "Port-forwarding setup failed"
        exit 1
    fi
}

# Function to get database credentials
get_db_credentials() {
    log "Retrieving database credentials..."

    cd "$HBI_DIR" || {
        log_error "Failed to change to HBI directory: $HBI_DIR"
        exit 1
    }

    # Create tmp directory if it doesn't exist
    mkdir -p "$TMP_DIR"

    # Run credentials script
    local creds_output="$TMP_DIR/ephemeral_db_credentials.log"

    if bash ./docs/get_hbi_rbac_db_creds.sh "$PROJECT_NAMESPACE" | tee "$creds_output"; then
        log_success "Database credentials retrieved"
        log_success "Credentials saved to: $creds_output"
    else
        log_error "Failed to retrieve database credentials"
        exit 1
    fi
}

# Function to fetch UNLEASH_TOKEN from Kubernetes secret
fetch_unleash_token_from_server() {
    log "Fetching UNLEASH_TOKEN from Kubernetes secret..."

    local namespace="${1:-$PROJECT_NAMESPACE}"

    # Determine the featureflags secret name based on namespace
    local secret_name="env-${namespace}-featureflags"

    # Try the namespace-based secret first, then fall back to unleash-proxy
    local client_token=""
    if oc get secret "$secret_name" >/dev/null 2>&1; then
        client_token=$(oc get secret "$secret_name" -o jsonpath='{.data.clientAccessToken}' 2>/dev/null | base64 -d)
    elif oc get secret unleash-proxy >/dev/null 2>&1; then
        client_token=$(oc get secret unleash-proxy -o jsonpath='{.data.cdappconfig\.json}' 2>/dev/null | base64 -d | jq -r '.featureFlags.clientAccessToken // empty')
    fi

    if [[ -z "$client_token" || "$client_token" == "null" ]]; then
        log_error "Failed to extract clientAccessToken from featureflags secret"
        log_error "Tried secrets: $secret_name, unleash-proxy in namespace: $namespace"
        return 1
    fi

    log_success "Successfully retrieved client API token from Kubernetes secret"
    log "  Token format: ${client_token:0:30}..."

    # Export token for use by caller
    # Use localhost:4242/api since port-forwarding will be used for local development
    UNLEASH_TOKEN="$client_token"
    UNLEASH_URL="http://localhost:4242/api"

    return 0
}

# Function to setup Kessel auth (OIDC client) via Keycloak and update .env
setup_kessel_auth() {
    log "Setting up Kessel authentication via Keycloak..."

    local env_file="$HBI_DIR/.env"
    local namespace="${PROJECT_NAMESPACE}"
    local env_namespace="env-${namespace}"
    local client_id="host-inventory"

    # Get Keycloak admin credentials from secret
    local admin_user admin_pass
    admin_user=$(oc get secret "${env_namespace}-keycloak" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d) || true
    admin_pass=$(oc get secret "${env_namespace}-keycloak" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d) || true

    if [[ -z "$admin_user" || -z "$admin_pass" ]]; then
        log_error "Failed to retrieve Keycloak admin credentials from secret: ${env_namespace}-keycloak"
        return 1
    fi
    log "  Keycloak admin user: $admin_user"

    # Get Keycloak route URL
    local keycloak_url
    keycloak_url=$(oc get route -l app=${env_namespace} -o json | jq -r '.items[] | select(.metadata.name | contains("auth")) | select(.spec.port.targetPort == "keycloak").spec.host') || true

    if [[ -z "$keycloak_url" ]]; then
        log_error "Failed to find Keycloak route"
        return 1
    fi
    log "  Keycloak URL: https://$keycloak_url"

    # Get admin access token
    local token
    token=$(curl -s -X POST "https://${keycloak_url}/auth/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${admin_user}" \
        -d "password=${admin_pass}" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" | jq -r '.access_token')

    if [[ -z "$token" || "$token" == "null" ]]; then
        log_error "Failed to obtain Keycloak admin token"
        return 1
    fi
    log_success "Obtained Keycloak admin token"

    # Create the OIDC client (ignore 409 if it already exists)
    local create_status
    create_status=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "https://${keycloak_url}/auth/admin/realms/redhat-external/clients" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d '{
          "clientId": "'"${client_id}"'",
          "enabled": true,
          "serviceAccountsEnabled": true,
          "publicClient": false,
          "clientAuthenticatorType": "client-secret",
          "standardFlowEnabled": false,
          "directAccessGrantsEnabled": false,
          "protocol": "openid-connect"
        }')

    if [[ "$create_status" == "201" ]]; then
        log_success "Created Keycloak client: $client_id"
    elif [[ "$create_status" == "409" ]]; then
        log_warning "Keycloak client '$client_id' already exists (reusing)"
    else
        log_error "Failed to create Keycloak client (HTTP $create_status)"
        return 1
    fi

    # Get the internal UUID for the client
    local internal_client_id
    internal_client_id=$(curl -s "https://${keycloak_url}/auth/admin/realms/redhat-external/clients" \
        -H "Authorization: Bearer ${token}" | jq -r '.[] | select(.clientId=="'"${client_id}"'") | .id')

    if [[ -z "$internal_client_id" || "$internal_client_id" == "null" ]]; then
        log_error "Failed to find internal UUID for client: $client_id"
        return 1
    fi

    # Get the client secret
    local client_secret
    client_secret=$(curl -s "https://${keycloak_url}/auth/admin/realms/redhat-external/clients/${internal_client_id}/client-secret" \
        -H "Authorization: Bearer ${token}" | jq -r '.value')

    if [[ -z "$client_secret" || "$client_secret" == "null" ]]; then
        log_error "Failed to retrieve client secret"
        return 1
    fi

    # Get the OIDC issuer URL
    local issuer_url
    issuer_url=$(curl -s "https://${keycloak_url}/auth/realms/redhat-external/.well-known/openid-configuration" | jq -r '.issuer')

    if [[ -z "$issuer_url" || "$issuer_url" == "null" ]]; then
        log_error "Failed to retrieve OIDC issuer URL"
        return 1
    fi

    log_success "Kessel auth credentials retrieved:"
    log "  KESSEL_AUTH_CLIENT_ID: $client_id"
    log "  KESSEL_AUTH_CLIENT_SECRET: ${client_secret:0:8}..."
    log "  KESSEL_AUTH_OIDC_ISSUER: $issuer_url"

    # Update .env file
    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found: $env_file"
        return 1
    fi

    # Use localhost URL for OIDC issuer since port-forwarding is used for local dev.
    # Keycloak is typically port-forwarded on 8180.
    local local_issuer_url="http://localhost:8180/auth/realms/redhat-external"

    sed -i '' "s|^KESSEL_AUTH_CLIENT_ID=.*|KESSEL_AUTH_CLIENT_ID=\"$client_id\"|" "$env_file"
    sed -i '' "s|^KESSEL_AUTH_CLIENT_SECRET=.*|KESSEL_AUTH_CLIENT_SECRET=\"$client_secret\"|" "$env_file"
    sed -i '' "s|^KESSEL_AUTH_OIDC_ISSUER=.*|KESSEL_AUTH_OIDC_ISSUER=\"$local_issuer_url\"|" "$env_file"

    log_success "Kessel auth credentials updated in .env"
}

# Function to update .env file with database credentials
update_env_file() {
    log "Updating .env file with database credentials..."

    local env_file="$HBI_DIR/.env"
    local creds_file="$TMP_DIR/ephemeral_db_credentials.log"

    # Check if credentials file exists
    if [[ ! -f "$creds_file" ]]; then
        log_error "Credentials file not found: $creds_file"
        return 1
    fi

    # Check if .env file exists
    if [[ ! -f "$env_file" ]]; then
        log_error ".env file not found: $env_file"
        return 1
    fi

    # Extract credentials from log file
    local db_user=$(grep "INVENTORY_DB_USER:" "$creds_file" | awk '{print $2}')
    local db_pass=$(grep "INVENTORY_DB_PASS:" "$creds_file" | awk '{print $2}')
    local db_name=$(grep "INVENTORY_DB_NAME:" "$creds_file" | awk '{print $2}')

    # Validate that we got all the values
    if [[ -z "$db_user" || -z "$db_pass" || -z "$db_name" ]]; then
        log_error "Failed to extract all database credentials from $creds_file"
        log_error "  INVENTORY_DB_USER: ${db_user:-NOT FOUND}"
        log_error "  INVENTORY_DB_PASS: ${db_pass:-NOT FOUND}"
        log_error "  INVENTORY_DB_NAME: ${db_name:-NOT FOUND}"
        return 1
    fi

    log "Found credentials:"
    log "  INVENTORY_DB_USER: $db_user"
    log "  INVENTORY_DB_PASS: $db_pass"
    log "  INVENTORY_DB_NAME: $db_name"

    # Create a backup of the .env file
    cp "$env_file" "$env_file.backup"
    log "Created backup: $env_file.backup"

    # Update the .env file using sed (macOS compatible)
    sed -i '' "s/^INVENTORY_DB_USER=.*/INVENTORY_DB_USER=$db_user/" "$env_file"
    sed -i '' "s/^INVENTORY_DB_PASS=.*/INVENTORY_DB_PASS=$db_pass/" "$env_file"
    sed -i '' "s/^INVENTORY_DB_NAME=.*/INVENTORY_DB_NAME=$db_name/" "$env_file"

    log_success ".env file updated with database credentials"
    log "Updated values in $env_file:"
    log "  INVENTORY_DB_USER=$db_user"
    log "  INVENTORY_DB_PASS=$db_pass"
    log "  INVENTORY_DB_NAME=$db_name"

    # Fetch Unleash token from server
    update_unleash_token_in_env "$env_file"

    # Setup Kessel auth (OIDC client via Keycloak)
    setup_kessel_auth || log_warning "Kessel auth setup failed - you may need to configure KESSEL_AUTH_* manually"
}

# Function to update Unleash token in .env file
update_unleash_token_in_env() {
    local env_file="$1"

    log "Updating Unleash token in .env file..."

    # Fetch token from Unleash server
    if fetch_unleash_token_from_server; then
        log_success "Successfully fetched Unleash token from server"

        # Update the .env file with the new token
        sed -i '' "s|^UNLEASH_TOKEN=.*|UNLEASH_TOKEN='$UNLEASH_TOKEN'|" "$env_file"
        sed -i '' "s|^UNLEASH_URL=.*|UNLEASH_URL=\"$UNLEASH_URL\"|" "$env_file"

        log_success "Unleash configuration updated in .env"
        log "  UNLEASH_TOKEN: ${UNLEASH_TOKEN:0:40}..."
        log "  UNLEASH_URL: $UNLEASH_URL"
    else
        log_error "Failed to fetch Unleash token from server"
        log_warning "Falling back to credentials file if available..."

        # Fallback: Try to extract from credentials file
        local creds_file="$TMP_DIR/ephemeral_db_credentials.log"
        local unleash_token=$(grep "UNLEASH_TOKEN:" "$creds_file" 2>/dev/null | awk '{print $2}')
        local unleash_url=$(grep "UNLEASH_URL:" "$creds_file" 2>/dev/null | awk '{print $2}')

        if [[ -n "$unleash_token" && -n "$unleash_url" ]]; then
            log "Found Unleash configuration in credentials file:"
            log "  UNLEASH_TOKEN: ${unleash_token:0:40}..."
            log "  UNLEASH_URL: $unleash_url"

            sed -i '' "s|^UNLEASH_TOKEN=.*|UNLEASH_TOKEN='$unleash_token'|" "$env_file"
            sed -i '' "s|^UNLEASH_URL=.*|UNLEASH_URL=\"$unleash_url\"|" "$env_file"

            log_success "Unleash configuration updated from credentials file"
        else
            log_warning "Unleash configuration not found in credentials file either"
            log_warning "Feature flags may not work correctly"
        fi
    fi
}

# Function to update /etc/hosts with ephemeral environment
# Assuming sudo is configured for the user and does not require a password
update_etc_hosts_file() {
    log "Updating /etc/hosts with ephemeral environment details..."

    # Extract environment ID from namespace (e.g., ephemeral-ijl7bd -> ijl7bd)
    local env_id="${PROJECT_NAMESPACE#ephemeral-}"

    if [[ -z "$env_id" || "$env_id" == "$PROJECT_NAMESPACE" ]]; then
        log_error "Could not extract environment ID from namespace: $PROJECT_NAMESPACE"
        log_error "Expected format: ephemeral-<id>"
        return 1
    fi

    log "Environment ID: $env_id"

    # Check if we can run sudo without password
    if ! sudo -n true 2>/dev/null; then
        log_error "Passwordless sudo is required to update /etc/hosts"
        log_error "Please configure passwordless sudo and try again"
        return 1
    fi

    # Backup /etc/hosts
    local backup_file="/tmp/hosts.backup.$(date +%Y%m%d_%H%M%S)"
    sudo cp /etc/hosts "$backup_file"
    log "Created backup of /etc/hosts: $backup_file"

    # Get the current ephemeral ID from /etc/hosts (if it exists)
    local current_env_id=$(grep -oE 'ephemeral-[a-z0-9]+' /etc/hosts | head -1 | sed 's/ephemeral-//')

    if [[ -n "$current_env_id" && "$current_env_id" != "$env_id" ]]; then
        log "Replacing old environment ID '$current_env_id' with new ID '$env_id'"

        # Replace all occurrences of the old environment ID with the new one
        sudo sed -i '' "s/$current_env_id/$env_id/g" /etc/hosts

        log_success "/etc/hosts updated successfully"
        log "Old environment: ephemeral-$current_env_id"
        log "New environment: ephemeral-$env_id"
    else
        log_warning "No existing ephemeral environment found in /etc/hosts or ID matches current namespace"
        log "You may need to manually add ephemeral entries to /etc/hosts"
    fi

    # Display the current ephemeral entries
    log "Current ephemeral entries in /etc/hosts:"
    grep -i "ephemeral" /etc/hosts || log_warning "No ephemeral entries found"
}

# Function to display summary
display_summary() {
    echo ""
    echo "========================================================================"
    echo -e "${GREEN}Deployment Complete!${NC}"
    echo "========================================================================"
    echo ""
    echo "Namespace: $PROJECT_NAMESPACE"
    echo ""
    echo "Outputs saved to: $TMP_DIR"
    echo "  - Port forwarding log: ephemeral_ports.log"
    echo "  - Database credentials: ephemeral_db_credentials.log"
    echo ""
    echo "Port Forwards Active:"
    echo "  - Host Inventory API:     http://localhost:8000"
    echo "  - RBAC Service:           http://localhost:8111"
    echo "  - Kessel Inventory API:   http://localhost:8222"
    echo "  - Kessel Relations API:   http://localhost:8333"
    echo "  - Kafka Bootstrap:        localhost:9092, localhost:29092"
    echo "  - Kafka Connect:          http://localhost:8083"
    echo "  - Feature Flags:          http://localhost:4242"
    echo "  - HBI Database:           localhost:5432"
    echo "  - RBAC Database:          localhost:5433"
    echo "  - Kessel Database:        localhost:5434"
    echo ""
    echo "Updated Files:"
    echo "  - $HBI_DIR/.env (database credentials, Unleash token, Kessel auth)"
    echo "  - /etc/hosts (Kafka bootstrap server)"
    echo ""
    echo "To view namespace details:"
    echo "  bonfire namespace describe"
    echo ""
    echo "To release namespace when done:"
    echo "  bonfire namespace release $PROJECT_NAMESPACE"
    echo ""
    echo "You can now run tests locally with:"
    echo "  cd $HBI_DIR"
    echo "  pipenv run pytest tests/"
    echo ""
    echo "========================================================================"
}

# Function to handle cleanup on error
cleanup_on_error() {
    log_error "Script failed. Cleaning up..."
    # Add any cleanup logic here if needed
    exit 1
}

# Trap errors
trap cleanup_on_error ERR

# Main execution
main() {
    echo ""
    echo "========================================================================"
    echo "  Auto-Deploy Script for Host Inventory Ephemeral Environment"
    echo "========================================================================"
    echo ""

    # Parse command-line arguments
    NAMESPACE_DURATION="335h"
    FORCE_USE_EXISTING="false"
    DEPLOY_ARGS=()

    while [[ $# -gt 0 ]]; do
        case $1 in
            --duration)
                NAMESPACE_DURATION="$2"
                shift 2
                ;;
            --force)
                FORCE_USE_EXISTING="true"
                shift
                ;;
            --help)
                echo "Usage: $0 [OPTIONS] [DEPLOY_ARGS...]"
                echo ""
                echo "Options:"
                echo "  --duration DURATION    Namespace reservation duration (default: 10h)"
                echo "  --force                Use existing namespace without prompting"
                echo "  --help                 Show this help message"
                echo ""
                echo "Deploy Arguments (passed to deploy.sh deploy_with_hbi_demo):"
                echo "  [template_ref]         Git ref for host-inventory deploy template"
                echo "  [image]                Custom host-inventory image"
                echo "  [tag]                  Custom image tag"
                echo "  [schema_file]          Path to local SpiceDB schema file"
                echo ""
                echo "Examples:"
                echo "  $0"
                echo "  $0 --force"
                echo "  $0 --duration 8h"
                echo "  $0 --force main quay.io/myrepo/inventory v1.0"
                echo ""
                exit 0
                ;;
            *)
                DEPLOY_ARGS+=("$1")
                shift
                ;;
        esac
    done

    # Export force flag for use in reserve_namespace function
    export FORCE_USE_EXISTING

    # Execute workflow
    check_prerequisites
    login_to_cluster
    reserve_namespace "$NAMESPACE_DURATION"
    deploy_services "${DEPLOY_ARGS[@]}"
    setup_port_forwarding
    get_db_credentials
    update_env_file
    update_etc_hosts_file
    display_summary

    log_success "All tasks completed successfully!"
}

# Run main function
main "$@"
