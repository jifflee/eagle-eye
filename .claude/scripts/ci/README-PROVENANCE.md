# SLSA Provenance Scripts

This directory contains scripts for generating and verifying SLSA provenance attestations for build artifacts.

## Scripts

### `generate-slsa-provenance.sh`

Generates SLSA-compatible provenance metadata for build artifacts.

**Purpose:**
- Create cryptographic attestations linking artifacts to their source and build
- Support SLSA levels 1-3
- Optional signing with cosign/Sigstore
- Automatic build environment detection

**Usage:**
```bash
# Basic usage
./generate-slsa-provenance.sh \
  --artifact dist/app \
  --artifact-type binary \
  --slsa-level 2

# With signing
./generate-slsa-provenance.sh \
  --artifact dist/app.tar.gz \
  --artifact-type package \
  --sign

# With upload to artifact storage
./generate-slsa-provenance.sh \
  --artifact dist/release.zip \
  --artifact-type package \
  --sign \
  --upload
```

**Options:**
- `--artifact PATH` - Path to artifact (required)
- `--artifact-type TYPE` - Type: container|package|binary (required)
- `--output PATH` - Output path for provenance file
- `--slsa-level LEVEL` - SLSA level 1-3 (default: 2)
- `--builder-id ID` - Builder identity (auto-detected)
- `--source-repo REPO` - Source repository (auto-detected from git)
- `--source-commit SHA` - Source commit (auto-detected from git)
- `--sign` - Sign with cosign
- `--upload` - Upload to .provenance/builds/
- `--verbose` - Show detailed output
- `--quiet` - Suppress output

**Exit Codes:**
- `0` - Success
- `1` - Generation failed
- `2` - Tool error or misconfiguration

**Requirements:**
- `jq` (required)
- `git` (required)
- `sha256sum` (required)
- `cosign` (optional, for signing)

### `verify-slsa-provenance.sh`

Verifies SLSA provenance attestations for artifacts.

**Purpose:**
- Validate provenance structure and format
- Verify artifact digest matches provenance
- Enforce minimum SLSA level requirements
- Verify builder trust and source repository
- Validate cosign signatures

**Usage:**
```bash
# Basic verification
./verify-slsa-provenance.sh \
  --artifact dist/app \
  --provenance dist/app.provenance.json \
  --min-slsa-level 2

# Strict verification with signatures
./verify-slsa-provenance.sh \
  --artifact dist/app.tar.gz \
  --min-slsa-level 3 \
  --require-signature

# With trust verification
./verify-slsa-provenance.sh \
  --artifact dist/release.zip \
  --trusted-builders config/trusted-builders.txt \
  --trusted-repos config/trusted-repos.txt
```

**Options:**
- `--artifact PATH` - Path to artifact (required)
- `--provenance PATH` - Path to provenance file (default: <artifact>.provenance.json)
- `--min-slsa-level LEVEL` - Minimum SLSA level 1-4 (default: 1)
- `--require-signature` - Require cosign signature
- `--trusted-builders FILE` - File with trusted builder IDs
- `--trusted-repos FILE` - File with trusted source repos
- `--output-dir DIR` - Output directory for reports
- `--format FORMAT` - Output format: json|summary
- `--verbose` - Show detailed output
- `--quiet` - Suppress output

**Exit Codes:**
- `0` - Verification passed
- `1` - Verification failed
- `2` - Tool error or misconfiguration

**Requirements:**
- `jq` (required)
- `sha256sum` (required)
- `cosign` (optional, for signature verification)

### `deployment-provenance-gate.sh`

Deployment gate that verifies all artifacts have valid provenance.

**Purpose:**
- Pre-deployment validation gate
- Integrates with package-attestation.sh and package-reputation.sh
- Verifies all artifacts in deployment directory
- Enforces minimum SLSA levels
- Generates deployment gate report

**Usage:**
```bash
# Run deployment gate (default config)
./deployment-provenance-gate.sh

# Strict mode
./deployment-provenance-gate.sh \
  --min-slsa-level 3 \
  --require-signatures \
  --strict

# Custom artifact locations
./deployment-provenance-gate.sh \
  --artifacts-dir build/output \
  --provenance-dir .provenance
```

**Options:**
- `--artifacts-dir DIR` - Directory with artifacts (default: dist/)
- `--provenance-dir DIR` - Directory with provenance (default: .provenance/)
- `--min-slsa-level LEVEL` - Minimum SLSA level (default: 2)
- `--require-signatures` - Require all artifacts to be signed
- `--skip-npm-packages` - Skip npm package checks
- `--skip-containers` - Skip container verification
- `--output-dir DIR` - Output directory for reports
- `--strict` - Strict mode: fail on any issue
- `--verbose` - Show detailed output

