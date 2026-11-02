# goAmnezia pro — vhost сайта-маскировки (шаблон lib/nginx/goamnezia.conf.tpl).
#
# Готовый файл /etc/nginx/sites-available/goamnezia собирает website_write_conf
# (lib/website.sh) из этого шаблона и config.json: server_name, сертификат,
# режим listen (site.listen), путь панели (panel.miniapp_path), доступы агентов
# (site.mcp_location), Alt-Svc (options.alt_svc). Правки руками в готовом файле
# перезапишутся при следующей смене настроек — меняйте шаблон здесь или
# значения в config.json.
#
# Один шаблон на два режима с сайтом (PLAN §4.3):
#   • pro       — домен: server_name = домен, сертификат Let's Encrypt;
#   • запасной путь — домена ещё нет: server_name _ (сервер отвечает по IP),
#     самоподписанный сертификат; бывает и в lite_site, и в pro
#                 сертификат /opt/goamnezia/tls/site.{crt,key} на 10 лет.
# Куски, нужные только одному режиму, обёрнуты строками-маркерами в начале
# строки (ONLY_PRO и ONLY_SELFSIGNED, BEGIN … END): сборщик оставляет блоки своего
# режима и вырезает чужие вместе с маркерами, поэтому в готовом файле их нет.
# Метки-подстановки (слова в ВЕРХНЕМ_РЕГИСТРЕ на месте значений), маркеры и
# якоря-комментарии ниже — контракт с website_write_conf, их имена не менять.
#
# Картина для наблюдателя снаружи (PLAN §4.4): в Pro — домен с сертификатом
# Let's Encrypt, обычный сайт по TCP/443 и «QUIC» на UDP/443 (на деле AmneziaWG);
# в Lite + сайт — обычный веб-сервер на IP, отвечающий и по 80, и по 443.

# ── Зоны ограничения запросов страниц подключения (уровень http) ─────────────
# limit_req_zone/limit_conn_zone живут только на уровне http, а этот файл nginx
# включает внутри http {} — поэтому они здесь, вне server. Вставляет их
# website_pages_location_on вместе с локацией /p-… (_ga_site_pages_zones).
# GOAMNEZIA_PAGES_ZONES
# Зоны подписок — так же, вместе с локацией /s-… (website_subs_location_on, _ga_site_subs_zones).
# GOAMNEZIA_SUBS_ZONES

# ── 80/tcp ───────────────────────────────────────────────────────────────────
server {
    listen 80;
LISTEN80_V6_PLACEHOLDER
    server_name SERVER_NAME_PLACEHOLDER;
    # «Server: nginx» без версии и ОС — как обещает docs/CLIENTS.md §7 (находка LS-15)
    server_tokens off;

    # Секретные пути (страницы /p-, подписки /s-, доступы агентов /a- и /r-, раздача /d-, путь панели app-…) — сами
    # ключ: набранный как http://… такой путь не пишется в журнал, а ответ тот же, что у любого пути здесь (в Pro —
    # редирект на HTTPS, в Lite + сайт — 404). Стоит всегда (lib/website.sh, _ga_site_secret_paths_block).
    # GOAMNEZIA_SECRET_PATHS_80
    # Короткие ссылки подписки (/<КОД>, docs/SUBSCRIPTION.md §11): в Pro с подписками — тот же редирект на HTTPS, но
    # без строки в журнале (lib/website.sh, _ga_site_short_http_block).
    # GOAMNEZIA_SHORT_HTTP

# GOAMNEZIA_ONLY_PRO_BEGIN
    # Pro: проверка Let's Encrypt (HTTP-01) и редирект на HTTPS.
    # Каталог для HTTP-01 отдельный от корня сайта: смена шаблона переписывает
    # корень целиком (в том числе во время продления сертификата), а «deny /\.»
    # в блоке HTTPS закрыл бы /.well-known. Модификатор ^~ — чтобы никакая
    # regex-локация не перехватила путь проверки.
    location ^~ /.well-known/acme-challenge/ {
        root ACME_ROOT_PLACEHOLDER;
        default_type text/plain;
        allow all;
    }

    # $server_name, а не $host: с чужим заголовком Host редирект вёл бы на
    # произвольный адрес (open redirect на ровном месте).
    location / {
        return 301 https://$server_name$request_uri;
    }
# GOAMNEZIA_ONLY_PRO_END
# GOAMNEZIA_ONLY_SELFSIGNED_BEGIN
    # Lite + сайт: тот же сайт по обычному HTTP, без редиректа на HTTPS.
    # Редирект вёл бы на https://<IP>/ с самоподписанным сертификатом — сразу
    # предупреждение браузера и «странный» хост для сканера, а обычный сервер на
    # голом IP отдаёт страницу по 80 как есть. ACME-локации нет: домена нет,
    # проверять Let's Encrypt нечего.
    root SITE_ROOT_PLACEHOLDER;
    index index.html;
    # Симлинк в корне сайта (шаблон — чужой git-репозиторий) не отдаётся: иначе ссылка на users.json или
    # ключ сертификата уходила бы любому посетителю. Второй рубеж после удаления ссылок при развёртывании.
    disable_symlinks on from=$document_root;

    location / {
        try_files $uri $uri/ =404;
        expires -1;
    }
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|webp|woff|woff2|ttf|eot)$ {
        expires 7d;
    }
    location ~ /\. { deny all; }
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location = /favicon.ico { log_not_found off; access_log off; }
# GOAMNEZIA_ONLY_SELFSIGNED_END
}

