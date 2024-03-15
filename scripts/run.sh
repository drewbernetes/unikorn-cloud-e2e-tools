#!/bin/bash

declare IMAGE_NAME IMAGE_VERS CN enable_nvidia enable_amd

enable_amd=false
enable_nvidia=false

CP="image-build"

# Check for a successful command exit code
function checkForSuccess {
    r=$1
    if [ $r -ne 0 ]; then
      printf "An error occurred: %s\n" "$3"
      if [ "$2" != "deprovision_cluster" ] && [ "$2" != "provision_cluster" ]; then
        deprovision_cluster
      fi

      exit 1
    fi
}

# Prepare the unikornctl auth file
function prepare_unikornctl {
  password="${OS_PASSWORD//\\/\\\\}"    # Escape backslashes
  password="${password//\//\\/}"   # Escape forward slashes
  password="${password//&/\\&}"    # Escape ampersands
  password="${password//\$/\\$}"   # Escape dollar signs
    sed -e "s|OS_USERNAME|${OS_USERNAME}|g" \
        -e "s|OS_PASSWORD|${password}|g" \
        -e "s|UNIKORN_URL|${unikorn_url}|g" \
        -e "s|OS_PROJECT_ID|${OS_PROJECT_ID}|g" \
        -i $HOME/.unikornctl.yaml
}

# Set some initial vars
function set_vars {
    IMAGE=$(unikornctl get image --id "${image_id}")
    IMAGE_NAME=$(echo ${IMAGE} | awk '{print $2}')
    IMAGE_VERS=$(echo ${IMAGE} | awk '{print $12}')
    CN="${IMAGE_NAME}-testing"
}

# Prepare the cluster.json for unikornctl
function prepare_cluster_build {
    sed -e "s|APP_BUNDLE|${app_bundle}|g" \
        -e "s|EXTERNAL_NETWORK_ID|${EXTERNAL_NETWORK_ID}|g" \
        -e "s|IMAGE_VERS|${IMAGE_VERS}|g" \
        -e "s|IMAGE_NAME|${IMAGE_NAME}|g" \
        -e "s|CP_FLAVOR|${CP_FLAVOR}|g" \
        -e "s|FLAVOR_NAME|${FLAVOR_NAME}|g" \
        -e "s|ENABLE_NVIDIA|${enable_nvidia}|g" \
        -i $HOME/cluster.json
        # TODO: enable when AMD support is configured in Unikorn
        # -e "s|ENABLE_AMD|${enable_amd}|g" \
}

# Generate the dogkat yaml file
function prepare_dogkat {
  scale_to=25

  sed -e "s|CLUSTER_NAME|${CN}|g" \
      -e "s|DOMAIN|${domain}|g" \
      -e "s|SCALE_TO|${scale_to}|g" \
      -e "s|STORAGE_CLASS|${storage_class}|g" \
      -e "s|ENABLE_NVIDIA|${enable_nvidia}|g" \
      -i $HOME/.dogkat/dogkat.yaml
      # TODO: enable when AMD support is configured in Unikorn and Dogkat
      # -e "s|ENABLE_AMD|${enable_amd}|g" \
}

# Provision the cluster for running tests
function provision_cluster {
    START=$(date +%s)
    unikornctl create cluster --name "${CN}" --controlplane "${CP}" --json "$HOME/cluster.json"
    checkForSuccess $? "provision_cluster" "failed to successfully provision cluster"

    # Have a little sleep to prevent the check happening too quick
    sleep 10

    PROVISIONING=$(unikornctl get cluster --name "${CN}" --controlplane "${CP}" | grep -o "Provisioned")
    while [ "${PROVISIONING}" != "Provisioned" ]; do
      echo "checking status again";
      if unikornctl get cluster --name "${CN}" --controlplane "${CP}" | grep -o "Provisioning"; [ "$?" -eq 0 ]; then
        PROVISIONING="Provisioning";
        sleep 10;
      elif unikornctl get cluster --name "${CN}" --controlplane "${CP}" | grep -o "Provisioned"; [ "$?" -eq 0 ]; then
        PROVISIONING="Provisioned";
        echo "cluster has finished provisioning";

      else
        PROVISIONING="Failed";
        echo "cluster has failed provisioning";
        echo $(unikornctl get cluster --name "${CN}" --controlplane "${CP}")
        exit 1
      fi;
    done

    END=$(date +%s)
    DURATION=$((END - START))
    echo "unikornctl_cluster_creation_duration_seconds{image=\"${CN}\"} ${DURATION}" | curl --data-binary @- ${push_gateway}
}

# Fetch kubeconfig for cluster
function get_kubeconfig {
    unikornctl get kubeconfig --cluster "${CN}" --controlplane "${CP}" > $HOME/.kube/config
    chmod 600 $HOME/.kube/config
}

# Deploy the cluster issuer for dns verification along with required secret
function deploy_cluster_issuers {
    cat << EOF > /tmp/ci.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  annotations:
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${cloudflare_email}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - dns01:
          cloudflare:
            email: ${cloudflare_email}
            apiTokenSecretRef:
              key: api-key
              name: cloudflare-api-key-secret
EOF

    # Deploy secrets for cloudflare api auth
    deploy_secrets "cert-manager"

    # Deploy cluster issuer
    kubectl apply -f /tmp/ci.yaml
    checkForSuccess $? "deploy_secrets" "failed to create cluster issuers"
}