**Exit Codes:**
- `0` - All checks passed
- `1` - Gate failed
- `2` - Tool error or misconfiguration

**Requirements:**
- `jq` (required)
- All requirements from verify-slsa-provenance.sh
- Optional: package-attestation.sh
- Optional: package-reputation.sh

## Integration Examples

### CI/CD Pipeline

**GitHub Actions:**
```yaml
- name: Generate Provenance
  run: |
    for artifact in dist/*; do
      ./scripts/ci/generate-slsa-provenance.sh \
        --artifact "$artifact" \
        --artifact-type binary \
        --slsa-level 2 \
        --sign \
        --upload
    done

- name: Deployment Gate
  run: |
    ./scripts/ci/deployment-provenance-gate.sh \
      --min-slsa-level 2 \
      --strict
```

**GitLab CI:**
```yaml
build:
  script:
    - make build
    - |
      for artifact in dist/*; do
        ./scripts/ci/generate-slsa-provenance.sh \
          --artifact "$artifact" \
          --artifact-type package \
          --slsa-level 2
      done

deploy:
  before_script:
    - ./scripts/ci/deployment-provenance-gate.sh --min-slsa-level 2
  script:
    - make deploy
```

### Local Development

**Generate provenance for local builds:**
```bash
# Build your application
make build

# Generate provenance
./scripts/ci/generate-slsa-provenance.sh \
  --artifact dist/myapp \
  --artifact-type binary \
  --slsa-level 1
```

**Verify before deploying:**
```bash
./scripts/ci/verify-slsa-provenance.sh \
  --artifact dist/myapp \
  --min-slsa-level 1
```

## Testing

Run the test suite:
```bash
./tests/ci/test-slsa-provenance.sh
```

Tests cover:
- Script existence and executability
- Help output
- Provenance generation
- Provenance structure validation
- Provenance verification
- Tamper detection
- SLSA level enforcement
- Deployment gate functionality

## Output Files

### Provenance Files
- `<artifact>.provenance.json` - SLSA provenance attestation
- `<artifact>.provenance.json.sig` - Cosign signature (if signed)

### Reports
- `.provenance/verification-report.json` - Verification results
- `.provenance/deployment-gate-report.json` - Gate status

### Uploaded Artifacts
- `.provenance/builds/<timestamp>/` - Timestamped builds
- `.provenance/builds/latest` - Symlink to latest build

## Troubleshooting

### Common Issues

**Issue:** Provenance generation fails with "artifact not found"

**Solution:** Ensure the artifact path is correct and the file exists:
```bash
ls -la dist/myapp
```

**Issue:** Verification fails with digest mismatch

**Cause:** Artifact was modified after provenance generation

**Solution:** Regenerate provenance:
```bash
./scripts/ci/generate-slsa-provenance.sh \
  --artifact dist/myapp \
  --artifact-type binary
```

**Issue:** Cosign signing fails

**Solution:** Install cosign:
```bash
curl -sSfL https://raw.githubusercontent.com/sigstore/cosign/main/install.sh | sh
```

**Issue:** Deployment gate fails with "no provenance found"

**Solution:** Generate provenance for all artifacts before running gate:
```bash
for artifact in dist/*; do
  ./scripts/ci/generate-slsa-provenance.sh \
    --artifact "$artifact" \
    --artifact-type binary
done
```

## Security Best Practices

1. **Always sign provenance in CI/CD**
   ```bash
   --sign  # Use cosign for cryptographic signatures
   ```

2. **Enforce minimum SLSA level 2 for production**
   ```bash
   --min-slsa-level 2  # Requires authenticated build service
   ```

3. **Verify provenance before deployment**
   ```bash
   ./deployment-provenance-gate.sh --strict
   ```

4. **Use trusted builder verification**
   ```bash
   --trusted-builders config/trusted-builders.txt
   ```

5. **Archive provenance with artifacts**
   ```bash
   --upload  # Store in .provenance/builds/
   ```

## Related Documentation

- [SLSA_PROVENANCE.md](../../docs/ci/SLSA_PROVENANCE.md) - Complete integration guide
- [PACKAGE_ATTESTATION.md](../../docs/ci/PACKAGE_ATTESTATION.md) - NPM package attestation
- [PACKAGE_REPUTATION.md](../../docs/ci/PACKAGE_REPUTATION.md) - Supply chain security
- [SBOM_INTEGRATION.md](../../docs/ci/SBOM_INTEGRATION.md) - Software Bill of Materials

## References

- [SLSA Framework](https://slsa.dev/)
- [in-toto Attestation](https://github.com/in-toto/attestation)
- [Sigstore/cosign](https://docs.sigstore.dev/)
- [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds)
