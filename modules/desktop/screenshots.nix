
{ ... }:

{
  flake.homeModules.screenshots =
    { pkgs, ... }:

    let
      screenshotAnnotate = pkgs.writeShellApplication {
        name = "screenshot-annotate";

        runtimeInputs = with pkgs; [
          niri
          gradia
          jq
          coreutils
        ];

        text = ''
          mode="''${1:-region}"

          case "$mode" in
            region|window|screen) ;;
            *)
              echo "Usage: screenshot-annotate [region|window|screen]" >&2
              exit 2
              ;;
          esac

          # Keep original screenshots in the standard directory.
          screenshots="$HOME/Pictures/Screenshots"
          mkdir -p "$screenshots"

          shot="$(mktemp "$screenshots/Screenshot-$(date +%Y-%m-%d_%H-%M-%S)-XXXXXXXX.png")"
          captured=false

	  # ShellCheck cannot detect functions invoked through traps.
	  # shellcheck disable=SC2329
          cleanup() {
            # Stop listening for Niri events.
            if [[ -n "''${NIRI_EVENTS_PID:-}" ]]; then
              kill "$NIRI_EVENTS_PID" 2>/dev/null || true
              wait "$NIRI_EVENTS_PID" 2>/dev/null || true
            fi

            # Remove empty screenshots if capture was canceled.
            if [[ "$captured" == false ]]; then
              rm -f -- "$shot"
            fi
          }

          trap cleanup EXIT

          # Subscribe before initiating a screenshot.
          coproc NIRI_EVENTS {
            exec niri msg --json event-stream
          }

          # Wait until the IPC subscription is active.
          if ! IFS= read -r -t 5 _initial_event <&"''${NIRI_EVENTS[0]}"; then
            echo "Failed to connect to Niri event stream" >&2
            exit 1
          fi

          # Start the requested native capture mode.
          case "$mode" in
            region)
              niri msg action screenshot --path "$shot"
              ;;
            window)
              niri msg action screenshot-window --path "$shot"
              ;;
            screen)
              niri msg action screenshot-screen --path "$shot"
              ;;
          esac

          # Wait for the screenshot completion event.
          deadline=$((SECONDS + 120))

          while (( SECONDS < deadline )); do
            if IFS= read -r -t 1 event <&"''${NIRI_EVENTS[0]}"; then
              saved="$(jq -r '.ScreenshotCaptured.path // empty' <<< "$event")"

              if [[ "$saved" == "$shot" && -s "$shot" ]]; then
                captured=true

                # Open the captured image for annotation.
                gradia "$shot"
                exit 0
              fi
            fi
          done

          echo "Screenshot canceled or timed out" >&2
          exit 1
        '';
      };
    in
    {
      home.packages = [
        pkgs.gradia
        screenshotAnnotate
      ];
    };
}

