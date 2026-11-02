#!/bin/bash
# goAmnezia pro — словарь RU, модуль lib/export.sh
# shellcheck disable=SC2034,SC2148

I18N[export_err_peer]="У пользователя %s нет ключа на профиле %s"
I18N[export_err_no_privkey]="Ключ %s на профиле %s выдан в приложении Amnezia и хранится только там — отсюда его не показать и не отправить. У пользователя он работает. Привяжите старый ключ (ссылка vpn:// или .conf, которые вы ему отправляли) или перевыпустите — тогда старый перестанет подключаться."
I18N[export_err_profile]="Профиль %s настроен не полностью (нет ключа сервера, порта или адреса)"
I18N[export_err_conf]="Не удалось собрать .conf для %s (%s)"
I18N[export_err_vpn]="Не удалось собрать ключ vpn:// для %s (%s)"
I18N[export_err_qrencode]="Нет qrencode — установите пакет qrencode, чтобы получать QR"
I18N[export_err_qr]="Не удалось создать QR-код: %s"
I18N[export_err_outdir]="Недопустимый каталог для QR: %s"
I18N[export_err_chunks]="Не удалось разбить ключ vpn:// на чанки для QR"
I18N[export_err_format]="Неизвестный формат ключа: %s (conf, vpn, qr-conf, qr-vpn, all)"
I18N[export_vpn_description]="%s · AmneziaWG %s"
I18N[export_warn_dns]="DNS %s из config.json не похож на IPv4 — в ключ он не попадёт"
I18N[export_err_endpoint]="Адрес сервера не определён — ключ с таким адресом не соединится. Задайте endpoint_host или server_ip в config.json"
# Ключ выключенному выдаём, но вслух (см. GA_EXPORT_DISABLED в lib/export.sh).
I18N[export_warn_disabled]="%s сейчас выключен — ключ профиля %s выдан, но подключиться по нему нельзя, пока пользователь не включён (карточка пользователя → Включить)"
I18N[export_err_address_gone]="Адреса %s, заданного пользователю %s, на сервере больше нет — ключ не соединился бы. Задайте пользователю другой адрес или верните общий."
I18N[export_vpn_description_at]="%s · AmneziaWG %s · %s"
I18N[export_err_key_host_invalid]="Адрес «%s» не годится для ключа: нужен IPv4 этого сервера или его домен."
I18N[export_err_key_host_not_here]="Адреса %s у этого сервера нет — ключ с ним не соединился бы. Можно: %s."
I18N[export_err_key_host_unknown]="Сервер не видит своих внешних адресов (похоже, он за NAT), и адрес %s проверить не по чему. Можно: %s."
