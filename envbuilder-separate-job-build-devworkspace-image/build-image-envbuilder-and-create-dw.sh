#!/usr/bin/env bash
# Build devcontainer image in a Job, wait for completion, create Che-Code DevWorkspace.
#
# Usage:
#   export REGISTRY_USERNAME=rohankanojia
#   export REGISTRY_PASSWORD='...'
#   ./examples/openshift/build-and-workspace.sh
#
# Optional env:
#   WORKSPACE_NAMESPACE=default
#   SETUP_SCC=false          # skip SA/SCC if already configured
#   SKIP_WORKSPACE=true      # only run the Job
#   ENVBUILDER_IMAGE=docker.io/rohankanojia/envbuilder:latest
#   DEVWORKSPACE_NAME=code-latest
#   GIT_URL=...#refs/heads/main
#
set -euo pipefail

WORKSPACE_NAMESPACE="${WORKSPACE_NAMESPACE:-$(oc project -q 2>/dev/null || kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)}"
REGISTRY="${REGISTRY:-quay.io}"
IMAGE_REPO="${IMAGE_REPO:-workspaces-envbuilder}"
REGISTRY_USERNAME="${REGISTRY_USERNAME:?set REGISTRY_USERNAME}"
REGISTRY_PASSWORD="${REGISTRY_PASSWORD:?set REGISTRY_PASSWORD}"
REGISTRY_EMAIL="${REGISTRY_EMAIL:-nobody@example.com}"
GIT_URL="${GIT_URL:-https://github.com/coder/envbuilder-starter-devcontainer#refs/heads/main}"
GIT_PROJECT_NAME="${GIT_PROJECT_NAME:-envbuilder-starter-devcontainer}"
GIT_PROJECT_URL="${GIT_PROJECT_URL:-https://github.com/coder/envbuilder-starter-devcontainer}"
CACHE_REPO="${REGISTRY}/${REGISTRY_USERNAME}/${IMAGE_REPO}"
OUTPUT_IMAGE="${OUTPUT_IMAGE:-${CACHE_REPO}:latest}"
SECRET_NAME="${SECRET_NAME:-envbuilder-registry-creds}"
SA_NAME="${SA_NAME:-envbuilder-builder}"
JOB_NAME="${JOB_NAME:-envbuilder-build}"
ENVBUILDER_IMAGE="${ENVBUILDER_IMAGE:-quay.io/rokumar/envbuilder:latest}"
DEVWORKSPACE_NAME="${DEVWORKSPACE_NAME:-code-latest}"
SETUP_SCC="${SETUP_SCC:-true}"
SKIP_WORKSPACE="${SKIP_WORKSPACE:-false}"
JOB_TIMEOUT="${JOB_TIMEOUT:-30m}"
WORKSPACE_TIMEOUT="${WORKSPACE_TIMEOUT:-15m}"

if command -v oc &>/dev/null; then
  KUBE="oc"
else
  KUBE="kubectl"
fi

log() { echo "[$(date +%H:%M:%S)] $*"; }

# --- Docker registry auth ---
AUTH_TOKEN=$(printf '%s' "${REGISTRY_USERNAME}:${REGISTRY_PASSWORD}" | base64 | tr -d '\n')
DOCKER_CONFIG_B64=$(printf '%s' "$(cat <<EOF
{
  "auths": {
    "quay.io": {
      "auth": "${AUTH_TOKEN}"
    }
  }
}
EOF
)" | base64 | tr -d '\n')

log "Namespace:        ${WORKSPACE_NAMESPACE}"
log "Builder image:    ${ENVBUILDER_IMAGE}"
log "Output image:     ${OUTPUT_IMAGE}"
log "Git URL:          ${GIT_URL}"

# --- Registry secret + ServiceAccount ---
${KUBE} create secret docker-registry "${SECRET_NAME}" \
  --docker-server="${REGISTRY}" \
  --docker-username="${REGISTRY_USERNAME}" \
  --docker-password="${REGISTRY_PASSWORD}" \
  --docker-email="${REGISTRY_EMAIL}" \
  -n "${WORKSPACE_NAMESPACE}" \
  --dry-run=client -o yaml | ${KUBE} apply -f -

