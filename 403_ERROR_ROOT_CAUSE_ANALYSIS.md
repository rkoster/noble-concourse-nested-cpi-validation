# Root Cause Analysis: 403 Forbidden Error on Stemcell Image Pull

## Error Context

When deploying zookeeper to the warden-lite director using light stemcells, the following error occurs:

```
Error: CPI error 'Bosh::Clouds::CloudError' with message 'Creating VM with agent ID '{{...}}': 
Creating container: running image plugin create: fetching image reference: creating image: 
creating image source: Requesting bearer token: received unexpected HTTP status: 403 Forbidden
```

## Key Observation

The user notes: "The stemcell image does not require authentication and should be pullable without auth (this has already been confirmed to work on the docker cpi)."

This suggests:
1. The stemcell image is public and should not require authentication
2. The docker-cpi successfully pulls the same image
3. The warden-cpi is failing to pull the same image

## Hypothesis 1: Different Image References

### Docker CPI vs Warden CPI Behavior

The docker-cpi and warden-cpi may be using different image references or registries:

- **Docker CPI**: May be using `docker.io/library/ubuntu:jammy` (Docker Hub - public)
- **Warden CPI**: May be using `ghcr.io/cloudfoundry/package/ubuntu-jammy-stemcell:latest` (GHCR - may require auth)

### Evidence

From the warden-lite README:
```yaml
**Supported Registries**:
- ✅ Public Docker Hub: `docker.io/library/ubuntu:jammy`
- ✅ Public GHCR: `ghcr.io/org/repo:tag` (public only)
- ⚠️ Private registries require authentication
```

GHCR requires authentication even for pulling public images in some contexts (especially from CI/CD environments or when rate-limited).

## Hypothesis 2: Registry Authentication Requirements

### GitHub Container Registry (ghcr.io) Behavior

GHCR has different authentication requirements compared to Docker Hub:

1. **Docker Hub**:
   - Anonymous pulls allowed for public images
   - Rate limits: 100 pulls per 6 hours (anonymous), 200 pulls per 6 hours (authenticated)

2. **GitHub Container Registry (ghcr.io)**:
   - Requires authentication for all pulls (even public images) in certain contexts
   - CI/CD environments often require authentication
   - Container runtimes need GitHub token for any GHCR pulls

### Why Docker CPI Works

The docker-cpi environment may have:
1. Pre-configured credentials for ghcr.io
2. Using Docker Hub instead of GHCR
3. Running in a context where GHCR allows anonymous pulls

## Hypothesis 3: Garden Configuration Difference

### Garden Image Plugin Configuration

The warden-lite director's Garden may not be configured with proper registry credentials:

```yaml
instance_groups:
- name: warden-lite
  jobs:
  - name: garden
    properties:
      garden:
        image_plugin:
          registry_endpoint: "https://ghcr.io"
          # Missing: registry_username and registry_password
```

### Required Configuration

For GHCR access from Garden:
```yaml
garden:
  image_plugin:
    registry_endpoint: "https://ghcr.io"
    registry_username: ((github_username))
    registry_password: ((github_token))
```

## Recommended Solutions

### Solution 1: Use Docker Hub Instead of GHCR (Immediate)

**Change**: Update light stemcell creation to use Docker Hub public images:

```bash
./create-light-stemcell.sh docker.io/library/ubuntu:jammy light-jammy.tgz
```

**Rationale**:
- Docker Hub allows anonymous pulls for public images
- No authentication configuration required
- Proven to work in various environments

### Solution 2: Add GHCR Authentication to Garden (Complete)

**Change**: Update warden-lite deployment to configure Garden with GHCR credentials:

1. Add to `warden-lite-ops.yml`:
```yaml
- type: replace
  path: /instance_groups/name=warden-lite/jobs/name=garden/properties/garden/image_plugin?
  value:
    registry_endpoint: "https://ghcr.io"
    registry_username: ((ghcr_username))
    registry_password: ((ghcr_token))
```

2. Add credentials to vars.yml:
```yaml
ghcr_username: github-username
ghcr_token: ghp_xxxxxxxxxxxxx
```

### Solution 3: Pre-pull Images (Workaround)

**Change**: Download and re-upload images to a registry that doesn't require auth:

```bash
docker pull ghcr.io/cloudfoundry/package/ubuntu-jammy-stemcell:latest
docker tag ghcr.io/cloudfoundry/package/ubuntu-jammy-stemcell:latest localhost:5000/stemcell:jammy
docker push localhost:5000/stemcell:jammy

./create-light-stemcell.sh localhost:5000/stemcell:jammy light-jammy.tgz
```

## Recommendation

**Implement Solution 1 first** (use Docker Hub) as it:
- Requires no configuration changes
- Works immediately
- Is already documented in the README
- Matches the user's expectation of "should be pullable without auth"

**Then document Solution 2** for users who need GHCR specifically.

## Testing Plan

1. **Test with Docker Hub**:
   ```bash
   ./create-light-stemcell.sh docker.io/library/ubuntu:jammy light-jammy.tgz
   source warden-lite.env
   bosh upload-stemcell light-jammy.tgz
   ./deploy-zookeeper.sh
   ```

2. **Verify image pull in Garden logs**:
   ```bash
   source ../bosh.env
   bosh -d warden-lite ssh -c "sudo tail -100 /var/vcap/sys/log/garden/garden.log | grep 'pulling image'"
   ```

3. **Expected result**: Image pulls successfully without 403 error
