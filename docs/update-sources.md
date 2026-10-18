# Build sources and updates

App Settings → **Builds & Updates** controls the update feed and the images used by
the host updater. Saving a preference does not replace images or restart services.

- **Current installation** follows each configured image reference and the panel
  repository/ref recorded by the host updater. Older installations without Git
  provenance do not guess that they follow official `main`.
- **Official stable** selects `5stackgg/5stack-panel` at `main` and the seven
  `ghcr.io/5stackgg/<component>:latest` images.
- **Official beta** selects that repository at `beta` and the seven `:beta`
  images. The publisher must create that ref and publish every image before the
  channel can be applied. A missing beta build never falls back to stable.
- **Custom** accepts seven explicit image references. They may mix forks and
  intentionally selected official images. Tracking a GitHub panel repository/ref
  is optional; leaving it off keeps the existing host checkout.

Tags follow a build channel. Digest references pin exact builds and do not produce
floating-tag update notices. Runtime server and streamer images apply to new jobs;
active jobs are not replaced. Third-party plugins retain their configured images.

## Applying a source

Use the commands shown by the settings page from the panel checkout on the host.
They fetch the selected GitHub repository/ref, check it out, and record its
provenance before running `./update.sh`. The commands first verify that the
selected ref contains `utils/update_source.sh`; older panel refs that cannot
honor the saved policy stop before checkout or apply. Official channels require
this feature to be merged into their panel ref. For image-only sources, run `./update.sh`
in the existing compatible checkout. Standard host updates still include the
panel's database migration and maintenance steps.

Before changing cluster resources, the updater validates the profile, verifies the
Git checkout, and checks that **all seven selected images can be read from their
registries**. Public GHCR and Docker Hub images are supported; registries requiring
credentials cannot pass this anonymous preflight. Any unavailable image stops the
update. Images are never substituted from another feed.

The renderer overrides API (including Hasura's migrations), web, demo-parser,
connector and NVIDIA connector images. It configures the API's streamer and both
server runtime images. An explicit official/custom selection replaces the legacy
`SERVER_IMAGE` override; Current installation preserves it. Other resources and
plugin workloads keep their manifests. Mutable tags use `imagePullPolicy: Always`.

After applying a source, the existing Update action can restart services whose
configured reference already matches the selected reference. Switching references
or applying panel manifests requires the host updater. The settings table shows
the installed image/digest, selected image/digest, unavailable builds and pending
source switches.

## Persistence and access

The named `5stack-update-source` ConfigMap contains `profile.json` and the host's
`installed.json` Git provenance. The base manifest intentionally declares no data:
ordinary overlay regeneration preserves choices saved through the API. The API
can read and patch only this named ConfigMap; administrator access and optimistic
resource-version checks protect saves. Do not put registry credentials in it.

Without the ConfigMap, the API follows installed images and exposes the settings
as read-only until the host manifests are updated. A corrupt or unreadable selected
profile stops update checks instead of selecting a different feed.
