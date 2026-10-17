# Intel IPU6 Camera Diagnostics

A diagnostic utility for an Intel IPU6/MIPI webcam on Linux. It checks the
Intel camera HAL, GStreamer, the `v4l2-relayd` service, the `v4l2loopback`
virtual camera, and Cheese access. The intended stack is Ubuntu/Debian with
Intel's `icamerasrc` camera source.

## Script

[`check-ipu6-webcam.sh`](check-ipu6-webcam.sh) reports missing components and
other issues as it checks them. Run it from a desktop terminal on the laptop
whose camera you are diagnosing:

```bash
./check-ipu6-webcam.sh
```

The default run performs static checks and does not change system state. Use
these options when needed:

```bash
./check-ipu6-webcam.sh --help
./check-ipu6-webcam.sh --live-test
./check-ipu6-webcam.sh --run-fixes
./check-ipu6-webcam.sh --run-fixes --live-test
```

- `--help` describes all options.
- `--live-test` briefly opens the relay camera and asks GStreamer to receive
  30 frames (up to 15 seconds). Close Cheese and other camera apps first so
  they do not hold the camera open.
- `--run-fixes` loads `v4l2loopback` if its kernel module is already available,
  then resets and restarts `v4l2-relayd@default`. It may ask for sudo access.
  These are runtime actions; the option does not install packages or edit
  configuration files. Combine it with `--live-test` to restart the relay and
  then check for frames.

The checks cover OS/kernel and IPU hardware identification, required Debian
packages, Cheese installation and Snap camera-interface access, kernel modules,
GStreamer elements, V4L2 devices and permissions, relay service status and
recent journal errors, and PipeWire/WirePlumber when a desktop session is
visible. The live test checks frame delivery from the virtual relay device;
passing it does not by itself verify Cheese's preview negotiation.

If the script reports that `/dev/video*` is not visible, run it directly in
the laptop's desktop session rather than in a container or restricted remote
execution environment.