# Deploy external DNS and required secret
function deploy_external_dns {
    cat << EOF > /tmp/dns.yaml
env:
  - name: "CF_API_TOKEN"
    valueFrom:
      secretKeyRef:
        key:  api-key
        name: cloudflare-api-key-secret
txtOwnerId: img-build
txtPrefix: "${CN}"
domainFilters:
  - ${domain}
sources:
  - service
  - ingress
provider: "cloudflare"
policy: sync
EOF
    # Deploy external dns
    helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/
    helm upgrade --install external-dns external-dns/external-dns -n external-dns --create-namespace -f /tmp/dns.yaml
    checkForSuccess $? "deploy_secrets" "failed to deploy external-dns"

    # Deploy secret for cloudflare auth
    deploy_secrets "external-dns"

    # Deploy wait for external dns to be ready before moving on
    kubectl wait deploy/external-dns --for=condition=Available -n external-dns --timeout=60s
    checkForSuccess $? "deploy_secrets" "failed to deploy external-dns"
}

# Deploy the cloudflare api secret into the target namespace
function deploy_secrets {
    cat << EOF > /tmp/cf.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-key-secret
type: Opaque
data:
  api-key: $(echo -n ${api_key} | base64 -w0)
EOF
    kubectl -n $1 apply -f /tmp/cf.yaml
    checkForSuccess $? "deploy_secrets" "failed to create cloudflare-secret in namespace $1"
}

# Run dogkat tests
function run_tests {
    dogkat validate -n dogkat
    checkForSuccess $? "run_tests" "failed to successfully run dogkat validate"
}


# Uploads the results of the test to S3
function upload_results_to_s3 {
    mkdir -p $HOME/.aws/
    cat << EOF > $HOME/.aws/credentials
[default]
aws_access_key_id = ${s3_access_key}
aws_secret_access_key = ${s3_secret_key}
EOF

    aws --endpoint-url "${s3_endpoint}" s3 cp /tmp/results.json s3://dogkat/${image_id}.json
    checkForSuccess $? "run_tests" "failed to successfully upload the results to s3"
}

# Runs a cleanup to ensure no resources are left hanging in openstack
function cleanup {
    dogkat delete -n dogkat
    checkForSuccess $? "cleanup" "failed to successfully run dogkat delete"

    helm uninstall -n external-dns external-dns
    checkForSuccess $? "cleanup" "failed to successfully uninstall external-dns"
}

# Deprovision the cluster
function deprovision_cluster {
    unikornctl delete cluster --name "${CN}" --controlplane "${CP}"
    checkForSuccess $? "deprovision_cluster" "failed to successfully delete cluster"

    # Have a little sleep to prevent the check happening too quick
    sleep 10
    DEPROVISIONING=$(unikornctl get cluster --name "${CN}" --controlplane "${CP}" | grep -o "Deprovisioning")
    while [ "${DEPROVISIONING}" == "Deprovisioning" ]; do
      echo "checking status again";
      if unikornctl get cluster --name "${CN}" --controlplane "${CP}" | grep -o "Deprovisioning"; [ "$?" -eq 0 ]; then
        PROVISIONING="Deprovisioning";
        sleep 10;
      else
        DEPROVISIONING="Done";
        echo "cluster has finished deprovisioning";
      fi;
    done
}

cmd="$1"

while [[ $# -gt 0 ]]; do
	case $1 in
		--image-id)
			image_id=$2
			shift
			;;
		--unikorn-url)
			unikorn_url="$2"
			shift
			;;
		--app-bundle)
			app_bundle="$2"
			shift
			;;
		--region)
			region="$2"
			shift
			;;
		--api-key)
			api_key="$2"
			shift
			;;
		--s3-endpoint)
			s3_endpoint="$2"
			shift
			;;
		--s3-access-key)
			s3_access_key="$2"
			shift
			;;
		--s3-secret-key)
			s3_secret_key="$2"
			shift
			;;
		--domain)
			domain="$2"
			shift
			;;
		--storage-class)
			storage_class="$2"
			shift
			;;
		--cloudflare-email)
			cloudflare_email="$2"
			shift
			;;
		--enable-amd)
			enable_amd="$2"
			shift
			;;
		--enable-nvidia)
			enable_nvidia="$2"
			shift
			;;
		--push-gateway-url)
			push_gateway="$2"
			shift
			;;
	esac
	shift
done

case $cmd in
  build-cluster)
    prepare_unikornctl
    set_vars
    prepare_cluster_build
    provision_cluster
    ;;
  deprovision-cluster)
    prepare_unikornctl
    set_vars
    deprovision_cluster
    ;;
  run-dogkat)
    prepare_unikornctl
    set_vars
    get_kubeconfig
    prepare_dogkat
    deploy_cluster_issuers
    deploy_external_dns
    run_tests
    upload_results_to_s3
    cleanup
    deprovision_cluster
    ;;
esac
