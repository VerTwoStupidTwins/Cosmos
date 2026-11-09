{
  flake.modules.nixos.base = {
    users.users.root.hashedPassword = "!";

    security.sudo.execWheelOnly = true;
  };
}
