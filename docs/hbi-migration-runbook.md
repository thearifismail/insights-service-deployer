This document describes how to test the HBI migration in the ephemeral environment.

## Prerequisites

- `oc` is installed
- `jq` is installed
- `psql` is installed
- You have access to the ephemeral environment.
- You have cloned the [insights service deployer repository](https://github.com/project-kessel/insights-service-deployer)
- You have cloned the [db-generator repository](https://github.com/tonytheleg/db-generator) - this repo is private and **requires access**
    - This repo generates host and outbox HBI records for insertion into the ephemeral environment database

## Steps

### Base Environment Setup

Login to the ephemeral environment.
```bash
oc login --token=<token> --server=<ephemeral-environment-api-url>
```

Via `insights-service-deployer`, deploy the components to the ephemeral environment.
```bash
./deploy.sh deploy_with_hbi_demo
```

> [!IMPORTANT]
> When the deployer script completes, it provides some URL's and auth information for testing purposes. Make sure to capture this info if you intend to test host deletion with the outbox as you'll need it to access the Console UI.

Once completed, add the kessel kafka infra
```bash
./deploy.sh host-replication-kafka
```

### Generate & Insert HBI records

By using the `deploy_with_hbi_demo` option, 10 hosts are automatically created during setup. This is sufficient enough for basic migration testing, but may not be suitable for larger host migration tests.

If you don't have host data already generated, generate it from the `db-generator` repository.

The following generates 10 host files with 1000 host records each (hosts are counted in hundreds and multiplied by the number of files). This means the following command will generate 10,000 host records total.

```bash
go run main.go --num-hosts 10 --num-files 10 --type hosts
```

Grab the host-inventory-db database `user` secret from the ephemeral environment.
```bash
oc get secrets host-inventory-db -o json | jq '.data["db.user"]' -r | base64 -d
```

Now port forward to the host-inventory database, host-inventory-db is the svc name
```bash
oc port-forward service/host-inventory-db 5433:5432
```

Next, insert the HBI records into the ephemeral environment database.
```bash
psql -h localhost -p 5433 -U <user> -d host-inventory -f <path-to-generated-host-file>
```

You can validate the records are inserted by checking the `host-inventory` database:
```bash
psql -h localhost -p 5433 -U <user> -d host-inventory -c "select count(*) from hbi.hosts" -x
```

### Start the Migration

To start the HBI migration, you just need to set the host migration connector to `running`

```bash
oc patch kafkaconnector "hbi-migration-connector" --type='merge' -p='{"spec":{"state":"running"}}'
```

### Validating the Migration

To validate the migration, you can check the `kessel-inventory-consumer` pod logs for the following message:
```bash
INFO ts=2025-08-06T18:10:20Z caller=log/log.go:30 service.name=inventory-consumer service.version=0.1.0 trace.id= span.id= subsystem=inventoryConsumer msg=consumed event from topic host-inventory.hbi.hosts, partition 0 at offset 999
```

To validate database records, you can port-forward and check the `kessel-inventory` database for the following records:

**Get the number of resources in the kessel-inventory database**
```bash
psql -h localhost -p <local_port> -U <user> -d kessel-inventory -c "select count(*) from reporter_resources" -x
```

**Check for resources in the kessel-inventory database that do not have a consistency token (should be 0 when migration is complete)**
```bash
psql -h localhost -p <local_port> -U <user> -d kessel-inventory -c "select count(*) from resource where ktn != ''" -x
```

### Outbox Replication

To validate outbox replication, you can do the same process with a couple of changes
1. Set the outbox connector to `running` first
```bash
oc patch kafkaconnector "hbi-outbox-connector" --type='merge' -p='{"spec":{"state":"running"}}'
```
2. Generate outbox records by either creating new hosts with `add_hosts_to_hbi` flag or via the `db-generator` repository using the `--type outbox` flag

Once you make those changes, you can insert and validate the outbox records are flowing through the same means as the host migration.

### Testing Host Deletion Replication

To test that deleting a host in HBI properly replicates to Kessel, the easiest method is to access the Development Console UI provided by the deployer and delete in browser

To Delete a Host via UI:
1. Access the dev Console using the `Gateway route` URL provided by the deployer script
2. Login using the `jdoe` user and the provided credentials from the deployer script
3. Click the Services Drop down menu (button says Red Hat Hybrid Cloud Console) and select **Inventories** --> **Inventory** --> **Systems**
4. Click on the host to delete
5. Capture the UUID of the host for validation
6. Click the **Delete** button to delete the host

This will trigger an outbox write which will be captured by the Inventory Consumer and replicated down to Inventory API.

To validate the removal of the host in Inventory, query the Inventory DB for the host

elect * from reporter_resources where local_resource_id = '45e70917-eb1b-46a5-a4af-d693f726498e';

`psql -h localhost -p <local_port> -U <user> -d kessel-inventory -c "select * from reporter_resources where local_resource_id = '<UUID_FROM_CONSOLE_UI>'" -x`

### Resetting the Migration

The easiest way to reset your environment is to `bonfire namespace release` and redeploy from the beginning.

If you are feeling adventurous you can use the `scripts/migration-cleanup.sh` via `insights-service-deployer` to clean up the database and kafka infra. But you will need to redeploy the deleted components manually.

### Troubleshooting

#### Debezium Connector Logs

You can inspect the Debezium connector logs to see if there are any errors snapshotting the HBI table. You will see a Java stack trace if there are any errors. Typically searching by the "Snapshot" keyword will help you find the relevant logs.

```bash
oc logs -f kessel-kafka-connect-connect-0
```

#### Kafka Messages
If you'd like to inspect kafka messages, you can use the following commands...

Note: `KAFKA_CONNECT_BOOTSTRAP_SERVERS` is already set inside the connect pod.

```bash
> oc rsh kessel-kafka-connect-connect-0

# Host migration events
> ./bin/kafka-console/consumer.sh --bootstrap-server $KAFKA_CONNECT_BOOTSTRAP_SERVERS --topic host-inventory.hbi.hosts --property print.key=true --property print.headers=true --from-beginning

 OR

# Outbox events
> ./bin/kafka-console/consumer.sh --bootstrap-server $KAFKA_CONNECT_BOOTSTRAP_SERVERS --topic outbox.event.hbi.hosts --property print.key=true --property print.headers=true --from-beginning
```

