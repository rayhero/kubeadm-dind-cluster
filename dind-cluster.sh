#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

if [ $(uname) = Darwin ]; then
  readlinkf(){ perl -MCwd -e 'print Cwd::abs_path shift' "$1";}
else
  readlinkf(){ readlink -f "$1"; }
fi
DIND_ROOT="$(cd $(dirname "$(readlinkf "${BASH_SOURCE}")"); pwd)"

# In case of moby linux, -v will not work so we can't
# mount /lib/modules and /boot
is_moby_linux=
if docker info|grep -q '^Kernel Version: .*-moby$'; then
    is_moby_linux=1
fi

source "${DIND_ROOT}/config.sh"

DIND_SUBNET="${DIND_SUBNET:-10.192.0.0}"
dind_ip_base="$(echo "${DIND_SUBNET}" | sed 's/\.0$//')"
DIND_IMAGE="${DIND_IMAGE:-}"
BUILD_KUBEADM="${BUILD_KUBEADM:-}"
BUILD_HYPERKUBE="${BUILD_HYPERKUBE:-}"
APISERVER_PORT=${APISERVER_PORT:-8080}
NUM_NODES=${NUM_NODES:-2}
DEPLOY_DASHBOARD=${DEPLOY_DASHBOARD:-}

function dind::need-source {
  if [[ ! -f cluster/kubectl.sh ]]; then
    echo "$0 must be called from the Kubernetes repository root directory" 1>&2
    exit 1
  fi
}

build_tools_dir="build"
use_k8s_source=y
if [[ ! ${BUILD_KUBEADM} && ! ${BUILD_HYPERKUBE} ]]; then
  use_k8s_source=
fi
if [[ ${use_k8s_source} ]]; then
  dind::need-source
  kubectl=cluster/kubectl.sh
  if [[ ! -f ${build_tools_dir}/common.sh ]]; then
    build_tools_dir="build-tools"
  fi
else
  if ! hash kubectl 2>/dev/null; then
    echo "You need kubectl binary in your PATH to use prebuilt DIND image" 1>&2
    exit 1
  fi
  kubectl=kubectl
fi

busybox_image="busybox:1.26.2"
e2e_base_image="golang:1.7.1"
sys_volume_args=()
build_volume_args=()

