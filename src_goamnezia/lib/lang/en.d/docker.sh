#!/bin/bash
# goAmnezia pro — EN dictionary, module lib/docker.sh
# shellcheck disable=SC2034,SC2148

I18N[docker_installing]="Installing Docker from the distribution repository (docker.io, containerd)…"
I18N[docker_err_podman]="podman detected instead of Docker — Amnezia does not work on podman. Remove podman-docker and install docker.io"
I18N[docker_err_install]="Failed to install Docker (apt-get install docker.io containerd)"
I18N[docker_err_not_running]="The Docker service is not running (systemctl status docker)"
I18N[docker_err_network]="Failed to create the Docker network %s"
I18N[docker_err_image_key]="Invalid image key: %s"
I18N[docker_err_images_json]="Pinned images file is missing: %s"
I18N[docker_err_image_unknown]="Image %s is not described in images.json"
I18N[docker_warn_unpinned]="Image digest is not pinned — pulling %s by tag (version may differ)"
I18N[docker_warn_pull_retry]="Attempt %s: failed to pull %s, retrying…"
I18N[docker_err_rate_limit]="Docker Hub throttled anonymous pulls (toomanyrequests). Wait a while or run docker login and retry"
I18N[docker_err_pull]="Failed to pull image %s"
I18N[docker_err_image_name]="Invalid image name: %s"
I18N[docker_err_dockerfile]="No Dockerfile in %s"
I18N[docker_err_build]="Building image %s failed"
I18N[docker_err_port]="Invalid port: %s"
I18N[docker_err_run]="Failed to start container %s"
I18N[docker_err_network_connect]="Failed to connect container %s to the amnezia-dns-net network"
I18N[docker_err_write]="Failed to write a file into container %s: %s"
I18N[docker_err_restart]="Failed to restart container %s"
I18N[docker_err_rm]="Container %s was not removed (docker rm failed) — deleting nothing."
I18N[docker_err_start]="Failed to start container %s"

# CLI ↔ daemon API mismatch (the docker.io package was upgraded by unattended
# upgrades while the daemon was never restarted) and everything that follows.
I18N[docker_warn_api_mismatch]="Docker was updated, but the service is still the old one — goAmnezia will restart it by itself when nobody is connected to the VPN; to do it now — «Maintenance → Restart Docker»"
I18N[docker_log_api_pinned]="Docker: the client asks for API %s, the daemon supports at most %s — the package was upgraded, the service was not restarted. Pinned %s; the watchdog will restart the service when nobody is connected to the VPN"
I18N[docker_err_unreachable]="The Docker daemon does not answer — container state is unknown. Check systemctl status docker; on a version mismatch run systemctl restart docker"
I18N[docker_state_running]="running"
I18N[docker_state_restarting]="restarting"
I18N[docker_state_exited]="stopped"
I18N[docker_state_missing]="no container"
I18N[docker_state_unreachable]="state unknown: the Docker daemon is unreachable"
I18N[docker_state_unpublished]="running, but the port is not published — no connection (Recreate the container)"
I18N[docker_diag_title]="Docker"
I18N[docker_diag_versions]="client %s (API %s) · daemon %s (API %s)"
I18N[docker_diag_mismatch]="Version mismatch: the Docker package was upgraded, but the service was not restarted. goAmnezia will restart it by itself when nobody is connected to the VPN; to do it now — «Maintenance → Restart Docker»"
I18N[docker_diag_pinned]="API version pinned for this run: %s"
I18N[docker_diag_unreachable]="The Docker daemon does not answer"

# Old daemon (DK-02): the package was upgraded, the service was not restarted — restart the service.
I18N[docker_diag_stale]="Docker was updated to %s, but the old service is still running (%s) — the update does not take effect until it is restarted. goAmnezia will do it by itself when nobody is connected to the VPN; to do it now — «Maintenance → Restart Docker»"
I18N[docker_diag_stale_since]="Package updated: %s"
I18N[docker_err_restart_daemon]="Could not restart the Docker service: %s. By hand: systemctl restart docker"
I18N[docker_err_restart_timeout]="The Docker service was restarted, but the daemon did not answer within %s s. Check systemctl status docker; by hand — systemctl restart docker"
