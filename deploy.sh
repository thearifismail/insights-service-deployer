#!/bin/bash

set -e

login() {
  if [[ -z "${EPHEMERAL_TOKEN}" || -z "${EPHEMERAL_SERVER}" ]]; then
    [[ -z "${EPHEMERAL_TOKEN}" ]] && echo " - EPHEMERAL_TOKEN is not set"
    [[ -z "${EPHEMERAL_SERVER}" ]] && echo " - EPHEMERAL_SERVER is not set"
    exit 1
  fi

  echo "Login.."
  oc login --token="${EPHEMERAL_TOKEN}" --server=${EPHEMERAL_SERVER}
}

release_current_namespace() {
  echo "Releasing current environment.."
  login
  bonfire namespace release `oc project -q`
}

deploy() {
  login
  echo "Deploying..."
  HOST_GIT_COMMIT=$(echo $(git ls-remote https://github.com/RedHatInsights/insights-host-inventory HEAD) | cut -d ' ' -f1)
  HOST_FRONTEND_GIT_COMMIT=$(echo $(git ls-remote https://github.com/RedHatInsights/insights-inventory-frontend HEAD) | cut -d ' ' -f1 | cut -c1-7)
  bonfire deploy host-inventory -F true -p host-inventory/RBAC_V2_FORCE_ORG_ADMIN=true \
  -p host-inventory/URLLIB3_LOG_LEVEL=WARN \
  --ref-env insights-stage \
  -p host-inventory/CONSUMER_MQ_BROKER=rbac-kafka-kafka-bootstrap:9092  \
  --set-template-ref host-inventory="${HOST_GIT_COMMIT}"  \
  -p rbac/V2_APIS_ENABLED=True -p rbac/V2_READ_ONLY_API_MODE=False -p rbac/V2_BOOTSTRAP_TENANT=True \
  -p rbac/REPLICATION_TO_RELATION_ENABLED=True -p rbac/BYPASS_BOP_VERIFICATION=True \
  -p rbac/KAFKA_ENABLED=False -p rbac/NOTIFICATONS_ENABLED=False \
  -p rbac/NOTIFICATIONS_RH_ENABLED=False \
 -p rbac/ROLE_CREATE_ALLOW_LIST="remediations,\
inventory,\
policies,\
advisor,\
vulnerability,\
compliance,\
automation-analytics,\
notifications,\
patch,\
integrations,\
ros,\
staleness,\
config-manager,\
idmsvc" \
  --set-image-tag quay.io/cloudservices/insights-inventory=latest \
  --set-image-tag quay.io/cloudservices/insights-inventory-frontend="${HOST_FRONTEND_GIT_COMMIT}" \
  --set-image-tag quay.io/redhat-services-prod/hcc-platex-services/chrome-service=latest \
  --set-image-tag quay.io/redhat-services-prod/hcc-accessmanagement-tenant/insights-rbac=latest \
  -p host-inventory/BYPASS_RBAC=false \
  --set-image-tag quay.io/redhat-services-prod/rh-platform-experien-tenant/insights-rbac-ui=latest

  setup_debezium
}

setup_debezium() {
  echo "Debezium is setting up.."
  download_debezium_configuration
  cd scripts
  chmod 0700 kafka.sh
  ./kafka.sh -n `oc project -q`
  cd ..

  setup_kessel
}

setup_kessel() {
  echo "Kessel inventory is setting up.."
  bonfire deploy kessel -C kessel-inventory --set-image-tag quay.io/redhat-services-prod/project-kessel-tenant/kessel-inventory/inventory-api=latest

  setup_sink_connector
}

setup_sink_connector() {
  echo "Relations sink connector is setting up.."
  NAMESPACE=`oc project -q`
  BOOTSTRAP_SERVERS=$(oc get svc -n $NAMESPACE -o json | jq -r '.items[] | select(.metadata.name | test("^rbac-kafka.*-kafka-bootstrap")) | "\(.metadata.name).\(.metadata.namespace).svc"')
  RELATIONS_SINK_IMAGE=quay.io/cloudservices/kafka-relations-sink
  IMAGE_TAG=latest
  bonfire deploy kessel -C relations-sink-ephemeral \
   -p relations-sink-ephemeral/NAMESPACE=$NAMESPACE \
   -p relations-sink-ephemeral/RELATIONS_SINK_IMAGE=$RELATIONS_SINK_IMAGE \
   -p relations-sink-ephemeral/BOOTSTRAP_SERVERS=$BOOTSTRAP_SERVERS \
   -p relations-sink-ephemeral/IMAGE_TAG=$IMAGE_TAG
}

download_debezium_configuration() {
  RAW_BASE_URL="https://raw.githubusercontent.com/RedHatInsights/insights-rbac/master"
  FILES=(
    "deploy/kafka-connect.yml"
    "deploy/debezium-connector.yml"
    "scripts/kafka.sh"
    "scripts/connector-params.env"
  )

  RAW_BASE_URL="https://raw.githubusercontent.com/RedHatInsights/insights-rbac/master"

  # --- DOWNLOAD ---
  for FILE in "${FILES[@]}"; do
    TARGET="./$FILE"
    DIR_PATH=$(dirname "$TARGET")
    FILE_NAME=$(basename "$FILE")
    URL="$RAW_BASE_URL/$FILE"

    mkdir -p "$DIR_PATH"

    if [[ -f "$TARGET" ]]; then
      echo "Skipping $FILE_NAME (already exists)"
      continue
    fi

    echo "Downloading $FILE_NAME to $DIR_PATH"
    curl -sSL -o "$TARGET" "$URL"
    echo "Saved to $TARGET"
  done
}

clean_download_debezium_configuration() {
  rm -rf deploy
  rm -rf scripts
}

usage() {
  echo "Usage: $SCRIPT_NAME {release_current_namespace|deploy|clean_download_debezium_configuration}"
  exit 1
}

case "$1" in
  release_current_namespace)
    release_current_namespace
    ;;
  deploy)
    deploy
    ;;
  clean_download_debezium_configuration)
    clean_download_debezium_configuration
    ;;
  *)
    usage
    ;;
esac
