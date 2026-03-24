#!/usr/bin/env bash
# emby-proxy-toolbox.sh
# 一体化 Emby 反代工具箱（单站反代管理器 + 通用反代网关）
set -euo pipefail

# -------------------- 通用配置 --------------------
SITES_AVAIL="/etc/nginx/sites-available"
SITES_ENAB="/etc/nginx/sites-enabled"
BACKUP_ROOT="/root"

# 单站管理器
SINGLE_PREFIX="emby-"
SINGLE_HTPASSWD="/etc/nginx/.htpasswd-emby"

# 通用网关
GW_PREFIX="emby-gw-"
GW_MAP_CONF="/etc/nginx/conf.d/emby-gw-map.conf"
GW_SNIP_CONF="/etc/nginx/snippets/emby-gw-locations.conf"
GW_HTPASSWD="/etc/nginx/.htpasswd-emby-gw"
GW_REWRITE_RULES="/etc/nginx/emby-gw-rewrite.rules"
GW_REWRITE_SNIP="/etc/nginx/snippets/emby-gw-rewrite.conf"

TOOL_NAME="emby-proxy-toolbox"
# ------------------------------------------------

need_root() { [[ "${EUID}" -eq 0 ]] || { echo "请用 root 运行：sudo bash $0"; exit 1; }; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

prompt() {
  local __var="$1" __msg="$2" __def="${3:-}"
  local __ans=""
  if [[ -n "$__def" ]]; then
    read -r -p "$__msg [$__def]: " __ans
    __ans="${__ans:-$__def}"
  else
    read -r -p "$__msg: " __ans
  fi
  printf -v "$__var" "%s" "$__ans"
}

yesno() {
  local __var="$1" __msg="$2" __def="${3:-y}"
  local __ans=""
  read -r -p "$__msg (y/n) [$__def]: " __ans
  __ans="${__ans:-$__def}"
  __ans="$(echo "$__ans" | tr '[:upper:]' '[:lower:]')"
  [[ "$__ans" == "y" || "$__ans" == "yes" ]] && printf -v "$__var" "y" || printf -v "$__var" "n"
}

strip_scheme() { local s="$1"; s="${s#http://}"; s="${s#https://}"; echo "$s"; }
sanitize_name() { echo "$1" | tr -cd '[:alnum:]._-' | sed 's/^\.*//;s/\.*$//'; }

is_port() { local p="$1"; [[ "$p" =~ ^[0-9]+$ ]] || return 1; (( p>=1 && p<=65535 )) || return 1; }
normalize_ports_csv() { local csv="$1"; csv="$(echo "$csv" | tr -d ' ')"; csv="${csv#,}"; csv="${csv%,}"; echo "$csv"; }

os_info() {
  local name="unknown" ver="unknown" codename="unknown"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    name="${NAME:-unknown}"
    ver="${VERSION_ID:-unknown}"
    codename="${VERSION_CODENAME:-${DEBIAN_CODENAME:-unknown}}"
  fi
  echo "$name|$ver|$codename"
}

apt_install() { export DEBIAN_FRONTEND=noninteractive; apt-get update -y >/dev/null; apt-get install -y "$@" >/dev/null; }
ensure_deps() { apt_install nginx curl ca-certificates rsync apache2-utils openssl; }
ensure_certbot() { apt_install certbot python3-certbot-nginx; }

ensure_htpasswd_cmd() {
  if ! has_cmd htpasswd; then
    echo "未检测到 htpasswd，正在安装 apache2-utils..."
    apt_install apache2-utils
  fi
}

backup_nginx() {
  local ts dir
  ts="$(date +%Y%m%d_%H%M%S)"
  dir="${BACKUP_ROOT}/nginx-backup-${ts}"
  mkdir -p "$dir/nginx"
  rsync -a /etc/nginx/ "$dir/nginx/"
  echo "$dir"
}
restore_nginx() { local dir="$1"; rsync -a --delete "$dir/nginx/" /etc/nginx/; }

validate_nginx() { local dumpfile="$1"; nginx -t >/dev/null; nginx -T >"$dumpfile" 2>/dev/null; }
reload_nginx() { systemctl enable nginx >/dev/null 2>&1 || true; systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true; }

apply_with_rollback() {
  local backup_dir="$1" dumpfile="$2"
  set +e
  validate_nginx "$dumpfile"
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "❌ nginx 校验失败（nginx -t/-T），开始回滚..."
    echo "---- nginx -T 输出（含错误）已保存：$dumpfile ----"
    restore_nginx "$backup_dir"
    nginx -t >/dev/null 2>&1 || true
    reload_nginx
    echo "✅ 已回滚并恢复 Nginx。"
    return 1
  fi
  reload_nginx
}

ensure_sites_enabled_include() {
  local main="/etc/nginx/nginx.conf"
  [[ -f "$main" ]] || return 0
  grep -qE 'include\s+/etc/nginx/sites-enabled/\*;' "$main" && return 0

  cp -a "$main" "${main}.bak.$(date +%F_%H%M%S)"
  if grep -qE 'include\s+/etc/nginx/conf\.d/\*\.conf;' "$main"; then
    sed -i '/include\s\+\/etc\/nginx\/conf\.d\/\*\.conf;/a\    include /etc/nginx/sites-enabled/*;' "$main"
  else
    sed -i '/http\s*{/a\    include /etc/nginx/sites-enabled/*;' "$main"
  fi
}

nginx_self_heal_compat() {
  local ts main changed
  ts="$(date +%F_%H%M%S)"
  main="/etc/nginx/nginx.conf"
  changed="n"
  [[ -f "$main" ]] || return 0

  # 注释 $http3
  local http3_files
  http3_files="$(grep -RIl '\$http3\b' /etc/nginx 2>/dev/null || true)"
  if [[ -n "$http3_files" ]]; then
    while read -r f; do
      [[ -z "$f" ]] && continue
      cp -a "$f" "${f}.bak.${ts}"
      sed -i '/\$http3\b/s/^/# /' "$f"
    done <<< "$http3_files"
    changed="y"
  fi

  # 注释 quic/http3/ssl_reject_handshake
  if grep -qiE '\b(quic_bpf|http3|ssl_reject_handshake)\b' "$main"; then
    cp -a "$main" "${main}.bak.${ts}"
    sed -i -E '
      s/^\s*quic_bpf\b/# quic_bpf/;
      s/^\s*http3\b/# http3/;
      s/^\s*ssl_reject_handshake\b/# ssl_reject_handshake/;
      s/^\s*(listen .*quic.*;)\s*$/# \1  # disabled by emby-proxy-toolbox/;
    ' "$main"
    changed="y"
  fi

  # 删除 nginx.conf 中 443 ssl default_server 但无证书的 server{}
  if grep -qE 'listen\s+443\s+ssl\s+default_server' "$main"; then
    if ! awk '
      BEGIN{inside=0;has_listen=0;has_cert=0;}
      /server[[:space:]]*\{/ {inside=1;has_listen=0;has_cert=0;}
      inside && /listen[[:space:]]+443[[:space:]]+ssl[[:space:]]+default_server/ {has_listen=1;}
      inside && /ssl_certificate[[:space:]]+/ {has_cert=1;}
      inside && /\}/ {
        if (has_listen && !has_cert) exit 10;
        inside=0;
      }
      END{exit 0;}
    ' "$main"; then
      cp -a "$main" "${main}.bak.${ts}"
      awk '
        BEGIN{state=0;lvl=0;match=0;}
        {
          if (state==0 && $0 ~ /server[[:space:]]*\{/){
            buf[0]=$0; n=1; state=1; lvl=1; match=0; next
          }
          if (state==1){
            buf[n++]=$0
            if ($0 ~ /listen[[:space:]]+443[[:space:]]+ssl[[:space:]]+default_server/) match=1
            if ($0 ~ /\{/) lvl++
            if ($0 ~ /\}/){
              lvl--;
              if (lvl==0){
                if (match==1){
                  has_cert=0
                  for(i=0;i<n;i++){ if (buf[i] ~ /ssl_certificate[[:space:]]+/) has_cert=1 }
                  if (has_cert==0){ state=0; next }
                }
                for(i=0;i<n;i++) print buf[i]
                state=0; next
              }
            }
            next
          }
          if (state==0) print
        }
      ' "$main" > /tmp/nginx.conf.healed && mv /tmp/nginx.conf.healed "$main"
      changed="y"
    fi
  fi

  ensure_sites_enabled_include || true

  if [[ "$changed" == "y" ]]; then
    nginx -t >/dev/null 2>&1 && (systemctl restart nginx >/dev/null 2>&1 || true)
  fi
}

certbot_enable_tls() {
  local domain="$1" email="$2"
  ensure_certbot
  ensure_sites_enabled_include
  nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
  certbot --nginx -d "$domain" --agree-tos -m "$email" --non-interactive --redirect
}

random_pass() { openssl rand -hex 10 2>/dev/null; }

# ========================= 单站反代 =========================
single_conf_path_for_domain() { local d="$1"; echo "${SITES_AVAIL}/${SINGLE_PREFIX}$(sanitize_name "$d").conf"; }
single_enabled_path_for_domain(){ local d="$1"; echo "${SITES_ENAB}/${SINGLE_PREFIX}$(sanitize_name "$d").conf"; }

warn_cf_ports_http_only() {
  local ports_csv; ports_csv="$(normalize_ports_csv "${1:-}")"
  [[ -z "$ports_csv" ]] && return 0
  local ok="80 8080 8880 2052 2082 2086 2095"
  IFS=',' read -r -a arr <<<"$ports_csv"
  for p in "${arr[@]}"; do
    [[ -z "$p" ]] && continue
    for a in $ok; do [[ "$p" == "$a" ]] && continue 2; done
    echo "⚠️ 提示：端口 ${p} 可能不被 Cloudflare 小黄云代理支持。开启橙云后若不可用：改用 8080/8880/2052/2082/2086/2095 或灰云直连。"
  done
}

single_write_site_conf() {
  local domain="$1" origin_host="$2" origin_port="$3" origin_scheme="$4"
  local enable_basicauth="$5" basic_user="$6" basic_pass="$7"
  local use_subpath="$8" subpath="$9"
  local upstream_insecure="${10}" extra_ports_csv="${11}"

  local conf enabled origin safe_ports auth_snip location_block
  conf="$(single_conf_path_for_domain "$domain")"
  enabled="$(single_enabled_path_for_domain "$domain")"
  origin="${origin_host}:${origin_port}"
  safe_ports="$(normalize_ports_csv "$extra_ports_csv")"

  auth_snip=""
  if [[ "$enable_basicauth" == "y" ]]; then
    ensure_htpasswd_cmd
    htpasswd -bc "$SINGLE_HTPASSWD" "$basic_user" "$basic_pass" >/dev/null
    auth_snip=$'auth_basic "Restricted";\n        auth_basic_user_file '"$SINGLE_HTPASSWD"$';\n'
  fi

  if [[ "$use_subpath" == "y" ]]; then
    location_block=$(cat <<EOF
    location = $subpath { return 301 $subpath/; }

    location ^~ $subpath/ {
        ${auth_snip}proxy_pass $origin_scheme://$origin/;

        proxy_http_version 1.1;
        proxy_set_header Host \$proxy_host;
        proxy_set_header X-Forwarded-Host \$host;

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        client_max_body_size 500m;

        rewrite ^$subpath/(.*)\$ /\$1 break;
        proxy_redirect ~^(/.*)\$ $subpath\$1;
EOF
)
    if [[ "$origin_scheme" == "https" ]]; then
      [[ "$upstream_insecure" == "y" ]] && location_block+=$'\n        proxy_ssl_verify off;\n'
      location_block+=$'        proxy_ssl_server_name on;\n'
    fi
    location_block+=$'    }\n'
  else
    location_block=$(cat <<EOF
    location / {
        ${auth_snip}proxy_pass $origin_scheme://$origin;

        proxy_http_version 1.1;
        proxy_set_header Host \$proxy_host;
        proxy_set_header X-Forwarded-Host \$host;

        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;

        client_max_body_size 500m;
EOF
)
    if [[ "$origin_scheme" == "https" ]]; then
      [[ "$upstream_insecure" == "y" ]] && location_block+=$'\n        proxy_ssl_verify off;\n'
      location_block+=$'        proxy_ssl_server_name on;\n'
    fi
    location_block+=$'    }\n'
  fi

  cat >"$conf" <<EOF
# ${TOOL_NAME} / 单站反代：${domain}
# Managed by ${TOOL_NAME}
# META domain=${domain} origin=${origin_scheme}://${origin} subpath=${subpath} extra_ports=${safe_ports} basicauth=${enable_basicauth}

map \$http_upgrade \$connection_upgrade {
  default upgrade;
  ''      close;
}

server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

${location_block}
}
EOF

  if [[ -n "${safe_ports// /}" ]]; then
    IFS=',' read -r -a ports <<<"$safe_ports"
    for p in "${ports[@]}"; do
      [[ -z "$p" ]] && continue
      is_port "$p" || { echo "端口非法：$p"; return 1; }
      [[ "$p" == "80" || "$p" == "443" ]] && { echo "额外端口不允许使用 80/443：$p"; return 1; }
      cat >>"$conf" <<EOF

server {
  listen ${p};
  listen [::]:${p};
  server_name _;
${location_block}
}
EOF
    done
  fi

  ln -sf "$conf" "$enabled"
  rm -f "${SITES_ENAB}/default" >/dev/null 2>&1 || true
}

single_print_usage_hint() {
  local domain="$1" subpath="$2" enable_ssl="$3" ports_csv="$4"
  local main="http://${domain}"
  [[ "$enable_ssl" == "y" ]] && main="https://${domain}"
  if [[ "$subpath" != "/" && -n "$subpath" ]]; then main="${main}${subpath}"; else main="${main}/"; fi

  echo
  echo "================ 使用方法 ================"
  echo "主入口："
  echo "  浏览器：${main}"
  echo "  Emby 客户端：服务器地址填 ${main%/}"
  if [[ -n "${ports_csv// /}" ]]; then
    ports_csv="$(normalize_ports_csv "$ports_csv")"
    echo
    echo "额外端口入口（HTTP 明文）："
    IFS=',' read -r -a ports <<<"$ports_csv"
    for p in "${ports[@]}"; do
      [[ -z "$p" ]] && continue
      echo "  - http://${domain}:${p}/"
      echo "  - http://VPS_IP:${p}/"
    done
  fi
  echo
  echo "注意：IP + HTTPS 会证书不匹配（正常），推荐域名 + HTTPS。"
  echo "=========================================="
  echo
}

single_action_add_or_edit() {
  local DOMAIN ORIGIN_HOST ORIGIN_PORT ORIGIN_SCHEME
  local ENABLE_SSL EMAIL ENABLE_UFW
  local ENABLE_BASICAUTH BASIC_USER BASIC_PASS
  local USE_SUBPATH SUBPATH UPSTREAM_INSECURE EXTRA_PORTS

  prompt DOMAIN "访问域名（只填域名，不要 https://）"
  DOMAIN="$(strip_scheme "$DOMAIN")"
  prompt ORIGIN_HOST "源站域名或IP（可误输 http(s)://，会自动去掉）"
  ORIGIN_HOST="$(strip_scheme "$ORIGIN_HOST")"
  prompt ORIGIN_PORT "源站端口" "8096"
  is_port "$ORIGIN_PORT" || { echo "端口不合法：$ORIGIN_PORT"; return 1; }
  prompt ORIGIN_SCHEME "源站协议 http/https" "http"
  [[ "$ORIGIN_SCHEME" == "http" || "$ORIGIN_SCHEME" == "https" ]] || { echo "协议只能是 http 或 https"; return 1; }

  yesno ENABLE_SSL "为主入口申请 Let's Encrypt（启用 443 并 80->443）" "y"
  EMAIL="admin@${DOMAIN}"
  [[ "$ENABLE_SSL" == "y" ]] && prompt EMAIL "证书邮箱" "$EMAIL"

  yesno ENABLE_UFW "自动用 UFW 放通 80/443 + 额外端口（不影响云安全组）" "n"

  yesno ENABLE_BASICAUTH "启用 BasicAuth（额外一层门禁，可选）" "n"
  BASIC_USER="emby"; BASIC_PASS=""
  if [[ "$ENABLE_BASICAUTH" == "y" ]]; then
    prompt BASIC_USER "BasicAuth 用户名" "emby"
    prompt BASIC_PASS "BasicAuth 密码"
  fi

  yesno USE_SUBPATH "使用子路径（例如 /emby）" "n"
  SUBPATH="/"
  if [[ "$USE_SUBPATH" == "y" ]]; then
    prompt SUBPATH "子路径（以 / 开头，不以 / 结尾）" "/emby"
    [[ "$SUBPATH" == /* ]] || SUBPATH="/$SUBPATH"
    [[ "$SUBPATH" != */ ]] || { echo "子路径不能以 / 结尾"; return 1; }
  fi

  UPSTREAM_INSECURE="n"
  if [[ "$ORIGIN_SCHEME" == "https" ]]; then
    yesno UPSTREAM_INSECURE "源站 HTTPS 为自签/不受信证书（跳过验证）" "n"
  fi

  prompt EXTRA_PORTS "额外端口入口（逗号分隔，可空；如 18443,28096）" ""
  EXTRA_PORTS="$(normalize_ports_csv "$EXTRA_PORTS")"
  if [[ -n "${EXTRA_PORTS// /}" ]]; then
    IFS=',' read -r -a arr <<<"$EXTRA_PORTS"
    for p in "${arr[@]}"; do
      [[ -z "$p" ]] && continue
      is_port "$p" || { echo "额外端口不合法：$p"; return 1; }
      [[ "$p" == "80" || "$p" == "443" ]] && { echo "额外端口不能用 80/443：$p"; return 1; }
    done
  fi

  warn_cf_ports_http_only "$EXTRA_PORTS"

  echo
  echo "---- 配置确认 ----"
  echo "入口域名:     $DOMAIN"
  echo "回源:         $ORIGIN_SCHEME://$ORIGIN_HOST:$ORIGIN_PORT"
  echo "子路径:       $SUBPATH"
  echo "主入口 HTTPS: $ENABLE_SSL"
  echo "BasicAuth:    $ENABLE_BASICAUTH"
  echo "UFW:          $ENABLE_UFW"
  echo "额外端口:     ${EXTRA_PORTS:-（无）} (HTTP)"
  echo "------------------"
  echo

  ensure_deps
  ensure_sites_enabled_include
  nginx_self_heal_compat

  local backup dump
  backup="$(backup_nginx)"
  dump="$(mktemp)"
  trap 'rm -f "$dump"' RETURN

  set +e
  single_write_site_conf "$DOMAIN" "$ORIGIN_HOST" "$ORIGIN_PORT" "$ORIGIN_SCHEME" \
    "$ENABLE_BASICAUTH" "$BASIC_USER" "$BASIC_PASS" \
    "$USE_SUBPATH" "$SUBPATH" \
    "$UPSTREAM_INSECURE" "$EXTRA_PORTS"
  local rc_write=$?
  set -e
  if [[ $rc_write -ne 0 ]]; then
    echo "❌ 写入配置失败，回滚..."
    restore_nginx "$backup"
    reload_nginx
    return 1
  fi

  apply_with_rollback "$backup" "$dump" || return 1

  if [[ "$ENABLE_UFW" == "y" ]]; then
    if ! has_cmd ufw; then apt_install ufw; fi
    ufw allow 80/tcp >/dev/null || true
    ufw allow 443/tcp >/dev/null || true
    if [[ -n "${EXTRA_PORTS// /}" ]]; then
      IFS=',' read -r -a arr <<<"$EXTRA_PORTS"
      for p in "${arr[@]}"; do [[ -z "$p" ]] && continue; ufw allow "${p}/tcp" >/dev/null || true; done
    fi
  fi

  if [[ "$ENABLE_SSL" == "y" ]]; then
    set +e
    certbot_enable_tls "$DOMAIN" "$EMAIL"
    local rc_cert=$?
    set -e
    if [[ $rc_cert -ne 0 ]]; then
      echo "❌ certbot 配置失败，回滚..."
      restore_nginx "$backup"
      reload_nginx
      return 1
    fi
    apply_with_rollback "$backup" "$dump" || return 1
  fi

  echo "✅ 已生效：$DOMAIN"
  echo "站点配置：$(single_conf_path_for_domain "$DOMAIN")"
  echo "备份目录：$backup"
  [[ "$USE_SUBPATH" == "y" ]] && echo "⚠️ 子路径：建议在 Emby 后台 Base URL 设置为 $SUBPATH 并重启 Emby。"
  single_print_usage_hint "$DOMAIN" "$SUBPATH" "$ENABLE_SSL" "$EXTRA_PORTS"
}

single_action_list() {
  echo "=== 现有单站反代（${SITES_AVAIL}/${SINGLE_PREFIX}*.conf）==="
  shopt -s nullglob
  local files=("${SITES_AVAIL}/${SINGLE_PREFIX}"*.conf)
  if [[ ${#files[@]} -eq 0 ]]; then echo "（空）"; return 0; fi
  for f in "${files[@]}"; do
    local meta domain origin subpath ports basicauth
    meta="$(grep -E '^# META ' "$f" | head -n1 || true)"
    domain="$(echo "$meta" | sed -n 's/.*domain=\([^ ]*\).*/\1/p')"
    origin="$(echo "$meta" | sed -n 's/.*origin=\([^ ]*\).*/\1/p')"
    subpath="$(echo "$meta" | sed -n 's/.*subpath=\([^ ]*\).*/\1/p')"
    ports="$(echo "$meta" | sed -n 's/.*extra_ports=\([^ ]*\).*/\1/p')"
    basicauth="$(echo "$meta" | sed -n 's/.*basicauth=\([^ ]*\).*/\1/p')"
    [[ -z "$subpath" ]] && subpath="/"
    [[ -z "$ports" ]] && ports="（无）"
    [[ -z "$basicauth" ]] && basicauth="n"
    echo "- ${domain:-（未知域名）}"
    echo "    回源: ${origin:-（未知）}"
    echo "    子路径: $subpath"
    echo "    额外端口: $ports (HTTP)"
    echo "    BasicAuth: $basicauth"
    echo "    conf: $f"
  done
}

single_action_delete() {
  local DOMAIN DEL_CERT
  prompt DOMAIN "要删除的访问域名（server_name）"
  DOMAIN="$(strip_scheme "$DOMAIN")"

  local conf enabled
  conf="$(single_conf_path_for_domain "$DOMAIN")"
  enabled="$(single_enabled_path_for_domain "$DOMAIN")"

  if [[ ! -f "$conf" && ! -L "$enabled" ]]; then echo "没找到该站点：$DOMAIN"; return 1; fi
  yesno DEL_CERT "是否同时删除证书（仍需你手动执行 certbot delete）" "n"

  ensure_deps
  ensure_sites_enabled_include
  nginx_self_heal_compat

  local backup dump
  backup="$(backup_nginx)"
  dump="$(mktemp)"
  trap 'rm -f "$dump"' RETURN

  rm -f "$enabled" "$conf"
  apply_with_rollback "$backup" "$dump" || return 1

  echo "✅ 已删除站点：$DOMAIN"
  echo "备份目录：$backup"
  if [[ "$DEL_CERT" == "y" ]] && has_cmd certbot; then
    echo "证书删除请手动执行：certbot delete --cert-name $DOMAIN"
  fi
}

single_menu() {
  IFS="|" read -r OS_NAME OS_VER OS_CODE < <(os_info)
  echo
  echo "=== 单站反代管理器 ==="
  echo "系统：${OS_NAME} / ${OS_VER} / ${OS_CODE}"
  echo
  while true; do
    echo "========== 单站菜单 =========="
    echo "1) 添加/覆盖单站反代（可选额外端口）"
    echo "2) 查看现有单站反代"
    echo "3) 修改单站反代（= 覆盖同域名）"
    echo "4) 删除单站反代"
    echo "5) Nginx 测试与状态"
    echo "0) 返回上级"
    echo "=============================="
    read -r -p "请选择: " c
    case "$c" in
      1) single_action_add_or_edit ;;
      2) single_action_list ;;
      3) single_action_add_or_edit ;;
      4) single_action_delete ;;
      5) echo "nginx -t：" && nginx -t && echo && (systemctl status nginx --no-pager || true) ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

# ========================= 通用网关 =========================
gw_conf_path_for_domain() { local d="$1"; echo "${SITES_AVAIL}/${GW_PREFIX}$(sanitize_name "$d").conf"; }
gw_enabled_path_for_domain(){ local d="$1"; echo "${SITES_ENAB}/${GW_PREFIX}$(sanitize_name "$d").conf"; }

gw_write_map_conf() {
  mkdir -p /etc/nginx/conf.d
  cat > "$GW_MAP_CONF" <<'EOF'
# Managed by emby-proxy-toolbox (universal gateway)
# Loaded under http{} via /etc/nginx/conf.d/*.conf

map $http_upgrade $connection_upgrade {
  default upgrade;
  ""      close;
}

map $up_target $up_host_only {
  default                                $up_target;
  ~^\[(?<h>[A-Fa-f0-9:.]+)\](:\d+)?$     [$h];
  ~^(?<h>[^:]+)(:\d+)?$                  $h;
}
EOF
}
gw_write_locations_snippet() {
  local enable_basicauth="$1" enable_ip_whitelist="$2" whitelist_csv="$3"

  mkdir -p /etc/nginx/snippets

  # build auth/allow blocks into temp files (no awk; avoids multiline escaping issues)
  local tmp_auth tmp_allow
  tmp_auth="$(mktemp)"
  tmp_allow="$(mktemp)"

  # auth block
  if [[ "$enable_basicauth" == "y" ]]; then
    cat >"$tmp_auth" <<'EOF'
    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd-emby-gw;
EOF
  else
    : >"$tmp_auth"
  fi

  # allowlist block
  if [[ "$enable_ip_whitelist" == "y" ]]; then
    : >"$tmp_allow"
    local csv="${whitelist_csv// /}"
    IFS=',' read -r -a arr <<<"$csv"
    for cidr in "${arr[@]}"; do
      [[ -z "$cidr" ]] && continue
      printf '    allow %s;\n' "$cidr" >>"$tmp_allow"
    done
    printf '    deny all;\n' >>"$tmp_allow"
  else
    : >"$tmp_allow"
  fi

  cat > "$GW_SNIP_CONF" <<'EOF'
# Managed by emby-proxy-toolbox (universal gateway)
# Included inside server{} (这里不能出现 map 指令)

proxy_http_version 1.1;

proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $connection_upgrade;

proxy_set_header Range $http_range;
proxy_set_header If-Range $http_if_range;

proxy_buffering off;
proxy_request_buffering off;

proxy_read_timeout 3600s;
proxy_send_timeout 3600s;

client_max_body_size 500m;

# Nginx resolver for variable proxy_pass (do NOT use 127.0.0.1 unless you run local DNS)
resolver 1.1.1.1 8.8.8.8 valid=60s;
resolver_timeout 5s;

# Normalize (avoid "Location: web/index.html" losing target)
location ~ ^/http/(?<up_target>[A-Za-z0-9.\-_\[\]:]+)$  { return 301 /http/$up_target/; }
location ~ ^/https/(?<up_target>[A-Za-z0-9.\-_\[\]:]+)$ { return 301 /https/$up_target/; }
location ~ ^/(?<up_target>[A-Za-z0-9.\-_\[\]:]+)$       { return 301 /$up_target/; }

# /http/<target>/...
location ~ ^/http/(?<up_target>[A-Za-z0-9.\-_\[\]:]+)(?<up_rest>/.*)?$ {
    set $up_scheme http;
    if ($up_rest = "") { set $up_rest "/"; }

#@@AUTH@@
#@@ALLOW@@

    proxy_set_header Host $up_host_only;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_ssl_server_name on;

    # 前后端分离：后端 URL 重写（如未配置规则，该文件为空，不影响）
    include /etc/nginx/snippets/emby-gw-rewrite.conf;

    # Rewrite redirects back to gateway to prevent client bypass.
    # Many clients require ABSOLUTE Location; we emit https://$host/...
    proxy_redirect off;
    proxy_redirect ~^http://([^/]+)(/.*)$  https://$host/http/$1$2;
    proxy_redirect ~^https://([^/]+)(/.*)$ https://$host/https/$1$2;
    proxy_redirect ~^/(.*)$               https://$host/http/$up_target/$1;
    proxy_redirect ~^([^/].*)$            https://$host/http/$up_target/$1;

    proxy_pass $up_scheme://$up_target$up_rest$is_args$args;
}

# /https/<target>/...
location ~ ^/https/(?<up_target>[A-Za-z0-9.\-_\[\]:]+)(?<up_rest>/.*)?$ {
    set $up_scheme https;
    if ($up_rest = "") { set $up_rest "/"; }

#@@AUTH@@
#@@ALLOW@@

    proxy_set_header Host $up_host_only;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_ssl_server_name on;

    # 前后端分离：后端 URL 重写（如未配置规则，该文件为空，不影响）
    include /etc/nginx/snippets/emby-gw-rewrite.conf;

    proxy_redirect off;
    proxy_redirect ~^http://([^/]+)(/.*)$  https://$host/http/$1$2;
    proxy_redirect ~^https://([^/]+)(/.*)$ https://$host/https/$1$2;
    proxy_redirect ~^/(.*)$               https://$host/https/$up_target/$1;
    proxy_redirect ~^([^/].*)$            https://$host/https/$up_target/$1;

    proxy_pass $up_scheme://$up_target$up_rest$is_args$args;
}

# Default: /<target>/... (scheme defaults to https)
location ~ ^/(?<up_target>[A-Za-z0-9.\-_\[\]:]+)(?<up_rest>/.*)?$ {
    set $up_scheme https;
    if ($up_rest = "") { set $up_rest "/"; }

#@@AUTH@@
#@@ALLOW@@

    proxy_set_header Host $up_host_only;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_ssl_server_name on;

    # 前后端分离：后端 URL 重写（如未配置规则，该文件为空，不影响）
    include /etc/nginx/snippets/emby-gw-rewrite.conf;

    proxy_redirect off;
    proxy_redirect ~^http://([^/]+)(/.*)$  https://$host/http/$1$2;
    proxy_redirect ~^https://([^/]+)(/.*)$ https://$host/https/$1$2;
    proxy_redirect ~^/(.*)$               https://$host/$up_target/$1;
    proxy_redirect ~^([^/].*)$            https://$host/$up_target/$1;

    proxy_pass $up_scheme://$up_target$up_rest$is_args$args;
}
EOF

  # Insert blocks (multiline safe)
  if [[ -s "$tmp_auth" ]]; then
    sed -i "/^#@@AUTH@@/r $tmp_auth" "$GW_SNIP_CONF"
  fi
  sed -i "/^#@@AUTH@@/d" "$GW_SNIP_CONF"

  if [[ -s "$tmp_allow" ]]; then
    sed -i "/^#@@ALLOW@@/r $tmp_allow" "$GW_SNIP_CONF"
  fi
  sed -i "/^#@@ALLOW@@/d" "$GW_SNIP_CONF"

  rm -f "$tmp_auth" "$tmp_allow"
}


gw_write_site_conf() {
  local domain="$1"
  local conf enabled
  conf="$(gw_conf_path_for_domain "$domain")"
  enabled="$(gw_enabled_path_for_domain "$domain")"

  cat >"$conf" <<EOF
# ${TOOL_NAME} / 通用反代网关：${domain}
# Managed by ${TOOL_NAME}

server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  location ^~ /.well-known/acme-challenge/ {
    root /var/www/html;
    try_files \$uri =404;
  }

  location = / {
    default_type text/plain;
    return 200 "OK\\n\\n通用反代网关使用方式（填写到 Emby 客户端“服务器地址”）：\\n\\n  https://${domain}/<上游主机:端口>\\n  https://${domain}/http/<上游主机:端口>\\n\\n说明：默认按 https 回源；若需要 http 回源用 /http 前缀。\\n\\n安全提示：建议开启 BasicAuth 或 IP 白名单，避免 OPEN PROXY。\\n";
  }

  include /etc/nginx/snippets/emby-gw-locations.conf;
}
EOF

  ln -sf "$conf" "$enabled"
  rm -f "${SITES_ENAB}/default" >/dev/null 2>&1 || true
}

gw_print_usage() {
  local domain="$1" ssl="$2" user="${3:-}" pass="${4:-}"
  local base="http://${domain}"; [[ "$ssl" == "y" ]] && base="https://${domain}"
  echo
  echo "================ 通用网关用法 ================"
  echo "在 Emby 客户端服务器地址中填写："
  echo "  ${base}/<上游主机:端口>        （默认按 https 回源）"
  echo "  ${base}/http/<上游主机:端口>   （强制 http 回源）"
  echo
  echo "示例（仅示意，非真实地址）："
  echo "  ${base}/example.com:443"
  echo "  ${base}/http/203.0.113.10:8096"
  echo
  if [[ -n "$user" ]]; then
    echo "已开启 BasicAuth（网关额外门禁；不影响上游 Emby 自身账号密码）："
    echo "  用户名: $user"
    echo "  密码:   $pass"
    echo "注意：部分客户端（如某些 SenPlayer/Forward 组合）不支持 BasicAuth，会导致无法使用。"
  else
    echo "未开启 BasicAuth。"
  fi
  echo "=============================================="
  echo
}

# -------------------- 通用网关：前后端分离（后端 URL 重写） --------------------
gw_parse_backend_input() {
  # input: URL 或 host[:port][/path]
  # output: scheme|host|port|path_prefix
  local raw="$1"
  raw="$(echo "$raw" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$raw" ]] || { echo "|||" ; return 0; }

  local scheme="http"
  if [[ "$raw" =~ ^https?:// ]]; then
    scheme="${raw%%://*}"
    raw="${raw#*://}"
  fi

  # strip query/fragment
  raw="${raw%%\#*}"
  raw="${raw%%\?*}"

  local hostport path="/"
  if [[ "$raw" == */* ]]; then
    hostport="${raw%%/*}"
    path="/${raw#*/}"
  else
    hostport="$raw"
    path="/"
  fi

  local host="$hostport" port=""
  # IPv6 in brackets: [::1]:8080
  if [[ "$hostport" =~ ^\[(.+)\]:(\d+)$ ]]; then
    host="[${BASH_REMATCH[1]}]"
    port="${BASH_REMATCH[2]}"
  elif [[ "$hostport" =~ ^\[(.+)\]$ ]]; then
    host="[${BASH_REMATCH[1]}]"
    port=""
  elif [[ "$hostport" =~ ^(.+):(\d+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  fi

  if [[ -z "$port" ]]; then
    if [[ "$scheme" == "https" ]]; then port="443"; else port="80"; fi
  fi

  # path_prefix: 只取第一段，减少误伤（/stream/xxx -> /stream）
  local prefix=""
  if [[ "$path" != "/" && -n "$path" ]]; then
    local seg="${path#/}"
    seg="${seg%%/*}"
    [[ -n "$seg" ]] && prefix="/$seg"
  fi

  echo "${scheme}|${host}|${port}|${prefix}"
}

gw_rewrite_ensure_files() {
  mkdir -p /etc/nginx/snippets
  [[ -f "$GW_REWRITE_RULES" ]] || : >"$GW_REWRITE_RULES"
  [[ -f "$GW_REWRITE_SNIP" ]]  || : >"$GW_REWRITE_SNIP"
}

gw_rewrite_render_snippet() {
  local gw_domain="$1"   # gateway entry domain, used as literal in sub_filter replacement
  gw_rewrite_ensure_files

  : >"$GW_REWRITE_SNIP"
  cat >>"$GW_REWRITE_SNIP" <<EOF
# Managed by ${TOOL_NAME} (gateway backend URL rewrite)
# 注意：sub_filter 只能改写“响应内容/可见 Location”，无法拦截客户端完全独立直连的第二域名。
# gateway: ${gw_domain}

EOF

  if [[ ! -s "$GW_REWRITE_RULES" ]]; then
    echo "# (no rewrite rules)" >>"$GW_REWRITE_SNIP"
    return 0
  fi

  cat >>"$GW_REWRITE_SNIP" <<'EOF'
# Enable sub_filter (force upstream uncompressed)
proxy_set_header Accept-Encoding "";
sub_filter_once off;
sub_filter_types text/html text/plain application/json application/javascript text/css;
EOF

  while IFS='|' read -r scheme host port prefix; do
    [[ -z "$scheme" || -z "$host" || -z "$port" ]] && continue
    [[ "$scheme" != "http" && "$scheme" != "https" ]] && continue
    prefix="${prefix:-}"
    [[ -n "$prefix" && "$prefix" != /* ]] && prefix="/$prefix"

    local target="${host}:${port}"
    local gw_base="https://${gw_domain}"
    local rep_base="${gw_base}/${scheme}/${target}${prefix}"

    # Build search candidates (with/without explicit port for default ports)
    local default_port="80"
    [[ "$scheme" == "https" ]] && default_port="443"

    local with_port="${scheme}://${host}:${port}${prefix}"
    local no_port="${scheme}://${host}${prefix}"
    local with_port_sr="//${host}:${port}${prefix}"
    local no_port_sr="//${host}${prefix}"

    if [[ "$port" == "$default_port" ]]; then
      printf 'sub_filter "%s" "%s";\n' "$no_port"     "$rep_base" >>"$GW_REWRITE_SNIP"
      printf 'sub_filter "%s" "%s";\n' "$with_port"   "$rep_base" >>"$GW_REWRITE_SNIP"
      printf 'sub_filter "%s" "%s";\n' "$no_port_sr"  "$rep_base" >>"$GW_REWRITE_SNIP"
      printf 'sub_filter "%s" "%s";\n' "$with_port_sr" "$rep_base" >>"$GW_REWRITE_SNIP"
    else
      printf 'sub_filter "%s" "%s";\n' "$with_port"   "$rep_base" >>"$GW_REWRITE_SNIP"
      printf 'sub_filter "%s" "%s";\n' "$with_port_sr" "$rep_base" >>"$GW_REWRITE_SNIP"
    fi
  done <"$GW_REWRITE_RULES"
}

gw_rewrite_apply_reload() {
  local gw_domain="$1"
  ensure_deps
  ensure_sites_enabled_include
  nginx_self_heal_compat

  local backup dump
  backup="$(backup_nginx)"
  dump="$(mktemp)"
  trap 'rm -f "$dump"' RETURN

  gw_rewrite_render_snippet "$gw_domain"
  apply_with_rollback "$backup" "$dump" || return 1
  return 0
}

gw_rewrite_add_rule() {
  local gw_domain="$1"
  gw_rewrite_ensure_files

  echo
  echo "请直接粘贴你抓包看到的“后端地址”（脚本自动分析）："
  echo "示例（占位示例域名）："
  echo "  http://media-backend.example.net/stream"
  echo "  http://origin-node.example.org:2052"
  echo "  https://api.example.com:443/base"
  echo "也可以只填 host 或 host:port 或 host/path（未写协议默认按 http 处理）"
  echo
  local backend_in=""
  prompt backend_in "后端地址（URL/host:port/path）"
  [[ -n "$backend_in" ]] || { echo "输入为空，已取消。"; return 1; }

  local parsed scheme host port prefix
  parsed="$(gw_parse_backend_input "$backend_in")"
  IFS='|' read -r scheme host port prefix <<<"$parsed"

  echo
  echo "---- 解析结果 ----"
  echo "协议:     ${scheme}"
  echo "主机:     ${host}"
  echo "端口:     ${port}"
  echo "路径前缀: ${prefix:-/（未指定）}"
  echo "------------------"
  echo

  local ok
  yesno ok "确认添加该后端重写规则" "y"
  [[ "$ok" == "y" ]] || { echo "已取消。"; return 0; }

  local line="${scheme}|${host}|${port}|${prefix}"
  # avoid duplicates
  grep -Fxq "$line" "$GW_REWRITE_RULES" 2>/dev/null || echo "$line" >>"$GW_REWRITE_RULES"

  gw_rewrite_apply_reload "$gw_domain" || return 1
  echo "✅ 已添加并生效：$line"
  echo "提示：该功能仅在后端 URL 出现在 HTML/JS/JSON 或可见 Location 中时有效。"
}

gw_rewrite_list_rules() {
  gw_rewrite_ensure_files
  echo "=== 当前后端重写规则（scheme|host|port|path_prefix）==="
  if [[ ! -s "$GW_REWRITE_RULES" ]]; then
    echo "（空）"
    return 0
  fi
  nl -ba "$GW_REWRITE_RULES"
}

gw_rewrite_delete_rule() {
  local gw_domain="$1"
  gw_rewrite_list_rules
  [[ -s "$GW_REWRITE_RULES" ]] || return 0

  local n
  prompt n "请输入要删除的规则行号"
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "行号不合法"; return 1; }
  sed -i "${n}d" "$GW_REWRITE_RULES" || true
  gw_rewrite_apply_reload "$gw_domain" || return 1
  echo "✅ 已删除并生效。"
}

gw_rewrite_clear_rules() {
  local gw_domain="$1"
  local ok
  yesno ok "确认清空全部重写规则" "n"
  [[ "$ok" == "y" ]] || { echo "已取消。"; return 0; }
  : >"$GW_REWRITE_RULES"
  gw_rewrite_apply_reload "$gw_domain" || return 1
  echo "✅ 已清空并生效。"
}

gw_rewrite_menu() {
  local gw_domain=""
  prompt gw_domain "请输入当前网关入口域名（只填域名，不要 https://；用于生成重写 URL）"
  gw_domain="$(strip_scheme "$gw_domain")"
  [[ -n "$gw_domain" ]] || { echo "域名不能为空"; return 1; }

  while true; do
    echo
    echo "========== 前后端分离配置（通用网关） =========="
    echo "用途：当 Emby 前端域名 A 可用，但播放/接口跳到后端域名 B 时，尝试把响应中的 B 改写回网关。"
    echo "注意：仅对 HTML/JS/JSON/Location 可见时有效；若客户端直接硬连 B，此法无效（需 DNS 接管）。"
    echo
    echo "1) 添加后端重写规则（粘贴抓包后端地址 URL）"
    echo "2) 查看现有规则"
    echo "3) 删除一条规则"
    echo "4) 清空全部规则"
    echo "0) 返回"
    echo "=============================================="
    read -r -p "请选择: " c
    case "$c" in
      1) gw_rewrite_add_rule "$gw_domain" ;;
      2) gw_rewrite_list_rules ;;
      3) gw_rewrite_delete_rule "$gw_domain" ;;
      4) gw_rewrite_clear_rules "$gw_domain" ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

frontsplit_guide() {
  echo
  echo "=== 前后端分离向导（通用网关）==="
  echo "当某些 Emby 服存在：前端域名 A / 后端（推流）域名 B 的情况时，客户端可能会绕过网关直连 B。"
  echo "本向导提供“后端 URL 重写”能力：把响应中出现的 B 改写成走网关的 /http/ 或 /https/ 路径。"
  echo
  echo "操作建议："
  echo "  1) 先确保通用网关已部署且可访问（主菜单 2 -> 网关安装/更新）。"
  echo "  2) 用抓包/开发者工具找到后端地址（如 http://media-backend.example.net/stream）。"
  echo "  3) 进入本向导添加规则，保存后重新在客户端刷新/重新添加服务器。"
  echo
  gw_rewrite_menu
}
gw_action_install_update() {
  local DOMAIN ENABLE_SSL EMAIL ENABLE_BASICAUTH BASIC_USER BASIC_PASS ENABLE_IPWL IPWL ok
  prompt DOMAIN "你的网关入口域名（例如 autoemby.example.com；只填域名，不要 https://）"
  DOMAIN="$(strip_scheme "$DOMAIN")"
  [[ -n "$DOMAIN" ]] || { echo "域名不能为空"; return 1; }

  yesno ENABLE_SSL "为网关域名申请 Let's Encrypt（启用 443 并 80->443）" "y"
  EMAIL="admin@${DOMAIN}"
  [[ "$ENABLE_SSL" == "y" ]] && prompt EMAIL "证书邮箱" "$EMAIL"

  yesno ENABLE_BASICAUTH "启用 BasicAuth（强烈建议；但注意部分客户端不支持）" "y"
  BASIC_USER="emby"; BASIC_PASS=""
  if [[ "$ENABLE_BASICAUTH" == "y" ]]; then
    prompt BASIC_USER "BasicAuth 用户名" "emby"
    BASIC_PASS="$(random_pass)"
    prompt BASIC_PASS "BasicAuth 密码（直接回车=自动生成）" "$BASIC_PASS"
  fi

  yesno ENABLE_IPWL "启用 IP 白名单（可选）" "n"
  IPWL=""
  if [[ "$ENABLE_IPWL" == "y" ]]; then
    prompt IPWL "白名单（逗号分隔，例如 1.2.3.4/32,5.6.7.8/32）"
    [[ -n "$IPWL" ]] || { echo "白名单不能为空"; return 1; }
  fi

  if [[ "$ENABLE_BASICAUTH" == "n" && "$ENABLE_IPWL" == "n" ]]; then
    echo "⚠️ 警告：你同时关闭了 BasicAuth 和 IP 白名单，这会把网关变成 OPEN PROXY（高风险）。"
    yesno ok "仍要继续安装吗" "n"
    [[ "$ok" == "y" ]] || { echo "已取消"; return 0; }
  fi

  echo
  echo "---- 配置确认 ----"
  echo "入口域名:   $DOMAIN"
  echo "网关 HTTPS: $ENABLE_SSL"
  echo "BasicAuth:  $ENABLE_BASICAUTH"
  echo "IP 白名单:  $ENABLE_IPWL"
  echo "------------------"
  echo

  ensure_deps
  ensure_sites_enabled_include
  nginx_self_heal_compat

  if [[ "$ENABLE_BASICAUTH" == "y" ]]; then
    ensure_htpasswd_cmd
    htpasswd -bc "$GW_HTPASSWD" "$BASIC_USER" "$BASIC_PASS" >/dev/null
  fi

  local backup dump
  backup="$(backup_nginx)"
  dump="$(mktemp)"
  trap 'rm -f "$dump"' RETURN

  gw_write_map_conf
  gw_write_locations_snippet "$ENABLE_BASICAUTH" "$ENABLE_IPWL" "$IPWL"
  gw_rewrite_ensure_files
  gw_rewrite_render_snippet "$DOMAIN"
  gw_write_site_conf "$DOMAIN"

  apply_with_rollback "$backup" "$dump" || return 1

  if [[ "$ENABLE_SSL" == "y" ]]; then
    set +e
    certbot_enable_tls "$DOMAIN" "$EMAIL"
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      echo "❌ certbot 配置失败，回滚..."
      restore_nginx "$backup"
      reload_nginx
      return 1
    fi
    apply_with_rollback "$backup" "$dump" || return 1
  fi

  echo "✅ 网关已生效：$DOMAIN"
  echo "站点配置：$(gw_conf_path_for_domain "$DOMAIN")"
  echo "备份目录：$backup"
  if [[ "$ENABLE_BASICAUTH" == "y" ]]; then gw_print_usage "$DOMAIN" "$ENABLE_SSL" "$BASIC_USER" "$BASIC_PASS"; else gw_print_usage "$DOMAIN" "$ENABLE_SSL"; fi
}

gw_action_status() {
  echo "=== 通用网关状态 ==="
  ls -l "${SITES_AVAIL}/${GW_PREFIX}"*.conf 2>/dev/null || echo "（未发现网关站点配置）"
  echo
  nginx -t || true
  echo
  systemctl status nginx --no-pager || true
  echo
  [[ -f "$GW_MAP_CONF" ]] && echo "Map 文件：$GW_MAP_CONF（存在）" || echo "Map 文件：$GW_MAP_CONF（缺失）"
  [[ -f "$GW_SNIP_CONF" ]] && echo "Snippet： $GW_SNIP_CONF（存在）" || echo "Snippet： $GW_SNIP_CONF（缺失）"
  [[ -f "$GW_HTPASSWD" ]] && echo "BasicAuth：$GW_HTPASSWD（存在）" || echo "BasicAuth：$GW_HTPASSWD（缺失/未启用）"
}

gw_action_change_auth() {
  local user pass
  if [[ ! -f "$GW_HTPASSWD" ]]; then
    echo "未找到 BasicAuth 文件：$GW_HTPASSWD"
    echo "请先在“安装/更新”中启用 BasicAuth。"
    return 1
  fi
  ensure_deps
  ensure_htpasswd_cmd
  prompt user "新的 BasicAuth 用户名" "emby"
  pass="$(random_pass)"
  prompt pass "新的 BasicAuth 密码（直接回车=自动生成）" "$pass"
  htpasswd -bc "$GW_HTPASSWD" "$user" "$pass" >/dev/null
  reload_nginx
  echo "✅ 已更新 BasicAuth："
  echo "  用户名: $user"
  echo "  密码:   $pass"
}

gw_action_uninstall() {
  local DOMAIN ok
  prompt DOMAIN "要卸载的网关域名（只填域名）"
  DOMAIN="$(strip_scheme "$DOMAIN")"
  local conf enabled
  conf="$(gw_conf_path_for_domain "$DOMAIN")"
  enabled="$(gw_enabled_path_for_domain "$DOMAIN")"

  echo "将删除："
  echo "  $conf"
  echo "  $enabled"
  echo "  $GW_MAP_CONF"
  echo "  $GW_SNIP_CONF"
  echo "  $GW_HTPASSWD"
  echo
  yesno ok "确认卸载" "n"
  [[ "$ok" == "y" ]] || { echo "已取消"; return 0; }

  ensure_deps
  ensure_sites_enabled_include
  nginx_self_heal_compat

  local backup dump
  backup="$(backup_nginx)"
  dump="$(mktemp)"
  trap 'rm -f "$dump"' RETURN

  rm -f "$enabled" "$conf" "$GW_MAP_CONF" "$GW_SNIP_CONF" "$GW_HTPASSWD" 2>/dev/null || true
  apply_with_rollback "$backup" "$dump" || true

  echo "✅ 已卸载网关。备份目录：$backup"
  echo "如需删除证书请手动执行：certbot delete --cert-name $DOMAIN"
}

gw_menu() {
  IFS="|" read -r OS_NAME OS_VER OS_CODE < <(os_info)
  echo
  echo "=== 通用反代网关 ==="
  echo "系统：${OS_NAME} / ${OS_VER} / ${OS_CODE}"
  echo "提示：强烈建议开启 BasicAuth 或 IP 白名单，避免 OPEN PROXY。"
  echo
  while true; do
    echo "========== 网关菜单 =========="
    echo "1) 安装/更新 通用反代网关"
    echo "2) 查看状态"
    echo "3) 修改 BasicAuth 账号/密码"
    echo "4) 卸载"
    echo "5) 前后端分离向导（后端地址重写）"
    echo "0) 返回上级"
    echo "=============================="
    read -r -p "请选择: " c
    case "$c" in
      1) gw_action_install_update ;;
      2) gw_action_status ;;
      3) gw_action_change_auth ;;
      4) gw_action_uninstall ;;
      5) frontsplit_guide ;;
      0) return 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

main_menu() {
  IFS="|" read -r OS_NAME OS_VER OS_CODE < <(os_info)
  echo "=== ${TOOL_NAME}（一体化 Emby 反代工具箱）==="
  echo "系统识别：${OS_NAME} / ${OS_VER} / ${OS_CODE}"
  echo
  while true; do
    echo "========== 主菜单 =========="
    echo "1) 单站反代管理器（逐个域名配置）"
    echo "2) 通用反代网关（一个入口反代多个上游）"
    echo "3) 前后端分离向导（通用网关：后端地址重写）"
    echo "0) 退出"
    echo "============================"
    read -r -p "请选择: " c
    case "$c" in
      1) single_menu ;;
      2) gw_menu ;;
      3) frontsplit_guide ;;
      0) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

need_root
main_menu
