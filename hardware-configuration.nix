# Hardware, boot chain, and disk layout for the Raspberry Pi 4 (Model B).
#
# Much of this is already provided by the board profile imported in flake.nix
# (`nixos-hardware.nixosModules.raspberry-pi-4`), which:
#   - pins a Raspberry Pi downstream kernel (6.18.x) — no manual kernelPackages
#     needed (the old `pkgs.linuxPackages_rpi4` override is obsolete)
#   - adds the Pi 4 initrd modules (pcie-brcmstb, reset-raspberrypi)
#   - installs pinned Wi-Fi + Bluetooth firmware
#   - filters device trees to bcm2711-rpi-*.dtb (bcm2711-rpi-4*.dtb with BT on)
#   - disables GRUB and enables generic-extlinux generation
#   - requests full KMS via the vc4-kms-v3d overlay in the generated config.txt
#
# The SD-card image module (also in flake.nix) supplies the disk layout
# (FAT /boot/firmware + ext4 /) and first-boot rootfs expansion.
#
# Hand-authored, not `nixos-generate-config` output: it encodes policy, so
# regenerating it would silently drop settings.
{ lib, ... }:

{
  boot = {
    # Boot chain: Raspberry Pi firmware -> U-Boot -> extlinux.conf -> NixOS.
    # The board profile and the SD-image module already disable GRUB and enable
    # generic-extlinux generation, so there is nothing to set here.

    supportedFilesystems = {
      # The pinned Raspberry Pi kernel does not build the ZFS module; the base
      # image profile enables ZFS, so it must be explicitly turned off.
      zfs = lib.mkForce false;
      exfat = true;
      ntfs3 = true;
    };
  };

  # First boot expands the root partition to fill the card (the SD-image
  # default; stated explicitly so the intent is part of the repo).
  sdImage.expandOnBoot = true;

  # The image builder stages GPU boot code, device trees, overlays, the rendered
  # config.txt, and U-Boot. `uboot.enable` also points config.txt's `kernel=`
  # at u-boot.bin. Runtime firmware-partition sync is opt-in: enable
  # `hardware.raspberry-pi.firmware.enable` and mount /boot/firmware if needed.
  hardware.raspberry-pi.firmware.uboot.enable = true;

  # Onboard Bluetooth: route the BCM2711 UART0 pins the Bluetooth controller uses.
  # Pairs with `hardware.bluetooth.enable` (BlueZ) in configuration.nix.
  # NOTE: with U-Boot enabled the firmware partition uses vendor DTBs
  # (`useGenerationDeviceTree = false`), so this build-time overlay may not reach
  # the booted DTB. The vendor DTB normally suffices for onboard BT; verify with
  # `bluetoothctl show` (nixos-hardware issue #1946).
  hardware.raspberry-pi."4".bluetooth.enable = true;
}
