# Core system configuration: identity, networking, users, SSH, services, packages.
{
  pkgs,
  lib,
  sshPublicKey,
  user,
  ...
}:

{
  system.stateVersion = "26.11";

  # Fail loudly rather than produce an image with a placeholder key.
  assertions = [
    {
      assertion = !(lib.hasInfix "OVERRIDE_ME" sshPublicKey);
      message = ''
        keys/placeholder.pub is still the placeholder. Override it with your
        public key (a symlink-free path):
          --override-input ssh-pubkey path:keys/my.pub
      '';
    }
  ];

  networking = {
    hostName = "pi4"; # reachable as pi4.local via mDNS
    networkmanager.enable = true;
    # Avoids intermittent Wi-Fi reachability (NixOS wiki: "Wi-Fi power saving").
    networkmanager.wifi.powersave = false;
  };

  # mDNS responder so the Pi resolves as `pi4.local`.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
  };

  # OpenSSH: public-key authentication only, no root login.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Trust the deploy user so `deploy-rs remoteBuild` and
  # `nixos-rebuild --build-host ${user}@...` can copy derivations to the daemon.
  # `root` is already the default trusted user; add only the deploy user.
  nix.settings.trusted-users = [ user ];

  # Onboard Bluetooth (BlueZ). The UART pin-routing overlay is enabled in
  # hardware-configuration.nix (`hardware.raspberry-pi."4".bluetooth.enable`).
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
  };

  # Docker for microservices.
  virtualisation.docker.enable = true;

  # Primary non-root user with passwordless sudo.
  users.users.${user} = {
    isNormalUser = true;
    description = "Primary administrative user";
    extraGroups = [
      "wheel"
      "docker"
      "networkmanager"
    ];
    openssh.authorizedKeys.keys = [ sshPublicKey ];
    # No password is set (SSH is key-only). For a console recovery password,
    # add `initialPassword = "...";` locally — never commit it.
  };
  security.sudo.wheelNeedsPassword = false;

  # Utility over lean: terminal emulator terminfo (so herdr/zellij/tmux render
  # correctly when SSHing from macOS wezterm/foot), everyday tools, and
  # removable-filesystem helpers.
  environment.systemPackages = with pkgs; [
    git
    curl
    htop
    tmux
    zellij
    ripgrep
    fd
    gum
    wezterm.terminfo
    foot.terminfo
    exfatprogs
    ntfs3g
    vim
  ];
}
