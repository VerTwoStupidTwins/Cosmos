{
  flake.modules.nixos.base = {
    services.tzupdate.enable = true;
    i18n.defaultLocale = "en_US.UTF-8";
  };
}
