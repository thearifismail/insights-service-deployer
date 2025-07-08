#!/bin/bash

# Script to customize deployments for okteto development mode
# Usage: customize_deployments.sh <service_name> <operation>
# Operations: up, down
#
###########################################################################################################
# The ONLY reason you need to be here is if (for some unfortunate reason) you need to alter the deployment
# for okteto dev mode in a way that you can't do through the okteto manifest. (i.e. okteto.template.yaml)
#
# Normally, the deployment will be identical what is in your ClowdApp config for ephemeral.
###########################################################################################################

set -e

SERVICE_NAME="$1"
OPERATION="$2"

if [[ -z "$SERVICE_NAME" || -z "$OPERATION" ]]; then
    echo "Usage: $0 <service_name> <operation>"
    echo "Operations: up, down"
    exit 1
fi

# Helper functions
get_deployment_name() {
    local service="$1"
    echo "$service"  # Service name matches deployment name
}

get_container_name() {
    local deployment="$1"
    kubectl get deployment "$deployment" -o jsonpath='{.spec.template.spec.containers[0].name}' 2>/dev/null || echo "$deployment"
}

# Main logic
DEPLOYMENT=$(get_deployment_name "$SERVICE_NAME")

# Check if deployment exists
if ! kubectl get deployment "$DEPLOYMENT" &>/dev/null; then
    echo "⚠️  Deployment $DEPLOYMENT not found, skipping customization"
    exit 0
fi

case "$OPERATION" in
    "up")
        #############################################
        # UP BLOCK - Service startup customizations
        #############################################
        
        case "$SERVICE_NAME" in
            # MQ Services - need relaxed liveness probe settings because dev mode takes longer to come up and 
            # kubernetes decides to kill it because it runs out of time
            host-inventory-mq-p1|host-inventory-mq-pmin|host-inventory-mq-sp|host-inventory-mq-workspaces)
                CONTAINER=$(get_container_name "$DEPLOYMENT")
                
                echo "🔧 Patching deployment $DEPLOYMENT for relaxed liveness probe..."
                
                # Patch liveness probe with relaxed timing for MQ services
                # (Readiness probe is fine as-is since it only affects traffic routing)
                kubectl patch deployment "$DEPLOYMENT" \
                   -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$CONTAINER\",\"livenessProbe\":{\"initialDelaySeconds\":60,\"failureThreshold\":6,\"periodSeconds\":30}}]}}}}"
                
                echo "✅ Deployment $DEPLOYMENT patched with relaxed liveness probe settings"
                ;;
            
            # Add more services here as needed
            # new-service-name)
            #     echo "🔧 Customizing $SERVICE_NAME for development..."
            #     # Add custom logic here
            #     ;;
            
            *)
                echo "ℹ️  No customization defined for service: $SERVICE_NAME"
                ;;
        esac
        ;;
        
    "down")
        ###############################################
        # DOWN BLOCK - Service shutdown customizations  
        ###############################################
        
        case "$SERVICE_NAME" in
            # MQ Services - revert liveness probe settings
            host-inventory-mq-p1|host-inventory-mq-pmin|host-inventory-mq-sp|host-inventory-mq-workspaces)
                CONTAINER=$(get_container_name "$DEPLOYMENT")
                
                echo "🔄 Reverting deployment $DEPLOYMENT liveness probe to original settings..."
                
                # Explicitly restore original liveness probe settings (10s delay, 3 failures, 10s period)
                # This could drift out of date, but it's probably not a big deal, because a full ./okteto-dev.sh down
                # will restore the original settings for everything. We could also do nothing here.
                kubectl patch deployment "$DEPLOYMENT" \
                    -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$CONTAINER\",\"livenessProbe\":{\"initialDelaySeconds\":10,\"failureThreshold\":3,\"periodSeconds\":10}}]}}}}"
                
                echo "✅ Deployment $DEPLOYMENT liveness probe reverted to original settings"
                ;;
            
            # Add more services here as needed
            # new-service-name)
            #     echo "🔄 Cleaning up $SERVICE_NAME customizations..."
            #     # Add custom cleanup logic here
            #     ;;
            
            *)
                echo "ℹ️  No cleanup defined for service: $SERVICE_NAME"
                ;;
        esac
        ;;
        
    *)
        echo "❌ Invalid operation: $OPERATION"
        echo "Valid operations: up, down"
        exit 1
        ;;
esac 