# ── HTTPS: сайт-маскировка, панель по секретному пути, доступы агентов ───────
server {
LISTEN_PLACEHOLDER
    server_name SERVER_NAME_PLACEHOLDER;
    server_tokens off;

    # Pro: fullchain/privkey Let's Encrypt; Lite + сайт: самоподписанные
    # /opt/goamnezia/tls/site.{crt,key} (website_selfsigned_ensure).
    ssl_certificate     SSL_CERT_PLACEHOLDER;
    ssl_certificate_key SSL_KEY_PLACEHOLDER;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:goamnezia_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    # OCSP stapling не включаем: Let's Encrypt с 2025 года не ставит в сертификаты
    # адрес OCSP-респондера, и «ssl_stapling on» даёт лишь предупреждение nginx -t.

    # Заголовки безопасности — как у любого аккуратного сайта на nginx.
# GOAMNEZIA_ONLY_PRO_BEGIN
    # HSTS только на доверенном сертификате: на самоподписанном браузер заголовок
    # игнорирует, а для наблюдателя «строгий HTTPS» без доверия — противоречие,
    # по которому сервер выделяется среди обычных.
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
# GOAMNEZIA_ONLY_PRO_END
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    # Объявление HTTP/3 (options.alt_svc): браузер попробует QUIC на UDP/443,
    # упрётся в AmneziaWG и откатится на TCP — картина правдоподобнее, но с
    # задержкой в секунду-две. По умолчанию выключено; строку вставляет
    # website_set_alt_svc on.
ALT_SVC_PLACEHOLDER

    client_max_body_size 2m;

    # ── Панель по секретному пути (panel.miniapp_path) ────────────────────────
    # Панель слушает только 127.0.0.1:1985; наружу её выводит этот location, и
    # только когда путь задан (website_panel_path_set) и режим — Pro: панель на
    # домене (её allowlist Host и код входа из бота рассчитаны на домен), в
    # Lite + сайт якорь остаётся пустым. Модификатор ^~ в блоке обязателен: ниже
    # стоит regex-локация кеширования статики (\.(js|css|…)$), а regex в nginx
    # приоритетнее префиксных — без ^~ она перехватывала бы /<путь>/app.js и
    # искала файл в корне сайта, панель грузилась бы пустой.
    # Секретный путь не должен попадать в логи: в блоке access_log off.
    # GOAMNEZIA_PANEL_LOCATION

    # ── Доступы агентов к MCP по HTTP (PLAN §6.10, CONTRACT §5.1) ─────────────
    # Одна regex-локация на все доступы: секрет — 43 символа base64url, форма
    # пути столь специфична, что с сайтом не пересекается, а новый доступ не
    # требует перезагрузки nginx. Чужой перебор путей получает 404 сайта.
    # Живёт и в Pro, и в Lite + сайт (там — на самоподписанном сертификате,
    # клиент доверяет ему по отпечатку). Секрет не пишется в логи (access_log
    # off). Блок вставляет website_mcp_location_on и убирает website_mcp_location_off.
    # GOAMNEZIA_MCP_LOCATION

    # ── Страницы подключения (docs/CLIENTS.md §6, lib/pages.sh) ──────────────
    # Одна regex-локация на все страницы: путь /p-<43 символа base64url>/ — и
    # есть ключ, новая страница nginx не трогает. Служба goamnezia-pages
    # слушает 127.0.0.1:1987 (pages.port); упавшая служба не должна выдавать
    # себя — 502/503/504 перехватываются и отдаются как 404 сайта. Внутренняя
    # локация /_ga_mirror/ — файлы зеркала сборок через X-Accel-Redirect
    # (сам файл отдаёт nginx, а решает, кому и что, — служба страниц). Блок
    # вставляет website_pages_location_on и убирает website_pages_location_off.
    # GOAMNEZIA_PAGES_LOCATION

    # ── Подписки (docs/SUBSCRIPTION.md, lib/subs.sh) ─────────────────────────
    # /s-<43 символа base64url>/<суффикс из белого списка> → та же служба goamnezia-pages, только на домене с
    # Let's Encrypt: маршрут вставляет website_subs_location_on и убирает website_subs_location_off. Вместе с ним —
    # короткие ссылки /<КОД> (8–12 знаков): сначала файлы сайта (try_files), потом служба (docs/SUBSCRIPTION.md §11).
    # GOAMNEZIA_SUBS_LOCATION

    # ── Глушилка секретных путей ─────────────────────────────────────────────
    # /p-, /s-, /a-, /r-, /d- + 43 знака base64url и путь панели app-… без живого маршрута выше (страниц,
    # подписок, агентов нет или они выключены, панель выключена, адрес отозван, перевыпущен или чужой) — 404
    # сайта без строки в журнале. Стоит всегда, ПОСЛЕ живых регулярных локаций (nginx проверяет их по порядку)
    # и до регулярок сайта ниже; живой путь панели — префикс ^~, сюда не доходит.
    # GOAMNEZIA_SECRET_PATHS_443

    # ── Сайт-маскировка ──────────────────────────────────────────────────────
    root SITE_ROOT_PLACEHOLDER;
    index index.html;
    # Симлинк в корне сайта (шаблон — чужой git-репозиторий) не отдаётся: иначе ссылка на users.json или
    # ключ сертификата уходила бы любому посетителю. Второй рубеж после удаления ссылок при развёртывании.
    disable_symlinks on from=$document_root;

    # html не кешируем: шаблон подменяется на месте под тем же именем, и при
    # долгом кеше владелец после смены шаблона видел бы прежний сайт.
    location / {
        try_files $uri $uri/ =404;
        expires -1;
    }

    # Кеширование статики через expires, а не add_header: свой add_header на
    # этом уровне отменил бы наследование заголовков безопасности с уровня
    # server. Неделя, а не «год с immutable»: файлы шаблонов не версионируются,
    # и вернувшийся посетитель после смены шаблона видел бы старую вёрстку.
    location ~* \.(jpg|jpeg|png|gif|ico|css|js|svg|webp|woff|woff2|ttf|eot)$ {
        expires 7d;
    }

    # Скрытые файлы: маркеры шаблона .goamnezia_template_*, .git и прочее.
    location ~ /\. { deny all; }
    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location = /favicon.ico { log_not_found off; access_log off; }
}
