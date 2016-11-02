#!/bin/bash
if [ $(uname) = Darwin ]; then
  readlinkf(){ perl -MCwd -e 'print Cwd::abs_path shift' "$1";}
else
  readlinkf(){ readlink -f "$1"; }
fi
DIND_ROOT="$(cd $(dirname "$(readlinkf "${BASH_SOURCE}")"); pwd)"

# Based on instructions from k8s build-tools/README.md
if [ -z "${KUBE_DIND_GCE_PROJECT:-}" ]; then
    echo >&2 "Please set KUBE_DIND_GCE_PROJECT"
    return 1
fi

set -x
KUBE_DIND_VM=k8s-dind
export KUBE_RSYNC_PORT=8370
export APISERVER_PORT=8899
docker-machine create \
               --driver=google \
               --google-project=${KUBE_DIND_GCE_PROJECT} \
               --google-zone=us-west1-a \
               --google-machine-type=n1-standard-8 \
               --google-disk-size=50 \
               --google-disk-type=pd-ssd \
               --engine-storage-driver=overlay2 \
               ${KUBE_DIND_VM}
eval $(docker-machine env ${KUBE_DIND_VM})
docker-machine ssh ${KUBE_DIND_VM} \
               -L ${KUBE_RSYNC_PORT}:localhost:${KUBE_RSYNC_PORT} \
               -L ${APISERVER_PORT}:localhost:${APISERVER_PORT} \
               -N&
time KUBE_RUN_COPY_OUTPUT=n \
     build-tools/run.sh \
     make WHAT='cmd/hyperkube cmd/kubelet cmd/kubectl cmd/kubeadm test/e2e/e2e.test vendor/github.com/onsi/ginkgo/ginkgo'
time "${DIND_ROOT}"/kubeadm-up.sh prepare
time "${DIND_ROOT}"/kubeadm-up.sh up
set +x