${KUBE} apply -n "${WORKSPACE_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
imagePullSecrets:
  - name: ${SECRET_NAME}
EOF

if [[ "${SETUP_SCC}" == "true" && "${KUBE}" == "oc" ]]; then
  log "Granting SCCs to ${SA_NAME}..."
  oc adm policy add-scc-to-user anyuid -z "${SA_NAME}" -n "${WORKSPACE_NAMESPACE}"
  oc adm policy add-scc-to-user container-build -z "${SA_NAME}" -n "${WORKSPACE_NAMESPACE}"
fi

# --- Delete previous Job ---
${KUBE} delete job "${JOB_NAME}" -n "${WORKSPACE_NAMESPACE}" --ignore-not-found=true --wait=true

# --- Create Job ---
${KUBE} apply -n "${WORKSPACE_NAMESPACE}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  labels:
    app: envbuilder-build
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: envbuilder-build
    spec:
      restartPolicy: Never
      serviceAccountName: ${SA_NAME}
      securityContext:
        runAsUser: 0
      containers:
        - name: envbuilder
          image: ${ENVBUILDER_IMAGE}
          resources:
            requests:
              memory: 2Gi
              cpu: "1"
            limits:
              memory: 4Gi
              cpu: "4"
          env:
            - name: ENVBUILDER_GIT_URL
              value: "${GIT_URL}"
            - name: ENVBUILDER_CACHE_REPO
              value: "${CACHE_REPO}"
            - name: ENVBUILDER_PUSH_IMAGE
              value: "1"
            - name: ENVBUILDER_BUILD_ONLY
              value: "1"
            - name: ENVBUILDER_OPENSHIFT_COMPAT
              value: "1"
            - name: ENVBUILDER_EXIT_ON_PUSH_FAILURE
              value: "1"
            - name: ENVBUILDER_VERBOSE
              value: "true"
            - name: ENVBUILDER_WORKING_DIR_BASE
              value: "/tmp/envbuilder"
            - name: ENVBUILDER_DOCKER_CONFIG_BASE64
              value: "${DOCKER_CONFIG_B64}"
EOF

log "Job created. Waiting for pod..."

