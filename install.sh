#!/usr/bin/env bash

# =============================================================================
# HEADSCALE + HEADPLANE - INSTALADOR INTERACTIVO
# =============================================================================
# Instalador todo-en-uno para Headscale (control plane) + Headplane (Web UI)
# Uso: ./install.sh
#
# Características:
# - Detección y validación de dependencias
# - Configuración interactiva con valores por defecto sensatos
# - Generación automática de secretos
# - Soporte para SSL (Let's Encrypt o certificado autofirmado)
# - Integración OIDC opcional
# - Idempotente: puede ejecutarse múltiples veces para reconfigurar
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# VARIABLES GLOBALES
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
DATA_DIR="${SCRIPT_DIR}/data"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# -----------------------------------------------------------------------------
# FUNCIONES DE UTILIDAD
# -----------------------------------------------------------------------------

# Imprimir mensajes con color
print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Preguntar sí/no con valor por defecto
ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    if [[ "$default" == "y" ]]; then
        prompt="$prompt [S/n]"
    else
        prompt="$prompt [s/N]"
    fi

    while true; do
        read -p "$(echo -e "${CYAN}?${NC} $prompt: ")" response
        response="${response:-$default}"
        response=$(echo "$response" | tr '[:upper:]' '[:lower:]')

        case "$response" in
            y|s|yes|si|sí)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                print_warning "Por favor responde 's' (sí) o 'n' (no)"
                ;;
        esac
    done
}

# Preguntar input con valor por defecto y validación opcional
ask_input() {
    local prompt="$1"
    local default="$2"
    local validate_func="${3:-}"
    local value

    if [[ -n "$default" ]]; then
        prompt="$prompt [${default}]"
    fi

    while true; do
        read -p "$(echo -e "${CYAN}?${NC} $prompt: ")" value
        value="${value:-$default}"

        # Si hay función de validación, usarla
        if [[ -n "$validate_func" ]] && type "$validate_func" &>/dev/null; then
            if $validate_func "$value"; then
                echo "$value"
                return 0
            else
                print_warning "Valor inválido, intenta de nuevo"
                continue
            fi
        fi

        # Si no está vacío, aceptar
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        else
            print_warning "Este campo no puede estar vacío"
        fi
    done
}