function dind::set-build-volume-args {
  if [ ${#build_volume_args[@]} -gt 0 ]; then
    return 0
  fi
  build_container_name=
  if [ -n "${KUBEADM_DIND_LOCAL:-}" ]; then
    build_volume_args=(-v "$PWD:/go/src/k8s.io/kubernetes")
  else
    build_container_name="$(KUBE_ROOT=$PWD &&
                            . ${build_tools_dir}/common.sh &&
                            kube::build::verify_prereqs >&2 &&
                            echo "${KUBE_DATA_CONTAINER_NAME:-${KUBE_BUILD_DATA_CONTAINER_NAME}}")"
    build_volume_args=(--volumes-from "${build_container_name}")
  fi
}

function dind::volume-exists {
  local name="$1"
  if docker volume inspect "${name}" >& /dev/null; then
    return 0
  fi
  return 1
}

function dind::create-volume {
  local name="$1"
  docker volume create --label mirantis.kubeadm_dind_cluster --name "${name}" >/dev/null
}

# We mount /boot and /lib/modules into the container
# below to in case some of the workloads need them.
# This includes virtlet, for instance. Also this may be
# useful in future if we want DIND nodes to pass
# preflight checks.
# Unfortunately we can't do this when using Mac Docker
# (unless a remote docker daemon on Linux is used)
# NB: there's no /boot on recent Mac dockers
function dind::prepare-sys-mounts {
  if [[ ! ${is_moby_linux} ]]; then
    sys_volume_args=()
    if [[ -d /boot ]]; then
      sys_volume_args+=(-v /boot:/boot)
    fi
    if [[ -d /lib/modules ]]; then
      sys_volume_args+=(-v /lib/modules:/lib/modules)
    fi
    return 0
  fi
  if ! dind::volume-exists kubeadm-dind-sys; then
    dind::step "Saving a copy of docker host's /lib/modules"
    dind::create-volume kubeadm-dind-sys
    # Use a dirty nsenter trick to fool Docker on Mac and grab system
    # /lib/modules into sys.tar file on kubeadm-dind-sys volume.
    local nsenter="nsenter --mount=/proc/1/ns/mnt --"
    docker run \
           --rm \
           --privileged \
           -v kubeadm-dind-sys:/dest \
           --pid=host \
           "${busybox_image}" \
           /bin/sh -c \
           "if ${nsenter} test -d /lib/modules; then ${nsenter} tar -C / -c lib/modules >/dest/sys.tar; fi"
  fi
  sys_volume_args=(-v kubeadm-dind-sys:/dind-sys)
}

tmp_containers=()

function dind::cleanup {
  if [ ${#tmp_containers[@]} -gt 0 ]; then
    for name in "${tmp_containers[@]}"; do
      docker rm -vf "${name}" 2>/dev/null
    done
  fi
}

trap dind::cleanup EXIT

function dind::check-image {
  local name="$1"
  if docker inspect --format 'x' "${name}" >&/dev/null; then
    return 0
  else
    return 1
  fi
}

function dind::make-for-linux {
  local copy="$1"
  shift
  dind::step "Building binaries:" "$*"
  if [ -n "${KUBEADM_DIND_LOCAL:-}" ]; then
    make WHAT="$*"
    dind::step "+ make WHAT=\"$*\""
  elif [ "${copy}" = "y" ]; then
    "${build_tools_dir}/run.sh" make WHAT="$*"
    dind::step "+ ${build_tools_dir}/run.sh make WHAT=\"$*\""
  else
    KUBE_RUN_COPY_OUTPUT=n "${build_tools_dir}/run.sh" make WHAT="$*"
    dind::step "+ KUBE_RUN_COPY_OUTPUT=n ${build_tools_dir}/run.sh make WHAT=\"$*\""
  fi
}

function dind::check-binary {
  local filename="$1"
  local dockerized="_output/dockerized/bin/linux/amd64/${filename}"
  local plain="_output/local/bin/linux/amd64/${filename}"
  dind::set-build-volume-args
  # FIXME: don't hardcode amd64 arch
  if [ -n "${KUBEADM_DIND_LOCAL:-${force_local:-}}" ]; then
    if [ -f "${dockerized}" -o -f "${plain}" ]; then
      return 0
    fi
  elif docker run --rm "${build_volume_args[@]}" \
              "${busybox_image}" \
              test -f "/go/src/k8s.io/kubernetes/${dockerized}" >&/dev/null; then
    return 0
  fi
  return 1
}

function dind::ensure-kubectl {
  if [[ ! ${use_k8s_source} ]]; then
    # already checked on startup
    return 0
  fi
  if [ $(uname) = Darwin ]; then
    if [ ! -f _output/local/bin/darwin/amd64/kubectl ]; then
      dind::step "Building kubectl"
      dind::step "+ make WHAT=cmd/kubectl"
      make WHAT=cmd/kubectl
    fi
  elif ! force_local=y dind::check-binary kubectl; then
    dind::make-for-linux y cmd/kubectl
  fi
}

function dind::ensure-binaries {
  local -a to_build=()
  for name in "$@"; do
    if ! dind::check-binary "$(basename "${name}")"; then
      to_build+=("${name}")
    fi
  done
  if [ "${#to_build[@]}" -gt 0 ]; then
    dind::make-for-linux n "${to_build[@]}"
  fi
  return 0
}

function dind::ensure-network {
  if ! docker network inspect kubeadm-dind-net >&/dev/null; then
    docker network create --subnet=10.192.0.0/16 kubeadm-dind-net >/dev/null
  fi
}

function dind::ensure-volume {
  local reuse_volume=
  if [[ $1 = -r ]]; then
    reuse_volume=1
    shift
  fi
  local name="$1"
  if dind::volume-exists "${name}"; then
    if [[ ! {reuse_volume} ]]; then
      docker volume rm "${name}" >/dev/null
    fi
  elif [[ ${reuse_volume} ]]; then
    echo "*** Failed to locate volume: ${name}" 1>&2
    return 1
  fi
  dind::create-volume "${name}"
}

function dind::run {
  local reuse_volume=
  if [[ $1 = -r ]]; then
    reuse_volume="-r"
    shift
  fi
  local container_name="${1:-}"
  local ip="${2:-}"
  local netshift="${3:-}"
  local portforward="${4:-}"
  if [[ $# -gt 4 ]]; then
    shift 4
  else
    shift $#
  fi
  local -a opts=(--ip "${ip}" "$@")
  local -a args

  if [[ ! "${container_name}" ]]; then
    echo >&2 "Must specify container name"
    exit 1
  fi

  dind::ensure-kubectl

  # remove any previously created containers with the same name
  docker rm -vf "${container_name}" >&/dev/null || true

  if [[ "$portforward" ]]; then
    opts+=(-p "$portforward")
  fi

  if [[ "$netshift" ]]; then
    args+=("systemd.setenv=DOCKER_NETWORK_OFFSET=0.0.${netshift}.0")
  fi

  opts+=(${sys_volume_args[@]+"${sys_volume_args[@]}"})

  dind::step "Starting DIND container:" "${container_name}"

  if [[ ! ${is_moby_linux} ]]; then
    opts+=(-v /boot:/boot -v /lib/modules:/lib/modules)
  fi

  volume_name="kubeadm-dind-${container_name}"
  dind::ensure-network
  dind::ensure-volume ${reuse_volume} "${volume_name}"

  # TODO: create named volume for binaries and mount it to /k8s
  # in case of the source build

  # Start the new container.
  docker run \
         -d --privileged \
         --net kubeadm-dind-net \
         --name "${container_name}" \
         --hostname "${container_name}" \
         -l mirantis.kubeadm_dind_cluster \
         -v ${volume_name}:/dind \
         ${opts[@]+"${opts[@]}"} \
         "${DIND_IMAGE}" \
         ${args[@]+"${args[@]}"}
}

function dind::kubeadm {
  local container_id="$1"
  shift
  dind::step "Running kubeadm:" "$*"
  status=0
  # See image/bare/wrapkubeadm.
  # Capturing output is necessary to grab flags for 'kubeadm join'
  if ! docker exec "${container_id}" wrapkubeadm "$@" 2>&1 | tee /dev/fd/2; then
    echo "*** kubeadm failed" >&2
    return 1
  fi
  return ${status}
}

# function dind::bare {
#   local container_name="${1:-}"
#   if [[ ! "${container_name}" ]]; then
#     echo >&2 "Must specify container name"
#     exit 1
#   fi
#   shift
#   run_opts=(${@+"$@"})
#   dind::run "${container_name}"
# }

function dind::configure-kubectl {
  dind::step "Setting cluster config"
  "${kubectl}" config set-cluster dind --server="http://localhost:${APISERVER_PORT}" --insecure-skip-tls-verify=true
  "${kubectl}" config set-context dind --cluster=dind
  "${kubectl}" config use-context dind
}

force_make_binaries=
function dind::set-master-opts {
  master_opts=()
  if [[ ${BUILD_KUBEADM} || ${BUILD_HYPERKUBE} ]]; then
    # share binaries pulled from the build container between nodes
    dind::ensure-volume "dind-k8s-binaries"
    dind::set-build-volume-args
    master_opts+=("${build_volume_args[@]}" -v dind-k8s-binaries:/k8s)
    local -a bins
    if [[ ${BUILD_KUBEADM} ]]; then
      master_opts+=(-e KUBEADM_SOURCE=build://)
      bins+=(cmd/kubeadm)
    fi
    if [[ ${BUILD_HYPERKUBE} ]]; then
      master_opts+=(-e HYPERKUBE_SOURCE=build://)
      bins+=(cmd/hyperkube)
    fi
    if [[ ${force_make_binaries} ]]; then
      dind::make-for-linux n "${bins[@]}"
    else
      dind::ensure-binaries "${bins[@]}"
    fi
  fi
}

function dind::deploy-dashboard {
  dind::step "Deploying k8s dashboard"
  "${kubectl}" create -f https://rawgit.com/kubernetes/dashboard/master/src/deploy/kubernetes-dashboard.yaml
}

function dind::init {
  local -a opts
  dind::set-master-opts
  local master_ip="${dind_ip_base}.2"
  local container_id=$(dind::run kube-master "${master_ip}" 1 127.0.0.1:${APISERVER_PORT}:8080 ${master_opts[@]+"${master_opts[@]}"})
  # FIXME: I tried using custom tokens with 'kubeadm ex token create' but join failed with:
  # 'failed to parse response as JWS object [square/go-jose: compact JWS format must have three parts]'
  # So we just pick the line from 'kubeadm init' output
  kubeadm_join_flags="$(dind::kubeadm "${container_id}" init --skip-preflight-checks "$@" | grep '^kubeadm join' | sed 's/^kubeadm join //')"
  dind::configure-kubectl
  if [[ ${DEPLOY_DASHBOARD} ]]; then
    dind::deploy-dashboard
  fi
}

function dind::create-node-container {
  local reuse_volume=
  if [[ $1 = -r ]]; then
    reuse_volume="-r"
    shift
  fi
  # if there's just one node currently, it's master, thus we need to use
  # kube-node-1 hostname, if there are two nodes, we should pick
  # kube-node-2 and so on
  local next_node_index=${1:-$(docker ps -q --filter=label=mirantis.kubeadm_dind_cluster | wc -l | sed 's/^ *//g')}
  local node_ip="${dind_ip_base}.$((next_node_index + 2))"
  local -a opts
  if [[ ${BUILD_KUBEADM} || ${BUILD_HYPERKUBE} ]]; then
    opts+=(-v dind-k8s-binaries:/k8s)
    if [[ ${BUILD_KUBEADM} ]]; then
      opts+=(-e KUBEADM_SOURCE=build://)
    fi
    if [[ ${BUILD_HYPERKUBE} ]]; then
      opts+=(-e HYPERKUBE_SOURCE=build://)
    fi
  fi
  dind::run ${reuse_volume} kube-node-${next_node_index} ${node_ip} $((next_node_index + 1)) "" ${opts[@]+"${opts[@]}"}
}

function dind::join {
  local container_id="$1"
  shift
  dind::kubeadm "${container_id}" join --skip-preflight-checks "$@" >/dev/null
}

function dind::escape-e2e-name {
    sed 's/[]\$*.^|()[]/\\&/g; s/\s\+/\\s+/g' <<< "$1" | tr -d '\n'
}

function dind::accelerate-kube-dns {
  dind::step "Patching kube-dns deployment to make it start faster"
  # Could do this on the host, too, but we don't want to require jq here
  # TODO: do this in wrapkubeadm
  docker exec kube-master /bin/bash -c \
         "kubectl get deployment kube-dns -n kube-system -o json | jq '.spec.template.spec.containers[0].readinessProbe.initialDelaySeconds = 3|.spec.template.spec.containers[0].readinessProbe.periodSeconds = 3' | kubectl apply --force -f -"
}

function dind::component-ready {
  local component="$1"
  local out
  if ! out="$("${kubectl}" get pod -l k8s-app="${component}" -n kube-system \
                           -o jsonpath='{ .items[*].status.conditions[?(@.type == "Ready")].status }' 2>/dev/null)"; then
    return 1
  fi
  if ! grep -v False <<<"${out}" | grep -q True; then
    return 1
  fi
  return 0
}

function dind::wait-for-ready {
  dind::step "Waiting for the cluster to become ready"
  local proxy_ready
  local dns_ready
  local nodes_ready
  while true; do
    if kubectl get nodes 2>/dev/null| grep -q NotReady; then
      nodes_ready=
    else
      nodes_ready=y
    fi
    if dind::component-ready kube-proxy; then
      proxy_ready=y
    else
      proxy_ready=
    fi
    if dind::component-ready kube-dns; then
      dns_ready=y
    else
      dns_ready=
    fi
    if [[ ${nodes_ready} && ${proxy_ready} && ${dns_ready} ]]; then
      echo "[done]" >&2
      break
    fi
    echo -n "." >&2
    sleep 1
  done

  "${kubectl}" get nodes >&2
  if [[ ${DEPLOY_DASHBOARD} ]]; then
    dind::step "Access dashboard at:" "http://localhost:${APISERVER_PORT}/ui"
  fi
}

function dind::up {
  dind::down
  dind::init
  local master_ip="$(docker inspect --format="{{.NetworkSettings.IPAddress}}" kube-master)"
  # pre-create node containers sequentially so they get predictable IPs
  local -a node_containers
  for ((n=1; n <= NUM_NODES; n++)); do
    dind::step "Starting node container:" ${n}
    if ! container_id="$(dind::create-node-container ${n})"; then
      echo >&2 "*** Failed to start node container ${n}"
      exit 1
    else
      node_containers+=(${container_id})
      dind::step "Node container started:" ${n}
    fi
  done
  status=0
  local -a pids
  for ((n=1; n <= NUM_NODES; n++)); do
    (
      dind::step "Joining node:" ${n}
      container_id="${node_containers[n-1]}"
      if ! dind::join ${container_id} ${kubeadm_join_flags}; then
        echo >&2 "*** Failed to start node container ${n}"
        exit 1
      else
        dind::step "Node joined:" ${n}
      fi
    )&
    pids[${n}]=$!
  done
  for pid in ${pids[*]}; do
    wait ${pid}
  done
  dind::accelerate-kube-dns
}

function dind::snapshot_container {
  local container_name="$1"
  docker exec -i ${container_name} /usr/local/bin/snapshot prepare
  docker diff ${container_name} | docker exec -i ${container_name} /usr/local/bin/snapshot save
}

function dind::snapshot {
  dind::step "Taking snapshot of the cluster"
  dind::snapshot_container kube-master
  for ((n=1; n <= NUM_NODES; n++)); do
    dind::snapshot_container "kube-node-${n}"
  done
  dind::wait-for-ready
}

restore_cmd=restore
function dind::restore_container {
  local container_id="$1"
  docker exec ${container_id} /usr/local/bin/snapshot "${restore_cmd}"
}

function dind::restore {
  local master_ip="${dind_ip_base}.2"
  dind::down
  dind::step "Restoring master container"
  dind::set-master-opts
  for ((n=0; n <= NUM_NODES; n++)); do
    (
      if [[ n -eq 0 ]]; then
        dind::step "Restoring master container"
        dind::restore_container "$(dind::run -r kube-master "${master_ip}" 1 127.0.0.1:${APISERVER_PORT}:8080 ${master_opts[@]+"${master_opts[@]}"})"
        dind::step "Master container restored"
      else
        dind::step "Restoring node container:" ${n}
        if ! container_id="$(dind::create-node-container -r ${n})"; then
          echo >&2 "*** Failed to start node container ${n}"
          exit 1
        else
          dind::restore_container "${container_id}"
          dind::step "Node container restored:" ${n}
        fi
      fi
    )&
    pids[${n}]=$!
  done
  for pid in ${pids[*]}; do
    wait ${pid}
  done
  # Recheck kubectl config. It's possible that the cluster was started
  # on this docker from different host
  dind::configure-kubectl
  dind::wait-for-ready
}

function dind::down {
  docker ps -a -q --filter=label=mirantis.kubeadm_dind_cluster | while read container_id; do
    dind::step "Removing container:" "${container_id}"
    docker rm -fv "${container_id}"
  done
}

function dind::remove-volumes {
  # docker 1.13+: docker volume ls -q -f label=mirantis.kubeadm_dind_cluster
  docker volume ls -q | grep '^kubeadm-dind' | while read volume_id; do
    dind::step "Removing volume:" "${volume_id}"
    docker volume rm "${volume_id}"
  done
}

function dind::check-for-snapshot {
  if ! dind::volume-exists "kubeadm-dind-kube-master"; then
    return 1
  fi
  for ((n=1; n <= NUM_NODES; n++)); do
    if ! dind::volume-exists "kubeadm-dind-kube-node-${n}"; then
      return 1
    fi
  done
}

function dind::do-run-e2e {
  local parallel="${1:-}"
  local focus="${2:-}"
  local skip="${3:-}"
  dind::need-source
  local test_args="--host=http://localhost:${APISERVER_PORT}"
  if [[ "$focus" ]]; then
    test_args="--ginkgo.focus=${focus} ${test_args}"
  fi
  if [[ "$skip" ]]; then
    test_args="--ginkgo.skip=${skip} ${test_args}"
  fi
  dind::ensure-binaries cmd/kubectl test/e2e/e2e.test vendor/github.com/onsi/ginkgo/ginkgo
  dind::step "Running e2e tests with args:" "${test_args}"
  dind::set-build-volume-args
  docker run \
         --rm -it \
         --net=host \
         "${build_volume_args[@]}" \
         -e KUBERNETES_PROVIDER=dind \
         -e KUBE_MASTER_IP=http://localhost:${APISERVER_PORT} \
         -e KUBE_MASTER=local \
         -e KUBERNETES_CONFORMANCE_TEST=y \
         -e GINKGO_PARALLEL=${parallel} \
         -w /go/src/k8s.io/kubernetes \
         "${e2e_base_image}" \
         bash -c "cluster/kubectl.sh config set-cluster dind --server='http://localhost:${APISERVER_PORT}' --insecure-skip-tls-verify=true &&
         cluster/kubectl.sh config set-context dind --cluster=dind &&
         cluster/kubectl.sh config use-context dind &&
         go run hack/e2e.go --v --test -check_version_skew=false --test_args='${test_args}'"
}

function dind::clean {
  dind::down
  # dind::remove-images
  dind::remove-volumes
  if docker network inspect kubeadm-dind-net >&/dev/null; then
    docker network remove kubeadm-dind-net
  fi
}

function dind::run-e2e {
  local focus="${1:-}"
  local skip="${2:-\[Serial\]}"
  if [[ "$focus" ]]; then
    focus="$(dind::escape-e2e-name "${focus}")"
  else
    focus="\[Conformance\]"
  fi
  dind::do-run-e2e y "${focus}" "${skip}"
}

function dind::run-e2e-serial {
  local focus="${1:-}"
  local skip="${2:-}"
  dind::need-source
  if [[ "$focus" ]]; then
    focus="$(dind::escape-e2e-name "${focus}")"
  else
    focus="\[Serial\].*\[Conformance\]"
  fi
  dind::do-run-e2e n "${focus}" "${skip}"
  # TBD: specify filter
}

function dind::step {
  local OPTS=""
  if [ "$1" = "-n" ]; then
    shift
    OPTS+="-n"
  fi
  GREEN="$1"
  shift
  if [ -t 2 ] ; then
    echo -e ${OPTS} "\x1B[97m* \x1B[92m${GREEN}\x1B[39m $*" 1>&2
  else
    echo ${OPTS} "* ${GREEN} $*" 1>&2
  fi
}

case "${1:-}" in
  up)
    dind::prepare-sys-mounts
    if ! dind::check-for-snapshot; then
      force_make_binaries=y dind::up
      dind::snapshot
    else
      dind::restore
    fi
    ;;
  reup)
    dind::prepare-sys-mounts
    if ! dind::check-for-snapshot; then
      force_make_binaries=y dind::up
      dind::snapshot
    else
      force_make_binaries=y
      restore_cmd=update_and_restore
      dind::restore
    fi
    ;;
  down)
    dind::down
    ;;
  init)
    shift
    dind::prepare-sys-mounts
    dind::init "$@"
    ;;
  join)
    shift
    dind::prepare-sys-mounts
    dind::join "$(dind::create-node-container)" "$@"
    ;;
  # bare)
  #   shift
  #   dind::bare "$@"
  #   ;;
  snapshot)
    shift
    dind::snapshot
    ;;
  restore)
    shift
    dind::restore
    ;;
  clean)
    dind::clean
    ;;
  e2e)
    shift
    dind::run-e2e "$@"
    ;;
  e2e-serial)
    shift
    dind::run-e2e-serial "$@"
    ;;
  *)
    echo "usage:" >&2
    echo "  $0 up" >&2
    echo "  $0 reup" >&2
    echo "  $0 down" >&2
    echo "  $0 init kubeadm-args..." >&2
    echo "  $0 join kubeadm-args..." >&2
    # echo "  $0 bare container_name [docker_options...]"
    echo "  $0 clean"
    echo "  $0 e2e [test-name-substring]" >&2
    echo "  $0 e2e-serial [test-name-substring]" >&2
    exit 1
    ;;
esac
