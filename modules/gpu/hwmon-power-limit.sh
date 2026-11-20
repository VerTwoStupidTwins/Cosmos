# Caps GPUs through the kernel's hwmon interface, as amdgpu and xe provide it.
# Arguments come in pairs: a PCI address and a limit in watts, e.g. 0000:1f:00.0 231.
status=0

while [ "$#" -ge 2 ]; do
  address=$1 watts=$2
  shift 2
  device=/sys/bus/pci/devices/$address

  # The driver may still be starting when this runs.
  cap=
  for _ in {1..30}; do
    for candidate in "$device"/hwmon/hwmon*/power1_cap; do
      [ -f "$candidate" ] && cap=$candidate
    done
    [ -n "$cap" ] && break
    sleep 1
  done

  microwatts=$((watts * 1000000))
  if [ -n "$cap" ] && echo "$microwatts" > "$cap" && [ "$(cat "$cap")" = "$microwatts" ]; then
    echo "$address: limited to $watts W"
  else
    echo "$address: could not set a $watts W limit" >&2
    status=1
  fi
done

exit "$status"
