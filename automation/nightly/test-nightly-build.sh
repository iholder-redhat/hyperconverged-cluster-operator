#!/usr/bin/env bash

set -ex

source "hack/cri-bin.sh"

# Get golang
$CRI_BIN login --username "$(cat "${QUAY_USER}")" --password-stdin quay.io < "${QUAY_PASSWORD}"
wget -q https://dl.google.com/go/go1.22.6.linux-amd64.tar.gz
tar -C /usr/local -xf go*.tar.gz
export PATH=/usr/local/go/bin:$PATH

# get latest KubeVirt commit
latest_kubevirt=$(curl -sL https://storage.googleapis.com/kubevirt-prow/devel/nightly/release/kubevirt/kubevirt/latest)
latest_kubevirt_image=$(curl -sL "https://storage.googleapis.com/kubevirt-prow/devel/nightly/release/kubevirt/kubevirt/${latest_kubevirt}/kubevirt-operator.yaml" | grep 'OPERATOR_IMAGE' -A1 | tail -n 1 | sed 's/.*value: //g')
IFS=: read -r kv_image kv_tag <<< "${latest_kubevirt_image}"
latest_kubevirt_commit=$(curl -sL "https://storage.googleapis.com/kubevirt-prow/devel/nightly/release/kubevirt/kubevirt/${latest_kubevirt}/commit")

# get latest CDI commit
latest_cdi=$(curl -sL https://storage.googleapis.com/kubevirt-prow/devel/nightly/release/kubevirt/containerized-data-importer/latest)
latest_cdi_image=$(curl -sL "https://storage.googleapis.com/kubevirt-prow/devel/nightly/release/kubevirt/containerized-data-importer/${latest_cdi}/cdi-operator.yaml" | grep "image:" | sed -E "s|^ +image: (.*)$|\1|")
IFS=: read -r cdi_image cdi_tag <<< "${latest_cdi_image}"
latest_cdi_commit=$(curl -sL "https://storage.googleapis.com/kubevirt-prow/devel/nightly/release/kubevirt/containerized-data-importer/${latest_cdi}/commit")

# Update HCO dependencies
go mod tidy
go mod vendor
rm -rf kubevirt cdi

# Get latest kubevirt
git clone https://github.com/kubevirt/kubevirt.git
(cd kubevirt; git checkout "${latest_kubevirt_commit}")

# Get latest CDI
git clone https://github.com/kubevirt/containerized-data-importer.git cdi
(cd cdi; git checkout "${latest_cdi_commit}")

go mod edit -replace kubevirt.io/api=./kubevirt/staging/src/kubevirt.io/api
go mod edit -replace kubevirt.io/containerized-data-importer-api=./cdi/staging/src/kubevirt.io/containerized-data-importer-api

go mod tidy
go mod vendor

# set envs
build_date="$(date +%Y%m%d)"
export IMAGE_REGISTRY=quay.io
export IMAGE_TAG="nb_${build_date}_$(git show -s --format=%h)"
export IMAGE_PREFIX=kubevirtci
TEMP_OPERATOR_IMAGE=${IMAGE_PREFIX}/hyperconverged-cluster-operator
TEMP_WEBHOOK_IMAGE=${IMAGE_PREFIX}/hyperconverged-cluster-webhook
CSV_OPERATOR_IMAGE=${IMAGE_REGISTRY}/${TEMP_OPERATOR_IMAGE}
CSV_WEBHOOK_IMAGE=${IMAGE_REGISTRY}/${TEMP_WEBHOOK_IMAGE}

# Build HCO & HCO Webhook
OPERATOR_IMAGE=${TEMP_OPERATOR_IMAGE} WEBHOOK_IMAGE=${TEMP_WEBHOOK_IMAGE} make container-build-operator container-push-operator container-build-webhook container-push-webhook

# Update image digests
sed -i "s#quay.io/kubevirt/virt-#${kv_image/-*/-}#" deploy/images.csv
sed -i "s#^KUBEVIRT_VERSION=.*#KUBEVIRT_VERSION=\"${kv_tag}\"#" hack/config
sed -i "s#^CDI_VERSION=.*#CDI_VERSION=\"${cdi_tag}\"#" hack/config
(cd ./tools/digester && go build .)
export HCO_VERSION="${IMAGE_TAG}"
./automation/digester/update_images.sh

HCO_OPERATOR_IMAGE_DIGEST=$(tools/digester/digester --image ${CSV_OPERATOR_IMAGE}:${IMAGE_TAG})
HCO_WEBHOOK_IMAGE_DIGEST=$(tools/digester/digester --image ${CSV_WEBHOOK_IMAGE}:${IMAGE_TAG})

# Build the CSV
HCO_OPERATOR_IMAGE=${HCO_OPERATOR_IMAGE_DIGEST} HCO_WEBHOOK_IMAGE=${HCO_WEBHOOK_IMAGE_DIGEST} ./hack/build-manifests.sh

# Download OPM
OPM_VERSION=v1.47.0
wget https://github.com/operator-framework/operator-registry/releases/download/${OPM_VERSION}/linux-amd64-opm -O opm
chmod +x opm
export OPM=$(pwd)/opm

# create and push bundle image and index image
REGISTRY_NAMESPACE=${IMAGE_PREFIX} IMAGE_TAG=${IMAGE_TAG} ./hack/build-index-image.sh latest UNSTABLE

BUNDLE_REGISTRY_IMAGE_NAME=${BUNDLE_REGISTRY_IMAGE_NAME:-hyperconverged-cluster-bundle}
INDEX_REGISTRY_IMAGE_NAME=${INDEX_REGISTRY_IMAGE_NAME:-hyperconverged-cluster-index}
BUNDLE_IMAGE_NAME="${IMAGE_REGISTRY}/${IMAGE_PREFIX}/${BUNDLE_REGISTRY_IMAGE_NAME}:${IMAGE_TAG}"
INDEX_IMAGE_NAME="${IMAGE_REGISTRY}/${IMAGE_PREFIX}/${INDEX_REGISTRY_IMAGE_NAME}:${IMAGE_TAG}"

# download operator-sdk
sdk_url=$(curl https://api.github.com/repos/operator-framework/operator-sdk/releases/latest | jq -rM '.assets[] | select(.name == "operator-sdk_linux_amd64") | .browser_download_url')
wget $sdk_url -O operator-sdk
chmod +x operator-sdk

# start K8s cluster
export KUBEVIRT_PROVIDER=k8s-1.31
make cluster-up
export KUBECONFIG=$(_kubevirtci/cluster-up/kubeconfig.sh)

export KUBEVIRTCI_TAG=$(curl -L -Ss https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirtci/latest)
export KUBECTL=$(pwd)/_kubevirtci/cluster-up/kubectl.sh

# install OLM on the cluster
# latest OLM, v0.29.0 is broken. Forcing a working OLM version
# TODO: drop the --version command line parameter when https://github.com/operator-framework/operator-lifecycle-manager/issues/3419 is resolved.
./operator-sdk olm install --version=v0.28.0

# install HCO on the cluster
$KUBECTL create ns kubevirt-hyperconverged
./operator-sdk run bundle -n kubevirt-hyperconverged --timeout=10m ${BUNDLE_IMAGE_NAME}

# deploy the HyperConverged CR
$KUBECTL apply -n kubevirt-hyperconverged deploy/hco.cr.yaml
$KUBECTL wait -n kubevirt-hyperconverged hco kubevirt-hyperconverged --for=condition=Available --timeout=5m

hco_bucket="kubevirt-prow/devel/nightly/release/kubevirt/hyperconverged-cluster-operator"
echo "${build_date}" > build-date
echo "${BUNDLE_IMAGE_NAME}" > hco-bundle
echo "${INDEX_IMAGE_NAME}" > hco-index
gsutil cp ./hco-bundle "gs://${hco_bucket}/${build_date}/hco-bundle-image"
gsutil cp ./hco-index "gs://${hco_bucket}/${build_date}/hco-index-image"
gsutil cp ./build-date gs://${hco_bucket}/latest
