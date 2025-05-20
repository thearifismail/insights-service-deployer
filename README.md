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
./deploy.sh add_hosts_to_hbi # adds 10 hosts with org_id 12345 by default
```
or
```shell
./deploy.sh add_hosts_to_hbi 12345 # adds 10 hosts by default with org_id 12345
```
or
```shell
./deploy.sh add_hosts_to_hbi 12345 10 # adds 10 hosts with org_id 12345
```
3. Login to console:
```shell
bonfire namespace describe

will give a gaterway URL wit jdoe|<password>
```
4. Run some checks. e.g. create a workspace in the HBI and check that it replicates into spicedb.

### Notes

#### Unleash Feature Flags Script

1. The script sets Unleash feature flags based on `unleash/unleash_project.json`.  
   It then builds and deploys an image with these feature flags and applies them using **bonfire**.

#### Possible scenarios

#### A. Not Logged into Podman 
(recommended if you don't need to set up your own feature flags)

- The script will use the image from `quay.io/mmclaugh/kessel-unleash-import`, which already contains the feature flags.

#### B. Logged into Podman

- The script will create a repository named `kessel-unleash-import` in **your quay account**.
- **Note:** This may fail the first time — you need to **make the repository public** manually.


### Checks
To check unleash feature flags manually:
```shell
Log in to Unleash at `localhost:4242` with the creds:

  -   user: admin
  -   pass: unleash4all
e.g. check that the `hbi.api.kessel-workspace-migration` in Unleash is on.
```