# insights-service-deployer


## Deploy rbac, HBI service and the Kessel stack with dedicated kafka connect stack (debezium included)


```
git clone git@github.com:project-kessel/insights-service-deployer.git
export EPHEMERAL_TOKEN=<> # get token from ephemeral cluster
export EPHEMERAL_SERVER=<> # get server from ephemeral cluster
./deploy.sh deploy
```

### Debugging

If the deploy looks like it's hanging, check with `oc get pods` to ensure that
no pod is crash looping. A common source of error is that pods are stuck in `ImagePullBackOff`
due to Konflux referencing an image that doesn't exist yet. (The script tries to
tackle this to some degree by requesting `latest` image tags and soon by checking if tags exist.)

## Demo steps for HBI & rbac end-to-end flow with kessel from console

These are the additional steps to get an end-to-end flow from the HBI 
and rbac consoles such that workspaces and hosts can be created and 
access managed with rbac and queried with kessel.

(We are in the process of automating the below steps.)

1. Ensure the deploy.sh script has run correctly, above.
2. Create test hosts in HBI:
```shell
# To populate hosts in a WS - note change the pod name
oc exec -it host-inventory-service-reads-78689bfb96-qhnpr -- /bin/bash
# Note: grab the Kafka-bootstrap from NS->service and change it below
NUM_HOSTS=10 KAFKA_BOOTSTRAP_SERVERS=env-ephemeral-7cks0f-da03ec58-kafka-bootstrap.ephemeral-7cks0f.svc:9092 python3 utils/kafka_producer.py
```
3. Assign hosts to the correct org:
```shell
oc exec -it host-inventory-db-9f6f46699-gwncm -- /bin/bash
psql
\c host-inventory
UPDATE hbi.hosts SET org_id='12345'
```
4. Login to console:
```shell
bonfire namespace describe

will give a gaterway URL wit jdoe|<password>
```
5. Run some checks. e.g. create a workspace in the HBI and check that it replicates into spicedb.

### Notes

1. The script sets unleash features flags as per `unleash/unleash_project.json`. It will build and deploy
an image with those feature flags and apply them with bonfire. (If you are not logged into podman it will just 
use/deploy whatever flags are in `quay.io/mmclaugh/kessel-unleash-import` instead.)

### Checks
To check unleash feature flags manually:
```shell
Log in to Unleash at `localhost:4242` with the creds:

  -   user: admin
  -   pass: unleash4all
e.g. check that the `hbi.api.kessel-workspace-migration` in Unleash is on.
```