POD_NAME=""
for _ in $(seq 1 90); do
  POD_NAME=$(${KUBE} get pods -n "${WORKSPACE_NAMESPACE}" -l job-name="${JOB_NAME}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "${POD_NAME}" ]] && break
  sleep 2
done

if [[ -z "${POD_NAME}" ]]; then
  echo "ERROR: Job pod did not appear" >&2
  exit 1
fi

log "Pod: ${POD_NAME}"

# Stream logs while waiting for Job completion
LOG_PID=""
if ${KUBE} logs -n "${WORKSPACE_NAMESPACE}" "${POD_NAME}" -c envbuilder --tail=1 &>/dev/null; then
  ${KUBE} logs -n "${WORKSPACE_NAMESPACE}" -f "${POD_NAME}" -c envbuilder &
  LOG_PID=$!
fi

cleanup() {
  [[ -n "${LOG_PID}" ]] && kill "${LOG_PID}" 2>/dev/null || true
}
trap cleanup EXIT

log "Waiting for Job complete (timeout ${JOB_TIMEOUT})..."
if ! ${KUBE} wait --for=condition=complete "job/${JOB_NAME}" -n "${WORKSPACE_NAMESPACE}" --timeout="${JOB_TIMEOUT}"; then
  cleanup
  trap - EXIT
  echo "" >&2
  echo "ERROR: Job did not complete successfully." >&2
  ${KUBE} describe job "${JOB_NAME}" -n "${WORKSPACE_NAMESPACE}" >&2 || true
  ${KUBE} logs -n "${WORKSPACE_NAMESPACE}" "${POD_NAME}" -c envbuilder --tail=100 >&2 || true
  exit 1
fi

cleanup
trap - EXIT

log "Job succeeded."
${KUBE} logs -n "${WORKSPACE_NAMESPACE}" "${POD_NAME}" -c envbuilder --tail=30 | grep -E 'Pushed image|ENVBUILDER_PUSHED_IMAGE|Build-only|error' || true

if [[ "${SKIP_WORKSPACE}" == "true" ]]; then
  log "SKIP_WORKSPACE=true — done."
  exit 0
fi

# --- DevWorkspace + Che-Code ---
log "Creating DevWorkspace ${DEVWORKSPACE_NAME}..."
${KUBE} delete devworkspace "${DEVWORKSPACE_NAME}" -n "${WORKSPACE_NAMESPACE}" --ignore-not-found=true --wait=true 2>/dev/null || \
  ${KUBE} delete devworkspace "${DEVWORKSPACE_NAME}" -n "${WORKSPACE_NAMESPACE}" --ignore-not-found=true

${KUBE} apply -n "${WORKSPACE_NAMESPACE}" -f - <<EOF
apiVersion: workspace.devfile.io/v1alpha2
kind: DevWorkspace
metadata:
  name: ${DEVWORKSPACE_NAME}
spec:
  started: true
  template:
    attributes:
      controller.devfile.io/storage-type: per-user
    projects:
      - name: ${GIT_PROJECT_NAME}
        git:
          remotes:
            origin: "${GIT_PROJECT_URL}"
          checkoutFrom:
            remote: origin
            revision: main
    components:
      - name: dev
        container:
          image: ${OUTPUT_IMAGE}
          mountSources: true
          command: ["/bin/bash"]
          args: ["-c", "sleep infinity"]
          memoryLimit: 2Gi
          memoryRequest: 512Mi
          cpuLimit: 2000m
          cpuRequest: 500m
    commands:
      - id: say-hello
        exec:
          component: dev
          commandLine: echo "Hello from \$(pwd)"
          workingDir: \${PROJECT_SOURCE}
  contributions:
    - name: che-code
      uri: https://eclipse-che.github.io/che-plugin-registry/main/v3/plugins/che-incubator/che-code/latest/devfile.yaml
      components:
        - name: che-code-runtime-description
          container:
            env:
              - name: CODE_HOST
                value: 0.0.0.0
EOF

log "Waiting for DevWorkspace (timeout ${WORKSPACE_TIMEOUT})..."
if ! ${KUBE} wait --for=jsonpath='{.status.phase}'=Running \
  "devworkspace/${DEVWORKSPACE_NAME}" -n "${WORKSPACE_NAMESPACE}" --timeout="${WORKSPACE_TIMEOUT}" 2>/dev/null; then
  # Fallback poll for older operators
  for _ in $(seq 1 60); do
    phase=$(${KUBE} get devworkspace "${DEVWORKSPACE_NAME}" -n "${WORKSPACE_NAMESPACE}" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [[ "${phase}" == "Running" ]] && break
    sleep 5
  done
fi

IDE_URL=$(${KUBE} get devworkspace "${DEVWORKSPACE_NAME}" -n "${WORKSPACE_NAMESPACE}" \
  -o jsonpath='{.status.ideUrl}' 2>/dev/null || true)

log "DevWorkspace phase: $(${KUBE} get devworkspace "${DEVWORKSPACE_NAME}" -n "${WORKSPACE_NAMESPACE}" -o jsonpath='{.status.phase}')"
if [[ -n "${IDE_URL}" ]]; then
  log "IDE URL: ${IDE_URL}"
else
  log "IDE URL not ready yet. Check: ${KUBE} get devworkspace ${DEVWORKSPACE_NAME} -o yaml"
fi

DW_ID=$(${KUBE} get devworkspace "${DEVWORKSPACE_NAME}" -n "${WORKSPACE_NAMESPACE}" \
  -o jsonpath='{.status.devworkspaceId}' 2>/dev/null || true)
WORKSPACE_POD=$(${KUBE} get pods -n "${WORKSPACE_NAMESPACE}" -o name 2>/dev/null \
  | grep -F "${DW_ID}" | head -1 | sed 's|pod/||' || true)
if [[ -n "${WORKSPACE_POD}" ]]; then
  log "Shell (pod):  ${KUBE} exec -it -n ${WORKSPACE_NAMESPACE} ${WORKSPACE_POD} -c dev -- bash"
else
  log "Shell: ${KUBE} get pods -n ${WORKSPACE_NAMESPACE} | grep ${DW_ID:-<devworkspace-id>}"
fi

