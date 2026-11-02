#!/bin/bash
# goAmnezia pro — strings of lib/awg_params.sh (EN). Keys mirror ru.d/awg_params.sh.
# shellcheck disable=SC2034
declare -gA I18N
I18N[awg_params_python_missing]="python3 not found — it is required for AmneziaWG parameters and keys"
I18N[awg_params_script_missing]="helper %s not found (expected in lib/)"
I18N[awg_params_bad_line]="unknown AmneziaWG line: \"%s\" (allowed: 1.0, 1.5, 2.0, 3.1)"
I18N[awg_params_bad_preset]="unknown obfuscation preset: \"%s\" (allowed: default, quic, router)"
I18N[awg_params_generate_failed]="failed to generate parameters for line %s"
I18N[awg_params_invalid]="parameters for line %s failed validation:"
I18N[awg_params_bad_json]="parameters must be a non-empty JSON object"
I18N[awg_keys_failed]="failed to run %s"
I18N[awg_keys_bad_privkey]="private key must be base64 of 32 bytes (44 characters)"
