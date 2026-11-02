#!/bin/bash
# goAmnezia pro — словарь RU, модуль lib/docker.sh
# shellcheck disable=SC2034,SC2148

I18N[docker_installing]="Ставлю Docker из репозитория дистрибутива (docker.io, containerd)…"
I18N[docker_err_podman]="Обнаружен podman вместо Docker — Amnezia на podman не работает. Удалите podman-docker и поставьте docker.io"
I18N[docker_err_install]="Не удалось установить Docker (apt-get install docker.io containerd)"
I18N[docker_err_not_running]="Служба Docker не запущена (systemctl status docker)"
I18N[docker_err_network]="Не удалось создать сеть Docker %s"
I18N[docker_err_image_key]="Недопустимый ключ образа: %s"
I18N[docker_err_images_json]="Нет файла закреплённых образов: %s"
I18N[docker_err_image_unknown]="Образ %s не описан в images.json"
I18N[docker_warn_unpinned]="Дайджест образа не закреплён — тяну %s по тегу (версия может отличаться)"
I18N[docker_warn_pull_retry]="Попытка %s: не удалось скачать %s, повторяю…"
I18N[docker_err_rate_limit]="Docker Hub ограничил анонимные загрузки (toomanyrequests). Подождите или выполните docker login и повторите"
I18N[docker_err_pull]="Не удалось скачать образ %s"
I18N[docker_err_image_name]="Недопустимое имя образа: %s"
I18N[docker_err_dockerfile]="В каталоге %s нет Dockerfile"
I18N[docker_err_build]="Сборка образа %s не удалась"
I18N[docker_err_port]="Недопустимый порт: %s"
I18N[docker_err_run]="Не удалось запустить контейнер %s"
I18N[docker_err_network_connect]="Не удалось подключить контейнер %s к сети amnezia-dns-net"
I18N[docker_err_write]="Не удалось записать файл в контейнер %s: %s"
I18N[docker_err_restart]="Не удалось перезапустить контейнер %s"
I18N[docker_err_rm]="Контейнер %s не снялся (docker rm отказал) — ничего не удаляю."
I18N[docker_err_start]="Не удалось запустить контейнер %s"

# Рассогласование версий CLI и демона (пакет docker.io обновился автообновлением,
# а демон не перезапускался) и всё, что из него следует.
I18N[docker_warn_api_mismatch]="Docker обновился, а служба осталась старой — goAmnezia перезапустит её сама, когда к VPN никто не будет подключён; сейчас — «Обслуживание → Перезапустить Docker»"
I18N[docker_log_api_pinned]="Docker: клиент просит API %s, демон понимает максимум %s — пакет обновлён, служба не перезапущена. Закреплено %s; сторож перезапустит службу, когда к VPN никто не будет подключён"
I18N[docker_err_unreachable]="Демон Docker не отвечает — состояние контейнеров неизвестно. Проверьте: systemctl status docker, при рассогласовании версий — systemctl restart docker"
I18N[docker_state_running]="работает"
I18N[docker_state_restarting]="перезапускается"
I18N[docker_state_exited]="остановлен"
I18N[docker_state_missing]="контейнера нет"
I18N[docker_state_unreachable]="состояние неизвестно: демон Docker недоступен"
I18N[docker_state_unpublished]="работает, но порт не опубликован — связи нет (Поднять контейнер заново)"
I18N[docker_diag_title]="Docker"
I18N[docker_diag_versions]="клиент %s (API %s) · демон %s (API %s)"
I18N[docker_diag_mismatch]="Рассогласование версий: пакет Docker обновлён, а служба не перезапускалась. goAmnezia перезапустит её сама, когда к VPN никто не будет подключён; сейчас — «Обслуживание → Перезапустить Docker»"
I18N[docker_diag_pinned]="Версия API закреплена на время работы: %s"
I18N[docker_diag_unreachable]="Демон Docker не отвечает"

# Старый демон (DK-02): пакет обновлён, служба не перезапущена — перезапуск службы.
I18N[docker_diag_stale]="Docker обновлён до %s, а служба работает старая (%s) — обновление не действует, пока её не перезапустить. goAmnezia сделает это сама, когда к VPN никто не будет подключён; сейчас — «Обслуживание → Перезапустить Docker»"
I18N[docker_diag_stale_since]="Пакет обновлён: %s"
I18N[docker_err_restart_daemon]="Не удалось перезапустить службу Docker: %s. Вручную: systemctl restart docker"
I18N[docker_err_restart_timeout]="Служба Docker перезапущена, но демон не ответил за %s с. Проверьте: systemctl status docker; вручную — systemctl restart docker"
