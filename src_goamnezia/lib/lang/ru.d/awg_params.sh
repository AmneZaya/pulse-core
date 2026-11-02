#!/bin/bash
# goAmnezia pro — строки модуля lib/awg_params.sh (RU). Ключи — паритет с en.d/awg_params.sh.
# shellcheck disable=SC2034
declare -gA I18N
I18N[awg_params_python_missing]="python3 не найден — он нужен для параметров и ключей AmneziaWG"
I18N[awg_params_script_missing]="не найден помощник %s (ожидался в lib/)"
I18N[awg_params_bad_line]="неизвестная линейка AmneziaWG: «%s» (допустимо: 1.0, 1.5, 2.0, 3.1)"
I18N[awg_params_bad_preset]="неизвестный пресет маскировки: «%s» (допустимо: default, quic, router)"
I18N[awg_params_generate_failed]="не удалось сгенерировать параметры линейки %s"
I18N[awg_params_invalid]="параметры линейки %s не прошли проверку:"
I18N[awg_params_bad_json]="параметры должны быть непустым JSON-объектом"
I18N[awg_keys_failed]="не удалось выполнить %s"
I18N[awg_keys_bad_privkey]="приватный ключ должен быть base64 из 32 байт (44 символа)"