# Validar dominio o IP
validate_domain_or_ip() {
    local input="$1"

    # Validar IP (simplificado)
    if [[ "$input" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi

    # Validar dominio (simplificado)
    if [[ "$input" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi

    # Validar localhost
    if [[ "$input" == "localhost" ]]; then
        return 0
    fi

    return 1
}

# Validar puerto
validate_port() {
    local port="$1"

    if [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    fi

    return 1
}

# Validar email
validate_email() {
    local email="$1"

    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi

    return 1
}

# Validar nombre alfanumérico
validate_alphanumeric() {
    local name="$1"

    if [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 0
    fi

    return 1
}

# Validar URL
validate_url() {
    local url="$1"

    if [[ "$url" =~ ^https?:// ]]; then
        return 0
    fi

    return 1
}

# Generar secreto aleatorio
generate_secret() {
    local length="${1:-64}"
    openssl rand -hex "$length" 2>/dev/null || \
        head -c "$length" /dev/urandom | xxd -p | tr -d '\n'
}

# -----------------------------------------------------------------------------
# FUNCIONES DE VERIFICACIÓN DE DEPENDENCIAS
# -----------------------------------------------------------------------------

check_command() {
    command -v "$1" &>/dev/null
}

install_docker() {
    print_info "Intentando instalar Docker..."

    # Detectar distribución
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        print_error "No se pudo detectar la distribución del sistema"
        return 1
    fi

    case "$OS" in
        ubuntu|debian)
            print_info "Instalando Docker en Debian/Ubuntu..."
            sudo apt-get update
            sudo apt-get install -y ca-certificates curl gnupg
            sudo install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$OS/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg
            echo \
              "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
              $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
              sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        fedora|rhel|centos)
            print_info "Instalando Docker en Fedora/RHEL/CentOS..."
            sudo dnf -y install dnf-plugins-core
            sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        arch)
            print_info "Instalando Docker en Arch Linux..."
            sudo pacman -Sy --noconfirm docker docker-compose
            sudo systemctl start docker
            sudo systemctl enable docker
            ;;
        *)
            print_error "Distribución no soportada para instalación automática: $OS"
            print_info "Por favor instala Docker manualmente: https://docs.docker.com/engine/install/"
            return 1
            ;;
    esac

    # Agregar usuario actual al grupo docker
    if ! groups | grep -q docker; then
        print_info "Agregando usuario actual al grupo docker..."
        sudo usermod -aG docker "$USER"
        print_warning "Debes cerrar sesión y volver a entrar para que el cambio de grupo surta efecto"
        print_warning "O ejecuta: newgrp docker"
    fi

    print_success "Docker instalado correctamente"
    return 0
}

check_dependencies() {
    print_header "VERIFICACIÓN DE DEPENDENCIAS"

    local missing_deps=()

    # Verificar Docker
    if ! check_command docker; then
        print_warning "Docker no está instalado"
        if ask_yes_no "¿Deseas instalar Docker automáticamente?" "y"; then
            if ! install_docker; then
                missing_deps+=("docker")
            fi
        else
            missing_deps+=("docker")
        fi
    else
        print_success "Docker está instalado"

        # Verificar que Docker daemon esté corriendo
        if ! docker info &>/dev/null; then
            print_warning "Docker daemon no está corriendo"
            print_info "Intentando iniciar Docker..."
            sudo systemctl start docker 2>/dev/null || sudo service docker start 2>/dev/null || {
                print_error "No se pudo iniciar Docker daemon. Inícialo manualmente."
                missing_deps+=("docker-daemon")
            }
        fi
    fi

    # Verificar Docker Compose (plugin)
    if ! docker compose version &>/dev/null; then
        print_warning "Docker Compose plugin no está instalado"
        missing_deps+=("docker-compose")
    else
        print_success "Docker Compose plugin está instalado"
    fi

    # Verificar openssl (para generar secretos)
    if ! check_command openssl; then
        print_warning "OpenSSL no está instalado (necesario para generar secretos)"
        missing_deps+=("openssl")
    fi

    # Si hay dependencias faltantes, salir
    if [ ${#missing_deps[@]} -gt 0 ]; then
        print_error "Faltan las siguientes dependencias: ${missing_deps[*]}"
        print_info "Por favor instálalas manualmente y vuelve a ejecutar el instalador"
        exit 1
    fi

    print_success "Todas las dependencias están instaladas"
}

# -----------------------------------------------------------------------------
# FUNCIONES DE CONFIGURACIÓN
# -----------------------------------------------------------------------------

load_existing_config() {
    if [ -f "$ENV_FILE" ]; then
        print_info "Encontrado archivo de configuración existente"
        if ask_yes_no "¿Deseas cargar la configuración existente?" "y"; then
            # Cargar variables existentes
            set -a
            source "$ENV_FILE"
            set +a
            return 0
        fi
    fi
    return 1
}

configure_network() {
    print_header "CONFIGURACIÓN DE RED Y ACCESO"

    # Dominio o IP
    print_info "Ingresa el dominio o IP pública/privada para acceder al servicio"
    print_info "Ejemplos: vpn.midominio.com, 192.168.1.100, 10.0.0.5"
    DOMAIN=$(ask_input "Dominio o IP" "${DOMAIN:-vpn.example.com}" "validate_domain_or_ip")

    # SSL
    if ask_yes_no "¿Deseas habilitar SSL/TLS (HTTPS)?" "${ENABLE_SSL:-y}"; then
        ENABLE_SSL="true"

        # Verificar si es un dominio válido (no IP) para Let's Encrypt
        if [[ "$DOMAIN" =~ ^[0-9.]+$ ]] || [[ "$DOMAIN" == "localhost" ]]; then
            print_warning "Has ingresado una IP o localhost"
            print_warning "Let's Encrypt requiere un dominio válido con DNS público"
            SSL_MODE="selfsigned"
            print_info "Se usará un certificado autofirmado"
        else
            if ask_yes_no "¿Tienes un dominio válido con DNS apuntando a este servidor?" "y"; then
                SSL_MODE="letsencrypt"
                print_info "Se usará Let's Encrypt para certificado automático"

                # Pedir email para Let's Encrypt
                print_info "Let's Encrypt requiere un email para notificaciones de renovación"
                ACME_EMAIL=$(ask_input "Email para Let's Encrypt" "${ACME_EMAIL:-admin@${DOMAIN}}" "validate_email")
            else
                SSL_MODE="selfsigned"
                print_info "Se usará un certificado autofirmado"
            fi
        fi

        URL_SCHEME="https"
    else
        ENABLE_SSL="false"
        SSL_MODE="none"
        URL_SCHEME="http"

        print_warning "ADVERTENCIA: El servicio se expondrá sin cifrado (HTTP plano)"
        print_warning "Esto NO es recomendable para entornos de producción expuestos a internet"
    fi

    print_success "Configuración de red completada"
}

configure_ports() {
    print_header "CONFIGURACIÓN DE PUERTOS"

    print_info "Puertos por defecto recomendados. Presiona Enter para usar los valores por defecto."

    if [[ "$ENABLE_SSL" == "true" ]]; then
        HTTP_PORT=$(ask_input "Puerto HTTP (para redirección a HTTPS)" "${HTTP_PORT:-80}" "validate_port")
        HTTPS_PORT=$(ask_input "Puerto HTTPS" "${HTTPS_PORT:-443}" "validate_port")
        HEADPLANE_PORT="3000"  # Interno, no expuesto
    else
        HEADPLANE_PORT=$(ask_input "Puerto web de Headplane" "${HEADPLANE_PORT:-3000}" "validate_port")
        HTTP_PORT="80"
        HTTPS_PORT="443"
    fi

    HEADSCALE_GRPC_PORT=$(ask_input "Puerto gRPC de Headscale (interno)" "${HEADSCALE_GRPC_PORT:-50443}" "validate_port")
    HEADSCALE_HTTP_PORT=$(ask_input "Puerto HTTP API de Headscale (interno)" "${HEADSCALE_HTTP_PORT:-8080}" "validate_port")
    HEADSCALE_DERP_PORT=$(ask_input "Puerto DERP/STUN de Headscale (UDP, debe ser accesible)" "${HEADSCALE_DERP_PORT:-3478}" "validate_port")
    HEADSCALE_METRICS_PORT=$(ask_input "Puerto Metrics de Headscale (interno)" "${HEADSCALE_METRICS_PORT:-9090}" "validate_port")

    print_success "Configuración de puertos completada"
}

compute_public_urls() {
    # Las URLs públicas dependen del dominio Y de los puertos, por lo que sólo
    # pueden calcularse después de configure_ports.
    #
    # Con proxy (SSL): Caddy sirve ambos servicios en el mismo dominio y puerto
    #   estándar; el enrutado se hace por ruta (/admin -> Headplane, resto ->
    #   Headscale). Ninguna URL lleva puerto.
    #
    # Sin proxy: cada servicio se expone en su propio puerto del host, por lo
    #   que las URLs son distintas y DEBEN incluirlo.
    if [[ "$ENABLE_SSL" == "true" ]]; then
        local suffix=""
        [[ "$HTTPS_PORT" != "443" ]] && suffix=":${HTTPS_PORT}"
        HEADSCALE_PUBLIC_URL="${URL_SCHEME}://${DOMAIN}${suffix}"
        HEADPLANE_PUBLIC_URL="${URL_SCHEME}://${DOMAIN}${suffix}"
    else
        HEADSCALE_PUBLIC_URL="${URL_SCHEME}://${DOMAIN}:${HEADSCALE_HTTP_PORT}"
        HEADPLANE_PUBLIC_URL="${URL_SCHEME}://${DOMAIN}:${HEADPLANE_PORT}"
    fi

    # SERVER_URL = URL del control plane; es la que usan los clientes Tailscale
    SERVER_URL="$HEADSCALE_PUBLIC_URL"

    print_info "URL del control plane (Headscale): ${HEADSCALE_PUBLIC_URL}"
    print_info "URL de la interfaz web (Headplane): ${HEADPLANE_PUBLIC_URL}/admin"
}

configure_tailnet() {
    print_header "CONFIGURACIÓN DE LA RED TAILNET"

    print_info "Configura los parámetros de tu red privada virtual (Tailnet)"

    TAILNET_NAME=$(ask_input "Nombre de la organización/tailnet (alfanumérico, sin espacios)" \
                             "${TAILNET_NAME:-myorg}" "validate_alphanumeric")

    ADMIN_USER=$(ask_input "Nombre del usuario administrador inicial" \
                           "${ADMIN_USER:-admin}" "validate_alphanumeric")

    IP_PREFIXES_V4=$(ask_input "Rango IPv4 para clientes (CIDR)" "${IP_PREFIXES_V4:-100.64.0.0/10}")
    IP_PREFIXES_V6=$(ask_input "Rango IPv6 para clientes (CIDR)" "${IP_PREFIXES_V6:-fd7a:115c:a1e0::/48}")

    DATA_DIR=$(ask_input "Ruta de persistencia de datos" "${DATA_DIR:-./data}")

    LOG_LEVEL=$(ask_input "Nivel de log (trace/debug/info/warn/error)" "${LOG_LEVEL:-info}")

    print_success "Configuración de Tailnet completada"
}

configure_oidc() {
    print_header "CONFIGURACIÓN DE AUTENTICACIÓN OIDC (OPCIONAL)"

    print_info "Puedes integrar un proveedor OIDC (Keycloak, Authentik, etc.)"
    print_info "Si no lo configuras, Headplane usará autenticación local (usuario/contraseña)"

    if ask_yes_no "¿Deseas configurar autenticación OIDC?" "${ENABLE_OIDC:-n}"; then
        ENABLE_OIDC="true"

        print_info "Ejemplos de Issuer URL:"
        print_info "  - Keycloak: https://auth.example.com/realms/master"
        print_info "  - Authentik: https://auth.example.com/application/o/headplane/"

        OIDC_ISSUER_URL=$(ask_input "Issuer URL del proveedor OIDC" "${OIDC_ISSUER_URL:-}" "validate_url")
        OIDC_CLIENT_ID=$(ask_input "Client ID" "${OIDC_CLIENT_ID:-headplane}")
        OIDC_CLIENT_SECRET=$(ask_input "Client Secret" "${OIDC_CLIENT_SECRET:-}")
        OIDC_SCOPE=$(ask_input "Scopes OIDC (separados por espacios)" "${OIDC_SCOPE:-openid profile email}")
        OIDC_EMAIL_CLAIM=$(ask_input "Claim del email" "${OIDC_EMAIL_CLAIM:-email}")
    else
        ENABLE_OIDC="false"
        OIDC_ISSUER_URL=""
        OIDC_CLIENT_ID=""
        OIDC_CLIENT_SECRET=""
        OIDC_SCOPE="openid profile email"
        OIDC_EMAIL_CLAIM="email"
    fi

    print_success "Configuración de OIDC completada"
}

generate_secrets() {
    print_header "GENERACIÓN DE SECRETOS"

    # Generar COOKIE_SECRET si no existe (exactamente 32 caracteres)
    if [ -z "${COOKIE_SECRET:-}" ]; then
        print_info "Generando COOKIE_SECRET..."
        COOKIE_SECRET=$(generate_secret 16)  # 16 bytes = 32 caracteres hex
        print_success "COOKIE_SECRET generado"
    else
        print_info "COOKIE_SECRET existente detectado, reutilizando"
    fi
}

# -----------------------------------------------------------------------------
# FUNCIONES DE GENERACIÓN DE ARCHIVOS
# -----------------------------------------------------------------------------

generate_env_file() {
    print_header "GENERANDO ARCHIVO .env"

    # Variables derivadas: deben existir como variables de shell (no solo en el
    # heredoc) porque las plantillas se rellenan con envsubst más adelante.
    AUTH_TYPE=$([[ "$ENABLE_OIDC" == "true" ]] && echo "oidc" || echo "local")
    SESSION_SECURE=$([[ "$ENABLE_SSL" == "true" ]] && echo "true" || echo "false")

    cat > "$ENV_FILE" <<EOF
# =============================================================================
# CONFIGURACIÓN HEADSCALE + HEADPLANE
# =============================================================================
# Generado por install.sh el $(date)
# Para reconfigurar: ejecuta ./install.sh

# -----------------------------------------------------------------------------
# RED Y ACCESO
# -----------------------------------------------------------------------------
DOMAIN=${DOMAIN}
URL_SCHEME=${URL_SCHEME}

# URL del control plane: la que usan los clientes con --login-server
SERVER_URL=${SERVER_URL}
HEADSCALE_PUBLIC_URL=${HEADSCALE_PUBLIC_URL}

# URL pública de la interfaz web (la UI se sirve bajo /admin)
HEADPLANE_PUBLIC_URL=${HEADPLANE_PUBLIC_URL}

ENABLE_SSL=${ENABLE_SSL}
SSL_MODE=${SSL_MODE}
ACME_EMAIL=${ACME_EMAIL:-}

# -----------------------------------------------------------------------------
# PUERTOS
# -----------------------------------------------------------------------------
HTTP_PORT=${HTTP_PORT}
HTTPS_PORT=${HTTPS_PORT}
HEADPLANE_PORT=${HEADPLANE_PORT}
HEADSCALE_GRPC_PORT=${HEADSCALE_GRPC_PORT}
HEADSCALE_HTTP_PORT=${HEADSCALE_HTTP_PORT}
HEADSCALE_DERP_PORT=${HEADSCALE_DERP_PORT}
HEADSCALE_METRICS_PORT=${HEADSCALE_METRICS_PORT}

# -----------------------------------------------------------------------------
# TAILNET
# -----------------------------------------------------------------------------
TAILNET_NAME=${TAILNET_NAME}

# Usuario administrador creado automáticamente al desplegar
ADMIN_USER=${ADMIN_USER}

# Caducidad de la API key generada automáticamente (ej: 90d, 365d)
APIKEY_EXPIRATION=${APIKEY_EXPIRATION:-90d}

# API key de Headscale: credencial de acceso a Headplane. La rellena el
# instalador tras arrancar Headscale. NO compartir ni versionar.
HEADSCALE_API_KEY=${HEADSCALE_API_KEY:-}

IP_PREFIXES_V4=${IP_PREFIXES_V4}
IP_PREFIXES_V6=${IP_PREFIXES_V6}
DATA_DIR=${DATA_DIR}
LOG_LEVEL=${LOG_LEVEL}

# -----------------------------------------------------------------------------
# HEADPLANE
# -----------------------------------------------------------------------------
COOKIE_SECRET=${COOKIE_SECRET}
INTEGRATION_MODE=integrated

# -----------------------------------------------------------------------------
# OIDC
# -----------------------------------------------------------------------------
ENABLE_OIDC=${ENABLE_OIDC}
OIDC_ISSUER_URL="${OIDC_ISSUER_URL}"
OIDC_CLIENT_ID="${OIDC_CLIENT_ID}"
OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET}"
OIDC_SCOPE="${OIDC_SCOPE}"
OIDC_EMAIL_CLAIM="${OIDC_EMAIL_CLAIM}"

# Auth type (generado automáticamente)
AUTH_TYPE=${AUTH_TYPE}

# Session secure (generado automáticamente)
SESSION_SECURE=${SESSION_SECURE}

# -----------------------------------------------------------------------------
# AVANZADO
# -----------------------------------------------------------------------------
TZ=${TZ:-UTC}
NETWORK_NAME=headscale-net
HEADSCALE_IMAGE_TAG=latest
HEADPLANE_IMAGE_TAG=latest
CADDY_IMAGE_TAG=2-alpine
EOF

    print_success "Archivo .env generado: $ENV_FILE"
}

generate_headscale_config() {
    print_header "GENERANDO CONFIGURACIÓN DE HEADSCALE"

    # Configurar OIDC si está habilitado
    if [[ "$ENABLE_OIDC" == "true" ]]; then
        # OIDC_SCOPE es una lista separada por espacios ("openid profile email");
        # Headscale la espera como lista YAML, un elemento por scope.
        local scope_list=""
        local s
        for s in $OIDC_SCOPE; do
            scope_list+="    - ${s}"$'\n'
        done

        # Heredoc SIN comillas: las variables deben expandirse aquí. envsubst
        # hace una sola pasada y no volvería a sustituir el texto insertado.
        OIDC_CONFIG=$(cat <<EOFC
oidc:
  only_start_if_oidc_is_available: true
  issuer: "${OIDC_ISSUER_URL}"
  client_id: "${OIDC_CLIENT_ID}"
  client_secret: "${OIDC_CLIENT_SECRET}"
  scope:
${scope_list%$'\n'}
  strip_email_domain: true
EOFC
        )
    else
        OIDC_CONFIG="# OIDC deshabilitado"
    fi

    # Cargar plantilla y sustituir variables
    export SERVER_URL HEADSCALE_HTTP_PORT HEADSCALE_METRICS_PORT HEADSCALE_GRPC_PORT \
           IP_PREFIXES_V4 IP_PREFIXES_V6 TAILNET_NAME HEADSCALE_DERP_PORT LOG_LEVEL \
           OIDC_CONFIG OIDC_ISSUER_URL OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_SCOPE

    envsubst < "$TEMPLATES_DIR/headscale-config.yaml.tmpl" > "$SCRIPT_DIR/headscale-config.yaml"

    print_success "Configuración de Headscale generada: headscale-config.yaml"
}

generate_headplane_config() {
    print_header "GENERANDO CONFIGURACIÓN DE HEADPLANE"

    # Generar bloque OIDC si está habilitado
    if [[ "$ENABLE_OIDC" == "true" ]]; then
        OIDC_CONFIG_BLOCK=$(cat <<EOFC
oidc:
  enabled: true
  issuer: "${OIDC_ISSUER_URL}"
  client_id: "${OIDC_CLIENT_ID}"
  client_secret: "${OIDC_CLIENT_SECRET}"
  scope: "${OIDC_SCOPE}"
  use_pkce: true
  disable_api_key_login: false
  profile_picture_source: "gravatar"
  default_role: "member"
EOFC
        )
    else
        OIDC_CONFIG_BLOCK="# OIDC disabled"
    fi

    # Headplane exige un booleano estricto; nunca dejar el valor vacío
    SESSION_SECURE=$([[ "$ENABLE_SSL" == "true" ]] && echo "true" || echo "false")

    # La API key sólo existe tras arrancar Headscale. En la primera pasada se
    # omite la clave; bootstrap_headscale regenera este fichero con ella.
    if [[ -n "${HEADSCALE_API_KEY:-}" ]]; then
        HEADSCALE_API_KEY_LINE="api_key: \"${HEADSCALE_API_KEY}\""
    else
        HEADSCALE_API_KEY_LINE="# api_key: pendiente de generar"
    fi

    # Cargar plantilla y sustituir variables
    # Exportar todas las variables necesarias
    export COOKIE_SECRET
    export SESSION_SECURE
    export HEADPLANE_PUBLIC_URL
    export HEADSCALE_PUBLIC_URL
    export HEADSCALE_HTTP_PORT
    export HEADSCALE_API_KEY_LINE
    export OIDC_CONFIG_BLOCK

    # Usar envsubst sin lista de variables para que sustituya todas
    envsubst < "$TEMPLATES_DIR/headplane-config.yaml.tmpl" > "$SCRIPT_DIR/headplane-config.yaml"

    # Verificar que no ha quedado ningún campo obligatorio sin sustituir
    if grep -qE '^\s*(cookie_secure|cookie_secret|base_url|public_url|url):\s*("")?\s*$' "$SCRIPT_DIR/headplane-config.yaml"; then
        print_error "headplane-config.yaml tiene campos obligatorios vacíos tras la sustitución"
        grep -nE '^\s*(cookie_secure|cookie_secret|base_url|public_url|url):\s*("")?\s*$' "$SCRIPT_DIR/headplane-config.yaml"
        exit 1
    fi

    print_success "Configuración de Headplane generada: headplane-config.yaml"
}

generate_caddyfile() {
    if [[ "$ENABLE_SSL" != "true" ]]; then
        print_info "SSL deshabilitado, no se genera Caddyfile"
        return 0
    fi

    print_header "GENERANDO CADDYFILE"

    # Configurar dominio y TLS según el modo
    if [[ "$SSL_MODE" == "letsencrypt" ]]; then
        CADDY_DOMAIN="$DOMAIN"
        CADDY_TLS="tls ${ACME_EMAIL}"
        CADDY_HSTS="Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\""
    else
        CADDY_DOMAIN="$DOMAIN"
        CADDY_TLS="tls internal"
        CADDY_HSTS="# HSTS deshabilitado (certificado autofirmado)"
    fi

    # Redirección HTTP a HTTPS
    HTTP_REDIRECT=$(cat <<EOF
http://${DOMAIN} {
    redir https://{host}{uri} permanent
}
EOF
    )

    # Cargar plantilla y sustituir variables
    export CADDY_DOMAIN CADDY_TLS CADDY_HSTS HEADSCALE_HTTP_PORT HTTP_REDIRECT

    envsubst < "$TEMPLATES_DIR/Caddyfile.tmpl" > "$SCRIPT_DIR/Caddyfile"

    print_success "Caddyfile generado: Caddyfile"
}

generate_compose_override() {
    # Si SSL está habilitado, no necesitamos override (Caddy maneja todo)
    if [[ "$ENABLE_SSL" == "true" ]]; then
        # Eliminar override si existe
        rm -f "$SCRIPT_DIR/docker-compose.override.yml"
        return 0
    fi

    print_header "GENERANDO DOCKER COMPOSE OVERRIDE"

    print_info "Generando docker-compose.override.yml para exponer puertos sin SSL..."

    cat > "$SCRIPT_DIR/docker-compose.override.yml" <<'EOF'
# Docker Compose Override - Generado automáticamente por install.sh
# Este archivo se usa cuando ENABLE_SSL=false para exponer puertos directamente

services:
  headscale:
    ports:
      # Puerto HTTP API - expuesto directamente (sin proxy)
      - "${HEADSCALE_HTTP_PORT:-8080}:8080"

  headplane:
    ports:
      # Puerto web - expuesto directamente (sin proxy)
      - "${HEADPLANE_PORT:-3000}:3000"
EOF

    print_success "docker-compose.override.yml generado"
}

create_data_dirs() {
    print_header "CREANDO DIRECTORIOS DE DATOS"

    mkdir -p "$DATA_DIR"
    mkdir -p "$DATA_DIR/caddy-logs"

    print_success "Directorios de datos creados en: $DATA_DIR"
}

# -----------------------------------------------------------------------------
# FUNCIONES DE DESPLIEGUE
# -----------------------------------------------------------------------------

start_headscale_first() {
    # Headscale debe estar arriba ANTES que Headplane: la API key que Headplane
    # necesita sólo puede emitirla un Headscale en marcha.
    print_header "ARRANCANDO HEADSCALE"

    print_info "Descargando imágenes de Docker..."
    local compose_args=""
    [[ "$ENABLE_SSL" == "true" ]] && compose_args="--profile ssl"
    docker compose $compose_args pull

    print_info "Levantando Headscale..."
    docker compose up -d headscale

    print_info "Esperando a que Headscale esté saludable..."
    local waited=0
    while [ $waited -lt 90 ]; do
        local state
        state=$(docker inspect -f '{{.State.Health.Status}}' headscale 2>/dev/null || echo "starting")
        if [[ "$state" == "healthy" ]]; then
            echo ""
            print_success "Headscale está listo"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
        echo -n "."
    done

    echo ""
    print_error "Headscale no llegó a estado saludable tras 90s"
    print_info "Revisa los logs con: docker compose logs headscale"
    exit 1
}

bootstrap_headscale() {
    print_header "CREANDO USUARIO ADMINISTRADOR Y API KEY"

    # --- Usuario administrador (idempotente) ---
    # 'users create' falla con UNIQUE constraint si ya existe, así que se
    # comprueba antes para que reejecutar el instalador no aborte.
    if docker exec headscale headscale users list --output json 2>/dev/null \
        | grep -q "\"name\": *\"${ADMIN_USER}\""; then
        print_info "El usuario '${ADMIN_USER}' ya existe, se conserva"
    else
        if docker exec headscale headscale users create "${ADMIN_USER}" >/dev/null 2>&1; then
            print_success "Usuario administrador creado: ${ADMIN_USER}"
        else
            print_error "No se pudo crear el usuario '${ADMIN_USER}'"
            docker exec headscale headscale users create "${ADMIN_USER}" || true
            exit 1
        fi
    fi

    # Headscale 0.29 exige el ID numérico en 'preauthkeys create --user',
    # no el nombre, así que hay que resolverlo para poder mostrar el comando.
    ADMIN_USER_ID=$(docker exec headscale headscale users list --output json 2>/dev/null \
                    | tr -d ' \t\n' \
                    | grep -oE "\"id\":[0-9]+,\"name\":\"${ADMIN_USER}\"" \
                    | grep -oE '[0-9]+' | head -1)
    [[ -z "$ADMIN_USER_ID" ]] && ADMIN_USER_ID="<id>"

    # --- API key ---
    # Headscale sólo devuelve el valor completo al crearla; después almacena
    # únicamente el prefijo. Si conservamos una en .env y sigue vigente, se
    # reutiliza para que reconfigurar no acumule claves huérfanas.
    if [[ -n "${HEADSCALE_API_KEY:-}" ]]; then
        local prefix expires now
        prefix=$(printf '%s' "$HEADSCALE_API_KEY" | cut -d- -f1-3)

        # Headscale lista el prefijo enmascarado ("hskey-api-XXXX-***"), por lo
        # que hay que buscar el prefijo como subcadena, no como valor exacto.
        expires=$(docker exec headscale headscale apikeys list --output json 2>/dev/null \
                  | tr -d ' \t\n' \
                  | grep -oE "\"prefix\":\"${prefix}[^\"]*\",\"expiration\":\{\"seconds\":[0-9]+" \
                  | grep -oE '[0-9]+$' || true)
        now=$(date +%s)

        if [[ -n "$expires" ]] && [[ "$expires" -gt "$now" ]]; then
            print_info "Reutilizando la API key existente de .env"
            return 0
        elif [[ -n "$expires" ]]; then
            print_warning "La API key guardada en .env ha caducado, se generará otra"
        else
            print_warning "La API key guardada en .env ya no existe, se generará otra"
        fi
    fi

    HEADSCALE_API_KEY=$(docker exec headscale headscale apikeys create \
                        --expiration "${APIKEY_EXPIRATION:-90d}" 2>/dev/null | tr -d '\r\n')

    if [[ ! "$HEADSCALE_API_KEY" =~ ^hskey- ]]; then
        print_error "La API key generada no tiene el formato esperado"
        print_info "Genérala manualmente con: docker exec headscale headscale apikeys create"
        HEADSCALE_API_KEY=""
        return 0
    fi

    # Persistir en .env (único fichero con secretos, ya excluido por .gitignore)
    if grep -q '^HEADSCALE_API_KEY=' "$ENV_FILE"; then
        sed -i "s|^HEADSCALE_API_KEY=.*|HEADSCALE_API_KEY=${HEADSCALE_API_KEY}|" "$ENV_FILE"
    else
        printf '\n# API key de Headscale (generada automáticamente, NO compartir)\nHEADSCALE_API_KEY=%s\n' \
            "$HEADSCALE_API_KEY" >> "$ENV_FILE"
    fi

    print_success "API key generada (válida ${APIKEY_EXPIRATION:-90d}) y guardada en .env"
}

deploy_stack() {
    print_header "DESPLEGANDO STACK CON DOCKER COMPOSE"

    # Determinar profile a usar
    local compose_args=""
    if [[ "$ENABLE_SSL" == "true" ]]; then
        compose_args="--profile ssl"
        print_info "Activando profile SSL..."
    fi

    # Levantar servicios
    print_info "Levantando servicios..."
    docker compose $compose_args up -d

    # Esperar a que los servicios estén saludables
    print_info "Esperando a que los servicios estén listos..."
    local max_wait=60
    local waited=0

    while [ $waited -lt $max_wait ]; do
        if docker compose ps | grep -q "healthy"; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
        echo -n "."
    done
    echo ""

    if [ $waited -ge $max_wait ]; then
        print_warning "Los servicios están tardando más de lo esperado en iniciar"
        print_info "Verifica el estado con: docker compose ps"
        print_info "Verifica los logs con: docker compose logs -f"
    else
        print_success "Servicios desplegados correctamente"
    fi
}

show_access_info() {
    print_header "¡INSTALACIÓN COMPLETADA!"

    echo ""
    echo -e "${GREEN}${BOLD}✓ Headscale + Headplane están corriendo${NC}"
    echo ""

    # URLs de acceso
    echo -e "${CYAN}Interfaz web (Headplane):${NC} ${BOLD}${HEADPLANE_PUBLIC_URL}/admin${NC}"
    echo -e "${CYAN}Control plane (Headscale):${NC} ${BOLD}${HEADSCALE_PUBLIC_URL}${NC}"
    echo ""

    if [[ "$ENABLE_SSL" == "true" ]]; then
        if [[ "$SSL_MODE" == "selfsigned" ]]; then
            print_warning "Estás usando un certificado autofirmado"
            print_warning "Tu navegador mostrará una advertencia de seguridad"
            print_warning "Esto es normal, puedes proceder de forma segura en una red privada"
            echo ""
        fi
    else
        print_warning "El servicio está usando HTTP sin cifrado"
        echo ""
    fi

    # --- API key: único método de acceso a la UI sin OIDC ---
    if [[ -n "${HEADSCALE_API_KEY:-}" ]]; then
        echo -e "${YELLOW}${BOLD}┌─────────────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}${BOLD}│  API KEY PARA INICIAR SESIÓN EN HEADPLANE                               │${NC}"
        echo -e "${YELLOW}${BOLD}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  ${BOLD}${HEADSCALE_API_KEY}${NC}"
        echo ""
        print_warning "GUÁRDALA AHORA: Headscale sólo la muestra en el momento de crearla."
        print_warning "Da control total sobre tu tailnet. Trátala como una contraseña."
        echo ""
        echo -e "  Si la pierdes, genera otra con:"
        echo -e "  ${YELLOW}docker exec headscale headscale apikeys create --expiration 90d${NC}"
        echo ""
    else
        print_warning "No se generó ninguna API key en esta ejecución"
        echo -e "  Para entrar en Headplane necesitas una:"
        echo -e "  ${YELLOW}docker exec headscale headscale apikeys create --expiration 90d${NC}"
        echo ""
    fi

    echo -e "${CYAN}${BOLD}Próximos pasos:${NC}"
    echo ""
    echo -e "1. Entra en ${BOLD}${HEADPLANE_PUBLIC_URL}/admin${NC} y pega la API key de arriba"
    echo -e "   ${YELLOW}(la UI vive bajo /admin; la raíz / devuelve 404)${NC}"
    echo ""
    echo "2. Generar una clave de pre-autenticación para conectar dispositivos:"
    echo -e "   ${YELLOW}docker exec headscale headscale preauthkeys create --user ${ADMIN_USER_ID} --reusable --expiration 24h${NC}"
    echo -e "   ${YELLOW}(--user espera el ID numérico del usuario, no su nombre)${NC}"
    echo ""
    echo "3. Conectar un dispositivo con Tailscale:"
    echo -e "   ${YELLOW}tailscale up --login-server=${HEADSCALE_PUBLIC_URL} --authkey=<clave-del-paso-2>${NC}"
    echo ""
    print_warning "No confundas las tres claves de este stack:"
    echo -e "   • ${BOLD}API key${NC} (hskey-api-...)      -> iniciar sesión en la UI de Headplane"
    echo -e "   • ${BOLD}Pre-auth key${NC} (hskey-auth-...) -> registrar dispositivos con --authkey"
    echo -e "   • ${BOLD}Auth ID${NC} (hskey-authreq-...)   -> lo imprime 'tailscale up' sin --authkey,"
    echo -e "     y es lo único que acepta el diálogo \"Register Machine Key\" de Headplane"
    echo ""

    echo -e "${CYAN}${BOLD}Comandos útiles:${NC}"
    echo ""
    echo "• Ver estado de los servicios:"
    echo -e "  ${YELLOW}docker compose ps${NC}"
    echo ""
    echo "• Ver logs:"
    echo -e "  ${YELLOW}docker compose logs -f${NC}"
    echo ""
    echo "• Reiniciar servicios:"
    echo -e "  ${YELLOW}docker compose restart${NC}"
    echo ""
    echo "• Detener servicios:"
    echo -e "  ${YELLOW}docker compose down${NC}"
    echo ""
    echo "• Reconfigurar:"
    echo -e "  ${YELLOW}./install.sh${NC}"
    echo ""

    echo -e "${CYAN}${BOLD}Archivos generados:${NC}"
    echo ""
    echo "• Configuración: .env"
    echo "• Config Headscale: headscale-config.yaml"
    echo "• Config Headplane: headplane-config.yaml"
    if [[ "$ENABLE_SSL" == "true" ]]; then
        echo "• Caddyfile: Caddyfile"
    fi
    echo "• Datos: $DATA_DIR/"
    echo ""

    print_success "¡Disfruta de tu red privada virtual!"
}

# -----------------------------------------------------------------------------
# FUNCIÓN PRINCIPAL
# -----------------------------------------------------------------------------

main() {
    clear

    echo -e "${CYAN}${BOLD}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════════╗
║                                                                           ║
║   ██╗  ██╗███████╗ █████╗ ██████╗ ███████╗ ██████╗ █████╗ ██╗     ███████╗║
║   ██║  ██║██╔════╝██╔══██╗██╔══██╗██╔════╝██╔════╝██╔══██╗██║     ██╔════╝║
║   ███████║█████╗  ███████║██║  ██║███████╗██║     ███████║██║     █████╗  ║
║   ██╔══██║██╔══╝  ██╔══██║██║  ██║╚════██║██║     ██╔══██║██║     ██╔══╝  ║
║   ██║  ██║███████╗██║  ██║██████╔╝███████║╚██████╗██║  ██║███████╗███████╗║
║   ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═════╝ ╚══════╝ ╚═════╝╚═╝  ╚═╝╚══════╝╚══════╝║
║                                                                           ║
║                        + HEADPLANE WEB UI                                 ║
║                                                                           ║
║              Instalador Interactivo Todo-en-Uno v1.0                     ║
║                                                                           ║
╚═══════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"

    print_info "Este instalador configurará Headscale + Headplane con un solo comando"
    print_info "Responde las preguntas a continuación (puedes usar valores por defecto)"
    echo ""

    # Verificar si es una reconfiguración
    local is_reconfigure=false
    if [ -f "$ENV_FILE" ]; then
        echo ""
        print_warning "Se detectó una instalación existente"
        if ask_yes_no "¿Deseas reconfigurar la instalación existente?" "n"; then
            is_reconfigure=true
            print_info "Modo reconfiguración activado"
            print_warning "Los datos existentes se mantendrán, solo se actualizará la configuración"
            echo ""
        else
            print_info "Continuando con la instalación existente..."
            exit 0
        fi
    fi

    # 1. Verificar dependencias
    check_dependencies

    # 2. Cargar configuración existente (si existe y no es reconfiguración)
    if ! $is_reconfigure; then
        load_existing_config || true
    else
        # En modo reconfiguración, cargar siempre la config existente como base
        set -a
        source "$ENV_FILE"
        set +a
    fi

    # 3. Configuración interactiva
    configure_network
    configure_ports
    compute_public_urls
    configure_tailnet
    configure_oidc

    # 4. Generar secretos
    generate_secrets

    # 5. Generar archivos de configuración
    generate_env_file
    create_data_dirs
    generate_headscale_config
    generate_headplane_config
    generate_caddyfile
    generate_compose_override

    # 6. Desplegar
    echo ""
    if ask_yes_no "¿Deseas desplegar el stack ahora?" "y"; then
        # Fase 1: sólo Headscale, para poder emitir la API key
        start_headscale_first
        bootstrap_headscale

        # Regenerar la config de Headplane ya con la API key inyectada
        generate_headplane_config

        # Fase 2: resto del stack (Headplane y, si procede, Caddy)
        deploy_stack
        show_access_info
    else
        print_info "Configuración completada pero no desplegada"
        print_info "Para desplegar manualmente, ejecuta:"
        if [[ "$ENABLE_SSL" == "true" ]]; then
            echo -e "  ${YELLOW}docker compose --profile ssl up -d${NC}"
        else
            echo -e "  ${YELLOW}docker compose up -d${NC}"
        fi
    fi

    echo ""
}

# Ejecutar main
main "$@"
