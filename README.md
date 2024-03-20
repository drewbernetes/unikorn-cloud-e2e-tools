# Unikorn Cloud E2E Tools

This image pulls in [unikornctl](https://github.com/drewbernetes/unikornctl)
and [dogkat](https://github.com/drewbernetes/dogkat)
and wraps a bash script around it to enable to automation of creating a cluster, scanning it and then
deleting it.

This is useful for testing new releases of Unikorn Cloud or new images being built
by [baski](https://github.com/drewbernetes/baski) that would be used by Unikorn Cloud

## Development

To test the image works properly, you can build an image and run it to launch a cluster and run Dogkat:

```shell
docker build -t local/e2e-test:0.0.0 .
```

### Updating DogKat OR unikornctl

If you're updating `dogkat` or `unikorctl` then the version you're testing likely won't have been built and tagged yet.
If they have, then just do the above steps with the required adjustments in the `scripts/dogkat.yaml`
or `scripts/.unikornctl.yaml` files.

However, if as mentioned they're not built and tagged, then the below can be done.

#### Dogkat

Inside the [https://github.com/drewbernetes/dogkat](dogkat) repo:

```shell
helm package --app-version 0.1.x --version 0.1.x charts/dogkat -d /tmp/
CGO_ENABLED=0 go build -o "$BINARY_NAME" cmd/dogkat/main.go

```

Once done, copy the resulting build file into the `tests` directory

```shell

docker build -t local/e2e-test:0.0.0 -f tests/Dockerfile-test-dogkat .
```

Then update the `scripts/dogkat.yaml` as required ensuring the `chart.version` is 0.0.0

#### unikornctl

It's pretty much the same as the `dogkat` process, but you're building the `unikornctl` binary instead and no chart is
required. Once that's done and copied into the `tests` directory, you can build the docker image.

```shell
docker build -t local/e2e-test:0.0.0 -f tests/Dockerfile-test-dogkat .
```

#### DogKat & Unikornctl

If you're updating both, you can follow the steps for each except when it comes to building the image, you can build
against the `Dockerfile-test` Dockerfile.

#### Testing

In side whichever container you build, you can then run the following to test the process works as expected.


_Ensure you replace the variables as required_

**NOTE: _If you need to run multiple dogkat tests, it's wise to comment out the `deprovision_cluster` step in the `run-dogkat` command. That way you don't have to keep bringing clusters up after each run_**

```shell
docker run --rm -it -v /tmp/dogkat-0.1.x.tgz:/tmp/dogkat-0.1.x.tgz \
-e OS_USERNAME=<OPENSTACK_USER> \
-e OS_PASSWORD=<OPENSTACK_PASSWORD> \
-e OS_PROJECT_ID=<OPENSTACK_PROJECT_ID> \
-e CP_FLAVOR=<CONTROL_PANEL_FLAVOR> \
-e FLAVOR_NAME=<WORKER_FLAVOR> \
-e EXTERNAL_NETWORK_ID=<EXTERNAL_NETWORK_ID>
local/e2e-test:0.0.0

# Test unikornctl
/home/e2e-tools/run.sh build-cluster \
    --image-id SOME_IMAGE_ID \
    --unikorn-url https://unikorn.example.com \
    --app-bundle 1.4.2 \
    --push-gateway-url http://pushgateway.example.com \
    --enable-nvidia false

# Test dogkat (and unikorn ctl deprovision)
/home/e2e-tools/run.sh run-dogkat \
    --image-id SOME_IMAGE_ID\
    --enable-nvidia false \
    --domain example.com \
    --unikorn-url https://unikorn.example.com \
    --api-key CLOUDFLARE_API_KEY \
    --push-gateway-url http://pushgateway.example.com \
    --s3-endpoint S3_ENDPOINT \
    --s3-access-key S3_ACCESS_KEY \
    --s3-secret-key S3_SECRET_KEY
```
