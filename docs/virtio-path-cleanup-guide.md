# Windows VM VirtIO Path Cleanup Guide (RHEL-256976)

This guide describes how to correct Windows VMs migrated to OpenShift Virtualization
(RHEL-256976) where the guest agent tools were installed to an incorrect path,
`C:\Windows\Drivers`. That path conflicts with the existing `C:\Windows\drivers` directory
and has world read/write permissions.

The fix is delivered by the repository [bry-tam/virtio-host-msi](https://github.com/bry-tam/virtio-host-msi). It has
two parts:

1. A small deployment in the cluster that hosts the files the fix needs and makes them
   available to the VMs.
2. A PowerShell script (`bin/Fix-VirtioPaths.ps1`) that is run in each affected VM and
   performs the cleanup.

> 🚨 Test on a clone or snapshot of one VM first. Scheduling a maintenance window is
> recommended.

## Prerequisites

- `oc` access to the cluster with permission to create a namespace, a deployment, and a
  route.
- In disconnected clusters, mirroring the images used by the deployment may be required.
- The VMs can resolve the Route host name to the cluster ingress.
- Administrator access inside each Windows VM (RDP, console, WinRM, or your configuration
  management tool).

> ⚠️ *WARNING*  
> The Route is plain HTTP and has no authentication. The MSI and the script are not
> encrypted or authenticated in transit, and the `.sha256` file only catches corruption,
> not tampering. Anyone who can reach the ingress can download them. Restrict access (for
> example with a Route IP allowlist annotation) or delete the Route when finished (Step 6).

## Step 1: Deploy the MSI host and Route (once per cluster)

This step deploys a small web server in the cluster that hosts the installer and the script
needed for the cleanup. The VMs download both over the network, so no virtual media has to
be attached and the VMs do not need to be rebooted. See the repository `README.md` for how
the deployment works.

1. **Clone and review the repository:**
   Clone the repository and open `kustomization.yaml`.

   ```bash
   git clone https://github.com/bry-tam/virtio-host-msi.git
   cd virtio-host-msi
   ```

2. **Update the images for your environment:**
   Review and update the `images:` section of `kustomization.yaml`. For example, set
   `newName` to your mirror registry for a disconnected cluster, and set `newTag` for the
   `virtio-win-rhel9` image to the tag that matches your OpenShift version. Preview the
   result before applying it:

   ```bash
   oc kustomize . | grep 'image:'
   ```

3. **Deploy the MSI host:**
   Apply the kustomization and wait for the rollout:

   ```bash
   oc apply -k .
   oc -n virtio-msi-host rollout status deploy/virtio-msi-host
   ```

4. **Verify the deployment:**
   Confirm that the MSI and its checksum file were extracted, and that the pod is Ready:

   ```bash
   oc -n virtio-msi-host logs deploy/virtio-msi-host -c extract-msi
   oc -n virtio-msi-host get pods,svc,route
   ```

   The log should list `virtio-win-gt-x64.msi` and `virtio-win-gt-x64.msi.sha256`, and the
   pod should show `1/1` Ready.

## Step 2: Get the URL

This step finds the address the VMs use to download the installer and the script from the
MSI host.

1. **Get the Route URL:**
   Print the base URL of the Route:

   ```bash
   oc -n virtio-msi-host get route virtio-msi-host -o jsonpath='http://{.spec.host}{"\n"}'
   ```

2. **Note the URL for the VMs:**
   The output looks like `http://virtio-msi-host-virtio-msi-host.apps.example.com`. Use
   this value as `<route-host-url>` in the steps below.

## Step 3: Open PowerShell as Administrator in the VM

This step prepares an administrator PowerShell session in each affected VM, confirms the VM
can reach the MSI host, and records the current state so it can be compared after the fix.

1. **Open PowerShell as Administrator:**
   In each affected VM, right-click PowerShell and choose Run as administrator. Run every
   command in Steps 3 to 5 in this same window.

2. **Check that the VM can reach the MSI host:**
   Set the base URL and test the connection:

   ```powershell
   $base = '<route-host-url>'
   Test-NetConnection ([uri]$base).Host -Port 80
   ```

   `TcpTestSucceeded` must be `True`. If the name does not resolve or the connection fails,
   the VM cannot reach the ingress; see the Troubleshooting section.

3. **Record the current state:**
   Capture the service path and the directories so the result can be compared:

   ```powershell
   Get-CimInstance Win32_Service -Filter "Name='BalloonService'" | Select-Object Name, State, PathName
   Get-ChildItem C:\Windows -Directory | Where-Object { $_.Name -like 'drivers' } | Select-Object Name
   icacls C:\Windows\drivers
   ```

   An affected VM shows `BalloonService` with a `PathName` under `C:\Windows\Drivers` and a
   directory literally named `Drivers` (capital D) in addition to the real `drivers`
   directory.

## Step 4: Download and run the script

This step downloads the cleanup script from the MSI host and runs it in the VM. The script
installs the VirtIO Guest Tools from the same host and removes the incorrect directory.

1. **Download the script:**
   In the same window, download the script from the MSI host:

   ```powershell
   (New-Object System.Net.WebClient).DownloadFile("$base/scripts/Fix-VirtioPaths.ps1", 'C:\Windows\Temp\Fix-VirtioPaths.ps1')
   ```

2. **Review the script:**
   Review `C:\Windows\Temp\Fix-VirtioPaths.ps1`, or compare it with
   `bin/Fix-VirtioPaths.ps1` in the repository.

3. **Run the script:**

   ```powershell
   C:\Windows\Temp\Fix-VirtioPaths.ps1 -MsiUrl "$base/virtio-win-gt-x64.msi"
   ```

   The script runs under the VM's normal PowerShell execution policy; no step here changes
   it. A file downloaded with `System.Net.WebClient` carries no internet-zone mark, so the
   `RemoteSigned` policy (the Windows Server default) runs it. If the VM uses `Restricted`
   (the Windows client default) or `AllSigned`, follow your own policy for allowing the
   script to run. You can also copy the script into the VM yourself (RDP file copy, WinRM,
   or configuration management).

4. **Use other options if needed:**
   Run from the same window:

   ```powershell
   # Use a local MSI instead of downloading it (no hash check)
   C:\Windows\Temp\Fix-VirtioPaths.ps1 -MsiPath D:\virtio-win-gt-x64.msi

   # Proceed when both "Drivers" and "drivers" exist under C:\Windows
   C:\Windows\Temp\Fix-VirtioPaths.ps1 -MsiUrl "$base/virtio-win-gt-x64.msi" -Force
   ```

### What the script does

In order:

1. Checks whether both `Drivers` and `drivers` exist under `C:\Windows`. If they do and
   `-Force` was not passed, it stops before changing anything (see below).
2. Stops `BalloonService` and any running `blnsvr.exe` so the old files are unlocked.
3. Downloads the MSI from the host and verifies its SHA256 against the `.sha256` file.
4. Installs it with `msiexec /qn /norestart`. The MSI log is
   `C:\Windows\Temp\virtio-gt-msi.log`. Exit codes 0 and 3010 count as success; on 3010
   schedule a reboot.
5. Confirms `BalloonService` runs from
   `C:\Program Files\Virtio-Win\Balloon\blnsvr.exe`, repointing it with `sc.exe config` if
   the installer left the old path, then starts it.
6. Deletes the incorrect-case `C:\Windows\Drivers` directory. It matches the exact-case name
   only and verifies afterwards that the real `C:\Windows\drivers` still exists.
7. Prints the ACL (`icacls`) of both `C:\Windows\drivers` and `C:\Program Files\Virtio-Win`,
   and warns if either is writable by Everyone or Users.

Because Windows resolves paths case-insensitively, a delete could remove the wrong directory
if both `Drivers` and `drivers` exist. In that case, unless `-Force` is passed, the script
prints a white-on-red message block, exits with code 2, and changes nothing. The block
contains the command to run again: the parameters you passed, plus `-Force`. Test that case
on a clone first.

Any other failure throws, so a non-zero exit code means the fix did not complete. The full
transcript is in `C:\Windows\Temp\virtio-cleanup.log`.

## Step 5: Verify

This step confirms that the fix worked in the VM and that the guest agent is healthy.

1. **Check the VM state:**
   In the same PowerShell window, run:

   ```powershell
   Get-CimInstance Win32_Service -Filter "Name='BalloonService'" | Select-Object Name, State, PathName
   Get-ChildItem C:\Windows -Directory | Where-Object { $_.Name -ceq 'Drivers' }
   Get-Item C:\Windows\drivers
   icacls C:\Windows\drivers
   icacls "C:\Program Files\Virtio-Win"
   ```

2. **Compare the results:**
   The output should show:

   - `BalloonService` is `Running` and its `PathName` is
     `"C:\Program Files\Virtio-Win\Balloon\blnsvr.exe"`.
   - The `Drivers` (capital D) query returns nothing, and the real `C:\Windows\drivers`
     still exists.
   - The ACLs on both `C:\Windows\drivers` and `C:\Program Files\Virtio-Win` do not grant
     Everyone or Users write access (no `(W)`, `(M)`, or `(F)` entries for those accounts).

3. **Confirm the guest agent in OpenShift (optional):**
   Check that the guest agent is healthy:

   ```bash
   oc get vmi <name> -n <namespace> -o jsonpath='{.status.conditions}'
   ```

## Step 6: Remove the MSI host and Route

This step removes the MSI host from the cluster once the cleanup is finished, so the
installer and script are no longer served over plain HTTP.

1. **Confirm all VMs are corrected:**
   Make sure every affected VM has been fixed and verified (Steps 3 to 5).

2. **Remove the deployment and Route:**
   From the repository directory, delete everything the kustomization created:

   ```bash
   oc delete -k .
   ```

## Troubleshooting

- **Name does not resolve or connection fails in Step 3.** The VM's DNS cannot resolve the
  Route host, or its network cannot reach the ingress. Fix DNS or routing, or copy the script
  and `virtio-win-gt-x64.msi` into the VM another way (file share, RDP, WinRM, configuration
  management) and run
  `C:\Windows\Temp\Fix-VirtioPaths.ps1 -MsiPath <path-to-msi>`.
- **SHA256 mismatch.** Re-check the `extract-msi` log from Step 1 and re-run.
- **MSI failure.** Read `C:\Windows\Temp\virtio-gt-msi.log`. Drivers installed by the MSI
  can fail on a running guest; in that case schedule a reboot and re-run the script.
- **Exit code 3010.** Reboot the VM in your maintenance window, then repeat Step 5.
- **Red message block about `Drivers` and `drivers` both existing.** Confirm on a clone, then
  run the command shown in the block (it already includes `-Force`).
- **Re-running.** The script can be re-run: it stops the service, reinstalls, and only
  deletes the wrong-case directory if it is still present.
