# Bluetooth audio receiver: Samsung M7 --BT--> Pi (A2DP sink) --3.5mm--> HK Aura.
#
# Headless by design: BlueALSA is a system daemon (no login session, linger, or
# PipeWire user units required), and `bluealsa-aplay` bridges A2DP to ALSA.
#
# If the M7's Bluetooth remains unreliable, the deterministic fallback is:
#   M7 HDMI(ARC) -> HDMI-ARC audio extractor -> HK Aura optical/3.5mm.
# If the Pi's internal BCM43455 proves flaky, use a USB dongle and disable the
# internal radio:
#   hardware.raspberry-pi.configtxt.deviceTreeOverlays.all = [ { disable-bt = { }; } ];
{ pkgs, ... }:

{
  # Present as an audio-class device and stay discoverable.
  hardware.bluetooth = {
    enable = true;
    powerOnBoot = true;
    settings = {
      General = {
        Class = "0x200414"; # Audio/Video
        DiscoverableTimeout = 0; # never stop advertising
        JustWorksRepairing = "always";
        FastConnectable = true; # faster reconnects
      };
      Policy.AutoEnable = true;
    };
  };

  # System-level BlueALSA daemon + ALSA plugin (no user session needed).
  # Pin ALSA's default to the 3.5 mm jack. `dmix` lets Bluetooth and AirPlay
  # share the device instead of one failing with EBUSY. (Pi 4 card name is
  # `Headphones`; verify with `aplay -l`.)
  hardware.alsa = {
    enable = true;
    enableBluetooth = true;
    defaultDevice.playback = "dmix:CARD=Headphones,DEV=0";
  };

  # BlueALSA provides the daemon; this is the A2DP -> ALSA playback bridge.
  # It plays to ALSA's default PCM, pinned to the 3.5 mm jack above.
  # `Headphone` is the bcm2835 mixer control; check with
  # `amixer -c Headphones scontrols` if AVRCP volume misbehaves.
  systemd.services.bluealsa-aplay = {
    description = "BlueALSA A2DP playback to the 3.5 mm output";
    wantedBy = [ "multi-user.target" ];
    after = [
      "bluetooth.service"
      "bluealsa.service"
    ];
    requires = [ "bluealsa.service" ];
    serviceConfig = {
      # `bluez-alsa` ships its own `bluealsa-aplay.service`, so this definition
      # is merged as a drop-in; `""` resets the packaged ExecStart before ours.
      ExecStart = [
        ""
        "${pkgs.bluez-alsa}/bin/bluealsa-aplay --single-audio --mixer-device=hw:CARD=Headphones --mixer-name=Headphone"
      ];
      Restart = "always";
      RestartSec = 5;
    };
  };

  # Auto-accept pairing (NoInputNoOutput) and advertise.
  systemd.services.bt-agent = {
    description = "Bluetooth auto-accept pairing agent";
    wantedBy = [ "multi-user.target" ];
    after = [ "bluetooth.service" ];
    requires = [ "bluetooth.service" ];
    serviceConfig = {
      ExecStartPre = "${pkgs.bluez}/bin/bluetoothctl discoverable on";
      ExecStart = "${pkgs.bluez-tools}/bin/bt-agent --capability=NoInputNoOutput";
      Restart = "always";
      RestartSec = 5;
    };
  };

  # AirPlay 1 bonus (shairport-sync is built with ALSA support by default).
  # It shares the same `dmix` default as Bluetooth. AirPlay 2 additionally
  # needs `nqptp` and an `enableAirplay2` package override; see README.
  services.shairport-sync = {
    enable = true;
    openFirewall = true;
    settings.general = {
      name = "Pi4 Receiver";
      output_backend = "alsa";
    };
  };

  # Mixer + Bluetooth diagnostics.
  environment.systemPackages = with pkgs; [
    alsa-utils
    bluez
    bluez-tools
  ];
}
