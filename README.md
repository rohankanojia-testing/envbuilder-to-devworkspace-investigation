# EnvBuilder + DevWorkspace Investigation

This repository contains a proof-of-concept investigation for [Eclipse Che #23458](https://github.com/eclipse/che/issues/23458) exploring whether [EnvBuilder](https://github.com/coder/envbuilder) can be used to provide native `devcontainer.json` support in Eclipse Che DevWorkspaces.

## What is EnvBuilder?

EnvBuilder is a [Coder](https://coder.com) tool that builds and runs development environments from a Git repository's `devcontainer.json` or `Dockerfile` on Docker, Kubernetes, and OpenShift.

**Key characteristics:**
- Clones a repository
- Processes `devcontainer.json` configuration
- Builds the development environment image (using Kaniko)
- Mutates the running container's filesystem to create the developer environment
- Executes into the resulting environment

## Investigation Approaches

This investigation explored three different approaches to integrating EnvBuilder with DevWorkspace:

### 1. EnvBuilder Inside K8s Pod
See: [`envbuilder-inside-k8s-pod/`](./envbuilder-inside-k8s-pod/)

A standard Kubernetes Pod running EnvBuilder to build and run a development environment.

**Status:** ✅ Works as expected

### 2. EnvBuilder Inside DevWorkspace
See: [`envbuilder-inside-devworkspace/`](./envbuilder-inside-devworkspace/)

Attempted to run EnvBuilder directly as a container component within a DevWorkspace.

**Status:** ❌ Failed

**Error:**
```
error: temp remount: temp remount: ensure path: mkdir /.envbuilder/mnt: permission denied
```

**Root cause:** DevWorkspace's restricted security context (non-root user, `allowPrivilegeEscalation: false`, dropped capabilities) conflicts with EnvBuilder's need to perform filesystem mutations and remounts.

### 3. EnvBuilder as Separate Build Job
See: [`envbuilder-separate-job-build-devworkspace-image/`](./envbuilder-separate-job-build-devworkspace-image/)

Used EnvBuilder in a separate Kubernetes Job to build and push an image to a registry, which could then be consumed by a DevWorkspace.

**Status:** ⚠️ Partially works, but not suitable

**Issues:**
1. EnvBuilder's `ENVBUILDER_PUSH_IMAGE` option pushes the image but does not terminate execution. Instead, the container continues into runtime phase by executing the configured init command. There is no "build-and-exit" mode.
2. Requires a container registry for storing built images with associated complexity:
   - **OpenShift Internal Registry:** Requires proper RBAC permissions, service account configuration, and image pull secrets for DevWorkspaces to access images
   - **External Registry (Docker Hub, Quay.io, etc.):** Requires:
     - Registry credentials management (username/password or tokens)
     - Secure credential injection into build Jobs (via Secrets)
     - Proper authentication configuration (`ENVBUILDER_DOCKER_CONFIG_BASE64`)
     - Network egress policies to allow image push/pull operations
   - Either approach adds operational overhead and security considerations for credential management

## Findings

### Architectural Mismatch

**EnvBuilder Model:**
- Self-mutating, root-capable runtime
- Transforms the running container into the final environment
- Builds image using Kaniko and unpacks layers in-place into the container's root filesystem

**DevWorkspace Model:**
- Immutable infrastructure
- Non-root execution with restricted security policies
- Starts from prebuilt, stable images

### Compatibility Analysis

**Conclusion:** EnvBuilder is fundamentally incompatible with standard, restricted DevWorkspace pods due to opposing lifecycle assumptions.

#### Why it Fails

1. **Permission Requirements:** EnvBuilder needs to:
   - Perform filesystem remounts
   - Write to system paths (`/usr`, `/etc`, `/.envbuilder`)
   - Execute with elevated privileges

2. **DevWorkspace Restrictions:**
   - Non-root user enforcement
   - `allowPrivilegeEscalation: false`
   - Dropped capabilities (`drop: ALL`)
   - Read-only root filesystem in many configurations

3. **Lifecycle Conflict:**
   - DevWorkspace: Start from finished image → run workspace
   - EnvBuilder: Start from unfinished image → transform during execution → run workspace

### Possible Integration Paths

#### Option 1: External Build Workflow (Most Practical)
**Recommended for production**

1. Run EnvBuilder in an external Job or CI pipeline
2. Build and push the resulting OCI image to a registry
3. Start DevWorkspace from the prebuilt, immutable image

**Blockers:**
- EnvBuilder currently lacks a "build-and-exit" mode
- Requires upstream changes to support: `build → push → exit` workflow

**Additional Considerations:**
- **Registry Selection:**
  - **OpenShift Internal Registry:** Keeps images within the cluster but requires:
    - RBAC configuration for build Jobs to push images
    - Service account token management
    - Image pull secrets for DevWorkspaces to consume images
    - Route/service exposure configuration
  - **External Registry (Docker Hub, Quay.io, GitHub Container Registry):** Provides better availability but requires:
    - Registry credentials (username/password or access tokens)
    - Kubernetes Secrets to securely inject credentials into build Jobs
    - Base64-encoded Docker config (`ENVBUILDER_DOCKER_CONFIG_BASE64`)
    - Network policies allowing egress to external registries
    - Cost considerations for private registries
- **Security:** Both approaches require careful credential management and access control to prevent unauthorized image access or modification

#### Option 2: Elevated Privileges
Enable `privileged: true` within the DevWorkspace

**Concerns:**
- Significant security implications
- Violates DevWorkspace security model
- Not recommended for multi-tenant environments

#### Option 3: Upstream EnvBuilder Changes
Modify EnvBuilder to decouple image building from runtime filesystem mutation

**Requirements:**
- Add build-only execution mode
- Support building without mutating the running container
- Clean exit after image push

## Repository Structure

```
.
├── envbuilder-inside-k8s-pod/              # Standard K8s Pod example
├── envbuilder-inside-devworkspace/         # Failed DevWorkspace attempt
├── envbuilder-separate-job-build-devworkspace-image/  # Build Job approach
└── README.md
```

## Conclusion

EnvBuilder cannot currently be used as a runtime component within DevWorkspace pods due to fundamental architectural incompatibilities. The most viable path forward for native `devcontainer.json` support in Eclipse Che would be:

1. **Short-term:** Implement a separate build service that uses EnvBuilder (or similar tooling) to pre-build images from `devcontainer.json` before workspace startup
2. **Long-term:** Either:
   - Work with upstream EnvBuilder to add build-only mode support
   - Develop Che-specific tooling for `devcontainer.json` processing that fits the DevWorkspace security model

## Related Issues

- [Eclipse Che #23458](https://github.com/eclipse/che/issues/23458) - Native devcontainer.json support

## References

- [EnvBuilder GitHub Repository](https://github.com/coder/envbuilder)
- [DevWorkspace Operator](https://github.com/devfile/devworkspace-operator)
- [devcontainer.json specification](https://containers.dev/)
