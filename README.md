# virtio-host-msi

Hosts the Red Hat VirtIO Guest Tools installer (`virtio-win-gt-x64.msi`) inside an
OpenShift cluster, and provides a PowerShell script that Windows VMs can use to fetch
it and repair a bad post-migration VirtIO install.

## Why this exists

Windows VMs migrated to OpenShift Virtualization (RHEL-256976) can end up with the
guest agent tools (`BalloonService` / `blnsvr.exe`) installed under `C:\Windows\Drivers`.
That path:

- Conflicts with the real Windows `C:\Windows\drivers` directory, because NTFS is
  case-insensitive but the tooling that wrote it was not.
- Has world read/write permissions.

The fix is to stop the service, reinstall the VirtIO Guest Tools into
`C:\Program Files\Virtio-Win`, and delete the wrongly-cased `Drivers` directory.

The installer normally comes from the virtio-win ISO. Hotplugging that ISO as a
DataVolume does not work: it shows up in Windows as a raw disk (`sdb`) with no drive
letter, because Windows only reads ISO9660 from optical drives. This repo avoids that by
serving the MSI over HTTP from inside the cluster instead.

## Repository layout

| Path | Contents |
|---|---|
| `kustomization.yaml` | Kustomize entry point. Applies `deployment/` and generates the script ConfigMap from `bin/`. |
| `deployment/` | Namespace, Deployment, and Service for the in-cluster web server. |
| `bin/Fix-VirtioPaths.ps1` | PowerShell script to run inside each affected Windows VM. Also served by the web server. |

## How the MSI host works

The deployment runs a single pod in the `virtio-msi-host` namespace:

1. Init container `copy-iso` runs
   `registry.redhat.io/container-native-virtualization/virtio-win-rhel9:v4.22` and copies
   `/disk/virtio-win.iso` into an `emptyDir`.
2. Init container `extract-msi` runs `registry.redhat.io/ubi9/httpd-24:9.8-1793639139`,
   extracts `virtio-win-gt-x64.msi` from the ISO with `bsdtar`, and writes a
   `virtio-win-gt-x64.msi.sha256` checksum file next to it.
3. Container `httpd` serves the extracted files read-only on port 8080 through the
   `virtio-msi-host` ClusterIP service.

`bin/Fix-VirtioPaths.ps1` is packaged into the `virtio-msi-host-scripts` ConfigMap by a
kustomize `configMapGenerator` and mounted read-only at `/var/www/html/scripts`. The
generated ConfigMap name carries a content hash, so editing the script and re-applying
rolls the pod automatically.

The files are then available inside the cluster at:

```
http://virtio-msi-host.virtio-msi-host.svc.cluster.local:8080/virtio-win-gt-x64.msi
http://virtio-msi-host.virtio-msi-host.svc.cluster.local:8080/virtio-win-gt-x64.msi.sha256
http://virtio-msi-host.virtio-msi-host.svc.cluster.local:8080/scripts/Fix-VirtioPaths.ps1
```

## Prerequisites

- The cluster nodes can pull from `registry.redhat.io` (the global pull secret normally
  covers this). Disconnected clusters need both images mirrored, and the image references
  in `deployment/deployment.yml` changed to match.
- Use the `virtio-win-rhel9` tag that matches your OpenShift version. This repo uses `v4.22`.
- Windows VMs must be able to resolve and reach `*.svc.cluster.local`. This works for VMs
  on the default pod network (masquerade). VMs attached only to a bridge or secondary
  network cannot reach the service.
- The service is plain HTTP with no authentication. Add a `NetworkPolicy` if you need to
  restrict who can reach it.

## Deploy

```bash
oc apply -k .
oc -n virtio-msi-host rollout status deploy/virtio-msi-host
```

Check that the MSI was extracted and is being served:

```bash
oc -n virtio-msi-host logs deploy/virtio-msi-host -c extract-msi
oc -n virtio-msi-host get pods
```

The `extract-msi` log should list `virtio-win-gt-x64.msi` and its `.sha256` file.

## Run the script

Run the script inside each affected Windows VM from an elevated PowerShell session (Run
as Administrator). The VM can fetch it straight from the in-cluster host, so nothing has
to be copied in by hand:

```powershell
$base = 'http://virtio-msi-host.virtio-msi-host.svc.cluster.local:8080'
(New-Object System.Net.WebClient).DownloadFile("$base/scripts/Fix-VirtioPaths.ps1", 'C:\Windows\Temp\Fix-VirtioPaths.ps1')
powershell.exe -ExecutionPolicy Bypass -File C:\Windows\Temp\Fix-VirtioPaths.ps1
```

The script is plain HTTP from inside the cluster, so review it (or compare it with
`bin/Fix-VirtioPaths.ps1` in this repo) before running. You can also copy it into the
guest yourself, for example over RDP, WinRM, or your configuration management tool, and
use the options below.

```powershell
# Default: downloads the MSI from the in-cluster host above
.\Fix-VirtioPaths.ps1

# Use a different URL for the MSI (a sibling .sha256 file must exist at "<url>.sha256")
.\Fix-VirtioPaths.ps1 -MsiUrl http://host:8080/virtio-win-gt-x64.msi

# Use a local MSI instead of downloading (no hash check)
.\Fix-VirtioPaths.ps1 -MsiPath D:\virtio-win-gt-x64.msi

# Proceed when both 'Drivers' and 'drivers' exist under C:\Windows
.\Fix-VirtioPaths.ps1 -Force
```

### What the script does

1. Stops `BalloonService` and any running `blnsvr.exe`, so the old files are unlocked.
2. Downloads the MSI and verifies its SHA256 against the `.sha256` file (or uses `-MsiPath`).
3. Installs it silently with `msiexec /qn /norestart`. The MSI log is written to
   `C:\Windows\Temp\virtio-gt-msi.log`. Exit codes 0 and 3010 count as success. On 3010,
   schedule a reboot.
4. Confirms `BalloonService` runs from `C:\Program Files\Virtio-Win\Balloon\blnsvr.exe`,
   repointing it with `sc.exe config` if the installer left the old path.
5. Deletes the wrongly-cased `C:\Windows\Drivers` directory. It matches the exact-case
   name only, and verifies afterwards that the real `C:\Windows\drivers` still exists.
6. Warns if `C:\Program Files\Virtio-Win` is writable by Everyone or Users.

If both `Drivers` and `drivers` exist, Windows resolves paths case-insensitively and a
delete could remove the wrong one. The script stops in that case unless `-Force` is
passed. Test on a clone or snapshot first.

The full transcript is written to `C:\Windows\Temp\virtio-cleanup.log`. Any failure
throws, so a non-zero exit code means the fix did not complete.

## Remove the MSI host

```bash
oc delete -k .
```

## Status

Verified locally with podman: both images pull, `cp` and `bsdtar` exist as assumed, the
MSI extracts, and httpd serves it with a matching checksum. The rendered kustomization
references the hashed ConfigMap, and httpd serves a script mounted at `/var/www/html/scripts`
byte-for-byte.

Not yet tested:

- The deployment on a cluster.
- A Windows VM reaching the service and running the script.
- Whether the MSI repoints an existing `BalloonService` by itself. The script's
  `sc.exe config` fallback covers it if not.
- The case where both `Drivers` and `drivers` exist, which needs `-Force`.
