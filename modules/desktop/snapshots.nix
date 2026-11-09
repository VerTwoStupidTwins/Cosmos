{
  flake.modules.nixos.snapshots = {
    services.snapper = {
      persistentTimer = true;
      configs.home = {
        SUBVOLUME = "/home";
        ALLOW_USERS = [ "twins" ];
        SYNC_ACL = true;
        TIMELINE_CREATE = true;
        TIMELINE_CLEANUP = true;
        TIMELINE_LIMIT_HOURLY = 12;
        TIMELINE_LIMIT_DAILY = 7;
        TIMELINE_LIMIT_WEEKLY = 4;
        TIMELINE_LIMIT_MONTHLY = 3;
        TIMELINE_LIMIT_YEARLY = 0;
      };
    };
  };
}
