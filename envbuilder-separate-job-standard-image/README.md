# EnvBuilder Separate Job - Standard Image

This approach uses the **official EnvBuilder image** (`ghcr.io/coder/envbuilder:latest`) instead of a custom build.

## Usage

```bash
export REGISTRY_USERNAME=<your-username>
export REGISTRY_PASSWORD=<your-password>
./build-with-standard-image.sh
```

## Difference from Custom Image Approach

The main difference between this and the custom image approach in `../envbuilder-separate-job-build-devworkspace-image/` is:

- **This approach**: Uses `ENVBUILDER_IMAGE=ghcr.io/coder/envbuilder:latest` (official upstream image)
- **Custom approach**: Uses `ENVBUILDER_IMAGE=quay.io/rokumar/envbuilder:latest` (fork with potential custom patches)

## Known Issues

Since this uses the standard EnvBuilder image, it will:
1. Build and push the image successfully
2. **Continue running** with `sleep infinity` after the push (not exit)
3. The Job pod will remain running indefinitely

This is the default behavior of standard EnvBuilder - it does not have a "build-and-exit" mode.
