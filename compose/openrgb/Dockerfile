# OpenRGB 1.0 (headless CLI) for the EVGA GTX 1080 Ti FTW3 LEDs, from the official Debian packages.
FROM debian:bookworm-slim

ARG BASE=https://codeberg.org/OpenRGB
RUN set -eu; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl; \
    cd /tmp; \
    curl -fsSLO "$BASE/OpenRGB/releases/download/release_1.0/openrgb_1.0_amd64_bookworm_81bbe18.deb"; \
    curl -fsSLO "$BASE/hidapi-hotplug/releases/download/hidapi-hotplug-0.15.0/libhidapi-hotplug-hidraw0_0.15.0-1_bookworm_amd64.deb"; \
    curl -fsSLO "$BASE/hidapi-hotplug/releases/download/hidapi-hotplug-0.15.0/libhidapi-hotplug-libusb0_0.15.0-1_bookworm_amd64.deb"; \
    printf '%s\n' \
      'be51c1d20fedb06f3c25baf61349c29c65ef92ab86f331b32a82d8c1eac217c3  openrgb_1.0_amd64_bookworm_81bbe18.deb' \
      'd0de851e65fac5943fb64a65f6098d3087fec164fbdfcdf9705a3aeee7205ebd  libhidapi-hotplug-hidraw0_0.15.0-1_bookworm_amd64.deb' \
      'bbb50b314332b9f47fb91f630725e0005fb4338daef9426240d9c273f7f96dac  libhidapi-hotplug-libusb0_0.15.0-1_bookworm_amd64.deb' \
      | sha256sum -c -; \
    apt-get install -y --no-install-recommends ./*.deb; \
    apt-get purge -y curl; apt-get autoremove -y; \
    rm -rf /tmp/*.deb /var/lib/apt/lists/*

# OpenRGB is a Qt app even on the command line.
ENV QT_QPA_PLATFORM=offscreen
ENTRYPOINT ["openrgb", "--config", "/config"]
