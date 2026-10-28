# NixOS on Raspberry Pi 4 (Model B)

Declarative, flake-based NixOS for a headless Pi 4, built and deployed from an
Apple Silicon Mac. Based on the current `nixos-hardware` Raspberry Pi 4 profile
and the Nixpkgs generic AArch64 SD-image builder.

**This repo is public and contains no secrets.** `keys/placeholder.pub` is a
tracked sentinel; your real key is supplied at evaluation time (see
[Secrets](#secrets)). Evaluation is **pure** — no `--impure`.

## Structure

| Path | Role |
| --- | --- |
| `flake.nix` | Inputs, `nixosConfigurations.pi4`, `deploy.nodes.pi4`, formatter, devShell, lint checks |
| `hardware-configuration.nix` | Boot chain (U-Boot/extlinux), firmware partition, filesystems |
| `configuration.nix` | Networking, mDNS, SSH, users, Docker, packages |
| `keys/placeholder.pub` | Tracked placeholder; override with `--override-input` |
| `ci/ssh.pub` | Throwaway key for CI builds only |
| `.github/workflows/ci.yml` | Lint+eval on PR/push; SD-image build on manual dispatch and tags |
| `README.md` | This file |

The Pi 4 board profile (`nixos-hardware.nixosModules.raspberry-pi-4`) selects the
pinned Raspberry Pi downstream kernel, Wi-Fi/Bluetooth firmware, device-tree
filter, GRUB-off + extlinux boot, and the `vc4-kms-v3d` GPU driver. The SD-image
module supplies the disk layout and first-boot rootfs expansion
(`sdImage.expandOnBoot` is set explicitly).

## Prerequisites

- macOS (Apple Silicon) with Nix and flakes enabled:
  ```sh
  mkdir -p ~/.config/nix
  echo 'experimental-features = nix-command flakes' >> ~/.config/nix/nix.conf
  ```
- An 8 GB+ microSD card (or NVMe in a USB enclosure) and a card reader.

## Secrets

SSH access is public-key-only and no key is committed. Put your public key in a
gitignored file (e.g. `keys/my.pub`) and pass it as a flake input override:

```sh
cp ~/.ssh/id_ed25519.pub keys/my.pub   # gitignored
KEY=keys/my.pub
```

`path:` inputs refuse to follow symlinks. If Nix reports "is a symlink", use a
symlink-free copy (on macOS avoid `/tmp`; e.g.
`nix shell nixpkgs#coreutils -c realpath "$KEY"`).

The build asserts the placeholder is gone, so a keyless build fails loudly
instead of producing an unreachable image.

## 1. Build the SD image

The Pi is `aarch64-linux`; the Mac is `aarch64-darwin`. A local build is a
cross-compile, so the CI image job is the recommended path for a reproducible
artifact.

### Option A — CI (recommended)

Run the `image` job from the Actions tab (`workflow_dispatch`), or push a `v*`
tag. It builds `.#nixosConfigurations.pi4.config.system.build.sdImage` natively
on `ubuntu-24.04-arm`, writes `sha256sums.txt`, and uploads the `.img.zst`.

Set the `PI_SSH_PUBKEY` repository variable (Settings → Secrets and variables →
Actions → Variables) to make the artifact deployable. Without it, CI falls back
to the throwaway `ci/ssh.pub` and the artifact is build-verification only.

### Option B — build on the Pi (needs a running Pi)

Bootstrap first (see [Bootstrapping](#bootstrapping)), then on the Pi:

```sh
git clone <this-repo> ~/pi4-config && cd ~/pi4-config
nix build --override-input ssh-pubkey path:/path/to/your_key.pub \
  .#nixosConfigurations.pi4.config.system.build.sdImage
```

### Option C — local Linux builder

Configure a remote `aarch64-linux` builder (e.g. `nix.linux-builder` with
nix-darwin, or `--builders`), then run the same `nix build` as Option B on the
Mac.

## 2. Flash the image

```sh
# Local build: decompress into a writable file (result/ is a read-only store symlink).
nix shell nixpkgs#zstd -c zstd -dc result/sd-image/*.img.zst > pi4.img

# CI artifact: download it, then decompress the flat file.
nix shell nixpkgs#zstd -c zstd -dc nixos-image-sd-card-*.img.zst > pi4.img

diskutil list                    # confirm the card, e.g. /dev/disk4
diskutil unmountDisk /dev/disk4  # required before raw writes

# /bin/dd is macOS BSD dd (lowercase m). A Nix/uutils `dd` in PATH wants `4M`.
sudo /bin/dd if=pi4.img of=/dev/rdisk4 bs=16m
sudo diskutil eject /dev/disk4
```

Or decompress the `.img.zst` and write the `.img` with Raspberry Pi Imager.

## 3. First boot

First boot expands the root partition to fill the device (about a minute), then:

```sh
ssh nixos@pi4.local
```

terminfo for wezterm/foot is installed so terminal UIs (herdr, zellij, tmux)
render correctly from a macOS terminal emulator.

## Receiver mode (Samsung M7 → Pi → HK Aura)

The Pi is an A2DP **sink**: the monitor pairs with it over Bluetooth, and the Pi
plays the stream out its **3.5 mm jack** into the Aura's aux input. BlueALSA runs
as a system daemon, so this works headless (no login or PipeWire session).

1. On the M7: **Settings → Sound → Sound Output → Bluetooth Speaker List**, then
   select the Pi (`pi4`). Pairing is auto-accepted.
2. Audio comes out the Pi's 3.5 mm jack; set the level with
   `alsamixer -c Headphones`.
3. To auto-reconnect, trust the monitor once:

   ```sh
   bluetoothctl trust <M7-MAC>
   ```

**AirPlay (bonus):** `shairport-sync` is enabled with the ALSA backend, so the Pi
also appears as an AirPlay 1 receiver named `Pi4 Receiver`. AirPlay 2 would need
the `nqptp` service and an `enableAirplay2` package override.

**If the M7's Bluetooth is still unreliable** (it is the failing link), the
deterministic fallback is HDMI ARC:
`M7 HDMI(ARC) → HDMI-ARC audio extractor → Aura optical/3.5 mm`. No Pi needed
for that path.

**If the Pi's internal radio is flaky,** use a USB Bluetooth dongle and disable
the internal one:

```nix
hardware.raspberry-pi.configtxt.deviceTreeOverlays.all = [ { disable-bt = { }; } ];
```

## 4. Update over the network (no re-flashing)

`nix.settings.trusted-users` includes `nixos`, so the deploy user can build and
copy closures through the remote daemon.

### nixos-rebuild (builds on the Pi, deploys)

```sh
nix run nixpkgs#nixos-rebuild -- switch \
  --no-reexec \
  --flake .#pi4 \
  --override-input ssh-pubkey path:"$KEY" \
  --target-host nixos@pi4.local \
  --build-host  nixos@pi4.local \
  --elevate=sudo
```

`nixos-rebuild` is not installed on macOS; `nix run` invokes it from nixpkgs.
`--no-reexec` keeps the darwin instance (re-exec would try to run the
aarch64-linux binary). On the Pi itself, drop `--target-host`/`--build-host`
and run `nixos-rebuild switch` directly.

### deploy-rs (atomic switch with automatic rollback)

```sh
nix run .#deploy -- .#pi4 -- \
  --override-input ssh-pubkey path:"$KEY"
```

`remoteBuild = true` is set in `flake.nix`, and the activation wrapper targets
`aarch64-linux`, so the Pi builds its own closure.

## Guardrails

Pure evaluation plus static lint. There are no VM tests: the Pi 4 kernel/DTB
cannot boot in QEMU, so hardware behavior is verified on the device.

```sh
nix fmt                                                     # nixfmt (RFC 166)
nix flake check --override-input ssh-pubkey path:ci/ssh.pub    # eval + lint checks
nix develop                                                 # nixfmt, statix, deadnix, actionlint
```

The flake exposes lint as
`checks.<system>.{formatting,statix,deadnix,actionlint}` and, for
`aarch64-linux` only, the deploy-rs schema/activation checks (macOS skips them
rather than failing on the target build).

CI (`.github/workflows/ci.yml`):

| Trigger | Jobs |
| --- | --- |
| `pull_request`, `push` to `main` | lint + eval; keyless-eval-must-fail; keyed-eval-must-pass |
| `workflow_dispatch`, `v*` tags | the above plus a native `aarch64-linux` SD-image build, `sha256sums.txt`, artifact upload |

## Bootstrapping (no cross-build)

Flash the official generic AArch64 NixOS SD image, boot it, then deploy this flake
over SSH with the `nixos-rebuild` command above. This avoids cross-compiling the
kernel from macOS for the first bring-up.

## Notes

- **Firmware/EEPROM**: the SD image stages the firmware partition at build time.
  Runtime sync is opt-in: set `hardware.raspberry-pi.firmware.enable = true`
  and mount `/boot/firmware`. The bootloader *EEPROM* is not managed by NixOS —
  update it with `nix shell nixpkgs#raspberrypi-eeprom` for USB/NVMe boot.
- **Bluetooth**: BlueZ is enabled. Onboard BT uses the vendor DTB's UART
  configuration; the profile's build-time UART overlay is not staged into the
  SD image (U-Boot uses vendor DTBs), so it is not enabled. Verify with
  `bluetoothctl show`; see nixos-hardware issue #1946.
- **A2DP**: for an audio receiver add PipeWire + WirePlumber and the bluez audio
  backend — deliberately out of scope for this base config.
- **Pinning**: `nixos-unstable` and `nixos-hardware` master move. Commit
  `flake.lock` for reproducibility.
