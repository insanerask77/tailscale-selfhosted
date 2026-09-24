# Headscale + Headplane - Despliegue Todo-en-Uno

<div align="center">

![Headscale](https://img.shields.io/badge/Headscale-Latest-blue?logo=tailscale)
![Headplane](https://img.shields.io/badge/Headplane-Latest-green)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker)
![License](https://img.shields.io/badge/License-MIT-yellow)

**Solución de despliegue automatizado para Headscale (control plane self-hosted compatible con Tailscale) + Headplane (UI web moderna)**

[Instalación Rápida](#-instalación-rápida) • [Características](#-características) • [Configuración](#-configuración) • [Uso](#-uso) • [Troubleshooting](#-troubleshooting)

</div>

---

## 📋 Tabla de Contenidos

- [Acerca del Proyecto](#-acerca-del-proyecto)
- [Características](#-características)
- [Requisitos](#-requisitos)
- [Instalación Rápida](#-instalación-rápida)
- [Configuración](#-configuración)
  - [Modos de despliegue](#modos-de-despliegue)
- [Uso](#-uso)
- [Arquitectura](#-arquitectura)
- [Reconfiguración](#-reconfiguración)
- [Backup y Restauración](#-backup-y-restauración)
- [Troubleshooting](#-troubleshooting)
- [Desinstalación](#-desinstalación)
- [Contribuir](#-contribuir)
- [Licencia](#-licencia)

---

## 🎯 Acerca del Proyecto

Este proyecto proporciona un **instalador interactivo todo-en-uno** que despliega:

- **[Headscale](https://github.com/juanfont/headscale)**: Control plane open-source compatible con Tailscale
- **[Headplane](https://github.com/tale/headplane)**: Interfaz web moderna para gestionar Headscale
- **[Caddy](https://caddyserver.com/)** (opcional): Reverse proxy con TLS automático

Todo funcional con **un solo comando** (`./install.sh`), sin necesidad de editar archivos de configuración manualmente.

### ¿Por qué usar esto?

✅ **Cero configuración manual**: El instalador te guía paso a paso  
✅ **SSL automático**: Certificados Let's Encrypt o autofirmados  
✅ **OIDC integrado**: Autenticación con Keycloak, Authentik, etc.  
✅ **Idempotente**: Puedes reconfigurar sin perder datos  
✅ **Producción ready**: Configuración segura por defecto  

---

## ✨ Características

### 🚀 Instalación

- ✅ Instalador interactivo en bash puro (sin dependencias adicionales)
- ✅ Detección automática de distribución Linux (Debian/Ubuntu, Fedora/RHEL, Arch)
- ✅ Instalación automática de Docker si no está presente
- ✅ Validación de inputs con valores por defecto sensatos
- ✅ Generación automática de secretos criptográficos
- ✅ Idempotente: ejecutar múltiples veces es seguro

### 🔐 Seguridad

- ✅ SSL/TLS con Let's Encrypt (certificado automático)
- ✅ Certificado autofirmado para redes privadas
- ✅ Headers de seguridad (HSTS, X-Frame-Options, etc.)
- ✅ Secretos generados automáticamente (nunca hardcodeados)
- ✅ Autenticación OIDC opcional (Keycloak, Authentik, etc.)
- ✅ Contenedores con mínimos privilegios (cap_drop, security_opt)

### 🎨 Interfaz

- ✅ UI web moderna (Headplane) para gestionar Headscale
- ✅ Modo integrado: acceso completo a todas las funciones de Headscale
- ✅ Gestión de usuarios, nodos, rutas, ACLs desde la web
- ✅ Tema claro/oscuro automático

### 🛠️ Operación

- ✅ Docker Compose v2 (última versión)
- ✅ Healthchecks para todos los servicios
- ✅ Logs estructurados en JSON
- ✅ Volúmenes persistentes para datos críticos
- ✅ Reinicio automático de contenedores
- ✅ Desinstalador con opción de purga total

---

## 📦 Requisitos

### Mínimos

- **Sistema Operativo**: Linux (Debian/Ubuntu, Fedora/RHEL, Arch, o cualquier distro con Docker)
- **Docker**: >= 20.10 (se instala automáticamente si falta)
- **Docker Compose**: plugin v2 (se instala con Docker)
- **RAM**: >= 1GB
- **Disco**: >= 2GB libres
- **Puertos**:
  - `80/tcp` y `443/tcp` (si SSL habilitado)
  - `3000/tcp` (si SSL deshabilitado)
  - `3478/udp` (DERP/STUN, debe ser accesible externamente)

### Recomendados

- **Dominio**: con DNS apuntando al servidor (para Let's Encrypt)
- **RAM**: >= 2GB
- **CPU**: >= 2 cores

### Opcional

- **OIDC Provider**: Keycloak, Authentik, Auth0, etc. (para autenticación centralizada)

---

## 🚀 Instalación Rápida

### Opción 1: Instalación Interactiva (Recomendada)

```bash
# 1. Clonar el repositorio
git clone https://github.com/tu-usuario/tailscale-selfhosted.git
cd tailscale-selfhosted

# 2. Ejecutar el instalador interactivo
./install.sh

# 3. ¡Listo! Accede a la URL mostrada al final
```

El instalador te preguntará:
- Dominio o IP de acceso
- ¿Habilitar SSL? (con Let's Encrypt o certificado autofirmado)
- Puertos a usar (con defaults razonables)
- Nombre de tu organización/tailnet
- ¿Integrar OIDC? (opcional)

Al finalizar, los servicios estarán corriendo y listos para usar.

### Opción 2: Instalación Silenciosa (Avanzada)

Si prefieres configurar manualmente:

```bash
# 1. Clonar el repositorio
git clone https://github.com/tu-usuario/tailscale-selfhosted.git
cd tailscale-selfhosted

# 2. Copiar y editar el archivo de configuración
cp .env.example .env
nano .env

# 3. Generar configuraciones
export $(cat .env | xargs)
envsubst < templates/headscale-config.yaml.tmpl > headscale-config.yaml
envsubst < templates/headplane-config.yaml.tmpl > headplane-config.yaml
envsubst < templates/Caddyfile.tmpl > Caddyfile  # Si SSL habilitado

# 4. Levantar los servicios
docker compose --profile ssl up -d  # Con SSL
# O
docker compose up -d  # Sin SSL
```

---

## ⚙️ Configuración

### Modos de despliegue

Lo primero que pregunta el instalador. La respuesta determina quién termina
TLS, si arranca Caddy y cuántos dominios hacen falta:

| Modo | Quién termina TLS | Dominios | Caddy | Cuándo usarlo |
|------|-------------------|----------|-------|---------------|
| **`standalone`** | Caddy, en esta máquina | 1 | ✅ arranca | Una sola máquina, sin nada delante. Lo más simple. |
| **`proxy-single`** | Proxy externo | 1 | ❌ | Ya tienes NPM/Traefik y quieres un único dominio. |
| **`proxy-split`** | Proxy externo | 2 | ❌ | Control plane y UI en dominios distintos. |
| **`plain`** | Nadie (HTTP) | 1 | ❌ | LAN de confianza y desarrollo. |

En **todos** los modos la interfaz web se sirve bajo **`/admin`**: el prefijo
está compilado en la imagen de Headplane y no se puede quitar con un rewrite
en el proxy.

**`standalone`** — todo en una máquina:

```
cliente ──HTTPS──▶ Caddy ─┬─▶ /       Headscale
                          └─▶ /admin  Headplane
```

**`proxy-single`** — un dominio, proxy en otra máquina:

```
cliente ──HTTPS──▶ NPM ─┬─▶ HTTP  backend:8080  Headscale   (vpn.midominio.com/)
                        └─▶ HTTP  backend:3000  Headplane   (vpn.midominio.com/admin)
```

**`proxy-split`** — dos dominios (necesita CORS):

```
cliente ──HTTPS──▶ NPM ─┬─▶ ts.midominio.com    ─▶ HTTP backend:8080  Headscale
                        └─▶ admin.midominio.com ─▶ HTTP backend:3000  Headplane
```

En los dos modos `proxy-*` el instalador escribe en `reverse-proxy/` los
ficheros de Nginx ya rellenados y una guía paso a paso para Nginx Proxy
Manager (`REVERSE-PROXY.md`). Cópialos a la máquina del proxy.

> ⚠️ **El puerto UDP DERP (3478) no pasa por ningún reverse proxy HTTP.**
> Ábrelo directamente contra la máquina de Headscale, o desactiva
> `derp.server.enabled` en `headscale-config.yaml` y usa los relays públicos
> de Tailscale.

> ⚠️ En los modos `proxy-*` y `plain`, los puertos 8080 y 3000 se publican
> **sin cifrar**. Restringe el acceso por firewall a la IP del proxy
> (el instalador la pide como `PROXY_CIDR`).

### Variables de Entorno Principales

El archivo `.env` (generado por `install.sh`) contiene todas las configuraciones:

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `DEPLOY_MODE` | Modo de despliegue (ver tabla de arriba) | `standalone`, `proxy-split` |
| `SERVER_URL` | URL pública del control plane | `https://ts.midominio.com` |
| `HEADPLANE_PUBLIC_URL` | URL pública de la UI (la UI va en `/admin`) | `https://admin.midominio.com` |
| `ENABLE_SSL` | **Arrancar Caddy** (profile `ssl`), *no* "hay HTTPS" | `true` o `false` |
| `SSL_MODE` | Origen del certificado | `letsencrypt`, `selfsigned`, `external`, `none` |
| `ACME_EMAIL` | Email para Let's Encrypt | `admin@midominio.com` |
| `BACKEND_HOST` | IP de esta máquina vista desde el proxy | `192.168.1.10` |
| `PROXY_CIDR` | CIDR del proxy → `trusted_proxies` de Headscale | `192.168.1.50/32` |
| `BIND_ADDRESS` | Interfaz donde publicar los puertos sin Caddy | `0.0.0.0` |
| `TAILNET_NAME` | Nombre de la organización | `myorg` |
| `ENABLE_OIDC` | Habilitar autenticación OIDC | `true` o `false` |
| `OIDC_ISSUER_URL` | URL del proveedor OIDC | `https://auth.example.com/realms/master` |

> `ENABLE_SSL` tiene un nombre heredado y engañoso: significa "levantar el
> contenedor Caddy". En `proxy-single` y `proxy-split` vale `false` y **sí**
> hay HTTPS, sólo que lo termina el proxy externo.

Ver [.env.example](.env.example) para la lista completa de variables.

### Puertos Utilizados

| Puerto | Protocolo | Servicio | Descripción |
|--------|-----------|----------|-------------|
| 80 | TCP | Caddy | HTTP (redirección a HTTPS) — sólo `standalone` |
| 443 | TCP/UDP | Caddy | HTTPS / HTTP/3 — sólo `standalone` |
| 3000 | TCP | Headplane | Web UI (interno en `standalone`, publicado en el resto) |
| 3478 | UDP | Headscale | DERP/STUN — **siempre directo, nunca vía proxy** |
| 8080 | TCP | Headscale | API HTTP (interno en `standalone`, publicado en el resto) |
| 50443 | TCP | Headscale | gRPC (interno) |
| 9090 | TCP | Headscale | Metrics (interno, opcional) |

---

## 📖 Uso

### Primeros Pasos

El instalador ya crea el **usuario administrador** y la **API key**, y muestra
esta última por pantalla al terminar. Guárdala: Headscale sólo la revela en el
momento de crearla.

1. **Acceder a la UI web** y pegar la API key en el formulario de login:
   ```
   Abre en tu navegador: https://vpn.midominio.com/admin
   ```
   > Headplane sirve la interfaz bajo `/admin`; la raíz (`/`) devuelve 404.

2. **Generar una clave de pre-autenticación**:
   ```bash
   # Ojo: desde Headscale 0.29 --user espera el ID numérico, no el nombre
   docker exec headscale headscale users list      # busca el ID de 'admin'
   docker exec headscale headscale preauthkeys create \
     --user 1 \
     --reusable \
     --expiration 24h
   ```
   El helper acepta el nombre y resuelve el ID por ti:
   ```bash
   ./scripts/utils.sh preauth:create admin
   ```

3. **Conectar un dispositivo**:
   ```bash
   # En tu dispositivo con Tailscale instalado
   tailscale up --login-server=https://vpn.midominio.com --authkey=<tu-clave>
   ```

### Certificado autofirmado: hay que instalar la CA en cada cliente

Con `SSL_MODE=selfsigned`, Caddy firma con su CA interna. El navegador solo
muestra un aviso que puedes saltarte, pero **el cliente Tailscale directamente
se niega a conectar**:

```
Received error: fetch control key: Get "https://vpn.midominio.com/key?v=142":
x509: certificate signed by unknown authority
```

El instalador exporta la CA raíz a `./caddy-root-ca.crt`. Instálala en el
almacén de confianza de cada dispositivo **antes** de `tailscale up`:

```bash
# Linux (Debian/Ubuntu)
sudo cp caddy-root-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates

# macOS
sudo security add-trusted-cert -d -k /Library/Keychains/System.keychain caddy-root-ca.crt

# Windows (PowerShell como administrador)
Import-Certificate -FilePath caddy-root-ca.crt -CertStoreLocation Cert:\LocalMachine\Root
```

Si la pierdes:

```bash
docker exec caddy cat /data/caddy/pki/authorities/local/root.crt > caddy-root-ca.crt
```

> ⚠️ Android e iOS no permiten que Tailscale use CAs propias. Para móviles
> necesitas **Let's Encrypt** (`SSL_MODE=letsencrypt`), que no requiere instalar
> nada en el cliente.

### Las tres claves del stack (no las confundas)

Los tres tipos de clave empiezan por `hskey-` y es fácil pegar la que no toca.
Hacerlo produce un error 500 confuso del tipo
`auth ID has invalid length: expected 38, got 101`.

| Clave | Prefijo | Longitud | Para qué sirve |
|---|---|---|---|
| **API key** | `hskey-api-…` | 87 | Iniciar sesión en la UI de Headplane |
| **Pre-auth key** | `hskey-auth-…` | 88 | `tailscale up --authkey=…` |
| **Auth ID** | `hskey-authreq-…` | 38 | Lo único que acepta el diálogo *Register Machine Key* de Headplane |

El **Auth ID** no se genera con ningún comando: lo imprime `tailscale up` cuando
lo lanzas **sin** `--authkey`:

```bash
tailscale up --login-server=https://vpn.midominio.com
# -> To authenticate, visit: https://vpn.midominio.com/register/hskey-authreq-XXXXXXXXXXXXXXXXXXXXXXXX
```

Esa última parte (`hskey-authreq-…`, 38 caracteres) es lo que se pega en
Headplane. Si pegas la API key, Headplane le antepone `hskey-authreq-` por su
cuenta y Headscale rechaza la petición: 87 + 14 = 101 caracteres.

### Dos URLs distintas: control plane e interfaz web

Headscale y Headplane son servicios separados y **no comparten URL**:

| | Control plane (Headscale) | Interfaz web (Headplane) |
|---|---|---|
| **Con proxy** (`ENABLE_SSL=true`) | `https://vpn.midominio.com` | `https://vpn.midominio.com/admin` |
| **Sin proxy** (`ENABLE_SSL=false`) | `http://vpn.midominio.com:8080` | `http://vpn.midominio.com:3000/admin` |

La primera es la que va en `--login-server`. Con proxy, Caddy las sirve en el
mismo dominio y enruta por ruta: `/admin*` va a Headplane y **todo lo demás** a
Headscale, porque los clientes Tailscale usan la raíz del dominio (`/key`,
`/ts2021`, `/machine/*`, `/derp`, `/bootstrap-dns`…).

Sin proxy cada servicio se expone en su propio puerto, así que las URLs
**incluyen el puerto y son diferentes**. Ambas quedan guardadas en `.env` como
`HEADSCALE_PUBLIC_URL` y `HEADPLANE_PUBLIC_URL`.

### API key de Headplane

Sin OIDC, la única credencial para entrar en la UI es una API key de Headscale
(no hay usuario/contraseña propios). El instalador genera una y la guarda en
`.env`; si la pierdes:

```bash
docker exec headscale headscale apikeys create --expiration 90d
docker exec headscale headscale apikeys list
docker exec headscale headscale apikeys expire --prefix <prefijo>
```

> ⚠️ Da control total sobre el tailnet. Trátala como una contraseña de
> administrador y ten en cuenta que caduca (90 días por defecto,
> configurable con `APIKEY_EXPIRATION`).

### Gestión de Usuarios

```bash
# Listar usuarios
docker exec headscale headscale users list

# Crear usuario
docker exec headscale headscale users create <nombre>

# Eliminar usuario
docker exec headscale headscale users destroy <nombre>
```

### Gestión de Nodos

```bash
# Listar nodos
docker exec headscale headscale nodes list

# Listar nodos de un usuario
docker exec headscale headscale nodes list --user admin

# Eliminar nodo
docker exec headscale headscale nodes delete --identifier <id>

# Expirar nodo
docker exec headscale headscale nodes expire --identifier <id>
```

### Gestión de Rutas

```bash
# Listar rutas
docker exec headscale headscale routes list

# Aprobar ruta
docker exec headscale headscale routes enable --route <id>

# Desaprobar ruta
docker exec headscale headscale routes disable --route <id>
```

### Ver Logs

```bash
# Todos los servicios
docker compose logs -f

# Solo Headscale
docker compose logs -f headscale

# Solo Headplane
docker compose logs -f headplane

# Solo Caddy
docker compose logs -f caddy
```

### Estado de Servicios

```bash
# Ver estado
docker compose ps

# Reiniciar servicios
docker compose restart

# Detener servicios
docker compose down

# Iniciar servicios
docker compose up -d
```

---

## 🏗️ Arquitectura

### Diagrama de Flujo

```
Internet
    │
    │ HTTPS (443)
    ├─────────────────────┐
    │                     │
    │                     │ UDP (3478)
    │                     │ DERP/STUN
    ▼                     ▼
┌─────────┐         ┌──────────────┐
│  Caddy  │         │  Headscale   │
│ (Proxy) │────────▶│(Control Plane)│
└─────────┘         └──────────────┘
    │                     ▲
    │ HTTP (3000)         │ Unix Socket
    ▼                     │
┌─────────┐               │
│Headplane│───────────────┘
│ (Web UI)│  (Modo Integrated)
└─────────┘
```

### Componentes

1. **Headscale**: Control plane que gestiona la red mesh
   - Asigna IPs a los nodos
   - Gestiona ACLs y rutas
   - Proporciona servidor DERP embebido
   - Expone API gRPC para gestión

2. **Headplane**: Interfaz web moderna
   - Modo integrado: acceso directo al socket Unix de Headscale
   - Gestión completa de usuarios, nodos, rutas, ACLs
   - Autenticación local u OIDC

3. **Caddy**: Reverse proxy (opcional, solo si SSL habilitado)
   - Gestión automática de certificados Let's Encrypt
   - Redirección HTTP → HTTPS
   - Headers de seguridad
   - Proxy a Headplane

### Volúmenes

```
headscale-data/          → Base de datos SQLite y claves de Headscale
headscale-socket/        → Socket Unix para comunicación Headscale ↔ Headplane
caddy-data/              → Certificados SSL (Let's Encrypt)
caddy-config/            → Configuración persistente de Caddy
data/caddy-logs/         → Logs de acceso de Caddy
```

---

## 🔄 Reconfiguración

Para cambiar la configuración después de la instalación:

### Método 1: Re-ejecutar el Instalador

```bash
./install.sh
```

El instalador detectará la instalación existente y te permitirá reconfigurar sin perder datos.

### Método 2: Editar Manualmente

```bash
# 1. Editar variables de entorno
nano .env

# 2. Regenerar configuraciones (si cambiaste variables que afectan a los .yaml)
export $(cat .env | xargs)
envsubst < templates/headscale-config.yaml.tmpl > headscale-config.yaml
envsubst < templates/headplane-config.yaml.tmpl > headplane-config.yaml

# 3. Reiniciar servicios
docker compose down
docker compose --profile ssl up -d  # Ajustar según SSL
```

### Cambiar de modo de despliegue

Re-ejecuta el instalador y elige otro modo en la primera pregunta:

```bash
./install.sh
```

El instalador lee el `.env` actual, propone los valores existentes como
predeterminados y regenera todo lo que cambie: `headscale-config.yaml`,
`Caddyfile`, `docker-compose.override.yml` y `reverse-proxy/`. Al pasar de
`standalone` a un modo `proxy-*` también para y elimina el contenedor de
Caddy, que si no seguiría ocupando los puertos 80 y 443.

> ⚠️ Cambiar `SERVER_URL` (por ejemplo al pasar de `http://ip:8080` a
> `https://ts.midominio.com`) **invalida el registro de los nodos ya
> conectados**: apuntan a la URL antigua y tendrás que volver a ejecutar
> `tailscale up --login-server=<nueva-url>` en cada uno.

---

## 💾 Backup y Restauración

### ¿Qué Respaldar?

Es crítico respaldar:

1. **Base de datos de Headscale** (contiene usuarios, nodos, rutas):
   - `data/` (directorio completo)
   - O volumen Docker: `headscale-data`

2. **Configuraciones**:
   - `.env`
   - `headscale-config.yaml`
   - `headplane-config.yaml`

3. **Certificados SSL** (opcional, se regeneran automáticamente):
   - Volumen Docker: `caddy-data`

### Crear Backup

```bash
# Método 1: Backup de directorios locales
tar -czf headscale-backup-$(date +%Y%m%d).tar.gz \
  .env \
  headscale-config.yaml \
  headplane-config.yaml \
  data/

# Método 2: Backup de volúmenes Docker
docker run --rm \
  -v headscale-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/headscale-data-backup-$(date +%Y%m%d).tar.gz -C /data .
```

### Restaurar Backup

```bash
# 1. Detener servicios
docker compose down

# 2. Restaurar archivos
tar -xzf headscale-backup-YYYYMMDD.tar.gz

# 3. Restaurar volumen (si usaste método 2)
docker run --rm \
  -v headscale-data:/data \
  -v $(pwd):/backup \
  alpine sh -c "cd /data && tar xzf /backup/headscale-data-backup-YYYYMMDD.tar.gz"

# 4. Reiniciar servicios
docker compose --profile ssl up -d
```

### Automatizar Backups

Crear un cron job:

```bash
# Editar crontab
crontab -e

# Agregar backup diario a las 2 AM
0 2 * * * cd /ruta/a/tailscale-selfhosted && tar -czf /backups/headscale-backup-$(date +\%Y\%m\%d).tar.gz .env *.yaml data/
```

---

## 🔧 Troubleshooting

### Los servicios no inician

**Síntoma**: `docker compose ps` muestra contenedores detenidos o en estado "unhealthy"

**Solución**:
```bash
# Ver logs de todos los servicios
docker compose logs -f

# Ver logs de un servicio específico
docker compose logs -f headscale

# Verificar healthcheck
docker inspect headscale | grep -A 20 Health
```

### Puerto UDP 3478 bloqueado

**Síntoma**: Los clientes no pueden conectarse entre sí (solo al servidor)

**Verificación**:
```bash
# Verificar que el puerto está abierto
sudo netstat -unl | grep 3478

# Verificar firewall
sudo ufw status  # Ubuntu/Debian
sudo firewall-cmd --list-all  # Fedora/RHEL
```

**Solución**:
```bash
# Ubuntu/Debian
sudo ufw allow 3478/udp

# Fedora/RHEL
sudo firewall-cmd --permanent --add-port=3478/udp
sudo firewall-cmd --reload

# iptables directo
sudo iptables -A INPUT -p udp --dport 3478 -j ACCEPT
```

### Problemas específicos de los modos con proxy externo

| Síntoma | Causa | Solución |
|---------|-------|----------|
| Los nodos se desconectan y reconectan cada ~60 s | `/machine/map` es un long-poll y el proxy lo corta con su `proxy_read_timeout` por defecto | `proxy_read_timeout 3600s;` y `proxy_buffering off;` en el proxy |
| `tailscale up` se queda colgado sin error | `/ts2021` necesita un `Upgrade` de HTTP/1.1 | Activa *Websockets Support* en NPM, o las cabeceras `Upgrade`/`Connection` en Nginx |
| La UI carga en blanco | Se intentó quitar el prefijo `/admin` con un `rewrite` | Quita el rewrite: el prefijo está compilado en la imagen |
| La UI no puede hablar con la API (errores CORS en la consola) | Modo `proxy-split` sin cabeceras CORS | Aplica el bloque CORS de `reverse-proxy/nginx-headscale.conf` |
| Todos los nodos aparecen con la misma IP en los logs | Falta `trusted_proxies` | Pon el CIDR del proxy en `PROXY_CIDR` y re-ejecuta el instalador |
| El navegador pierde la sesión de Headplane al recargar | `SESSION_SECURE=false` sirviendo por HTTPS | Re-ejecuta el instalador: lo deriva de `URL_SCHEME` |
| Los nodos conectan pero no se ven entre sí | UDP 3478 cerrado (no pasa por el proxy) | Ábrelo directo contra la máquina de Headscale |

Comprobación rápida desde la máquina del proxy, saltándose el proxy:

```bash
# El control plane responde con su clave pública
curl -s http://<BACKEND_HOST>:8080/key?v=142

# La UI responde en /admin
curl -sI http://<BACKEND_HOST>:3000/admin | head -1
```

Si estos dos funcionan pero los dominios públicos no, el problema está en el
proxy; si fallan, está en la máquina de Headscale (firewall o `BIND_ADDRESS`).

### Let's Encrypt falla (DNS no propagado)

**Síntoma**: Caddy no puede obtener certificado, logs muestran error ACME

**Verificación**:
```bash
# Verificar que el DNS apunta correctamente
nslookup vpn.midominio.com

# Verificar que los puertos 80/443 son accesibles desde internet
# (desde otra máquina)
curl -I http://vpn.midominio.com
```

**Solución**:
```bash
# Opción 1: Esperar a que el DNS se propague (puede tomar hasta 48h)
# Caddy reintentará automáticamente

# Opción 2: Usar certificado autofirmado temporalmente
# Editar .env
SSL_MODE=selfsigned

# Regenerar Caddyfile y reiniciar
envsubst < templates/Caddyfile.tmpl > Caddyfile
docker compose restart caddy
```

### Headplane muestra "Connection refused"

**Síntoma**: Al acceder a la UI, aparece error de conexión

**Verificación**:
```bash
# Verificar que headscale está corriendo y healthy
docker compose ps headscale

# Verificar que el socket Unix existe
docker exec headplane ls -la /var/run/headscale/

# Verificar permisos del socket
docker exec headscale ls -la /var/run/headscale/headscale.sock
```

**Solución**:
```bash
# Reiniciar servicios en orden
docker compose restart headscale
sleep 10
docker compose restart headplane
```

### Error de permisos en socket Unix

**Síntoma**: Headplane no puede conectarse a Headscale, error de permisos en logs

**Solución**:
```bash
# Verificar configuración de permisos en headscale-config.yaml
# Debe tener:
# unix_socket_permission: "0770"

# Reiniciar Headscale
docker compose restart headscale
```

### Certificado autofirmado no es confiable

**Síntoma**: El navegador muestra advertencia de seguridad con certificado autofirmado

**Solución**:

Esto es **normal** con certificados autofirmados. Tienes 3 opciones:

1. **Aceptar la advertencia** (seguro en redes privadas):
   - Chrome/Edge: Clic en "Avanzado" → "Continuar"
   - Firefox: Clic en "Avanzado" → "Aceptar el riesgo"

2. **Instalar el certificado en tu sistema**:
   ```bash
   # Obtener certificado
   docker exec caddy cat /data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/vpn.midominio.com/vpn.midominio.com.crt > cert.crt
   
   # Instalar (varía según SO)
   # Ubuntu/Debian:
   sudo cp cert.crt /usr/local/share/ca-certificates/
   sudo update-ca-certificates
   
   # Firefox: Importar manualmente en Settings → Certificates
   ```

3. **Usar Let's Encrypt** (requiere dominio válido):
   ```bash
   ./install.sh  # Re-ejecutar y elegir Let's Encrypt
   ```

### Base de datos corrupta

**Síntoma**: Headscale no inicia, logs muestran error de SQLite

**Solución**:
```bash
# 1. Detener servicios
docker compose down

# 2. Hacer backup de la BD actual
docker run --rm \
  -v headscale-data:/data \
  -v $(pwd):/backup \
  alpine cp /data/db.sqlite /backup/db.sqlite.backup

# 3. Intentar reparar
docker run --rm \
  -v headscale-data:/data \
  alpine sh -c "cd /data && sqlite3 db.sqlite 'PRAGMA integrity_check;'"

# 4. Si falla, restaurar desde backup
# (o empezar de cero, perdiendo datos)

# 5. Reiniciar
docker compose up -d
```

### Los clientes no pueden comunicarse entre sí

**Síntoma**: Los clientes se conectan a Headscale pero no pueden hacer ping entre ellos

**Verificación**:
```bash
# 1. Verificar que los nodos están registrados
docker exec headscale headscale nodes list

# 2. Verificar rutas
docker exec headscale headscale routes list

# 3. Verificar ACLs (si están configuradas)
```

**Solución**:
```bash
# 1. Verificar que no hay ACLs bloqueando
# Editar headscale-config.yaml si es necesario

# 2. Verificar que el servidor DERP está funcionando
# Ver logs de headscale
docker compose logs -f headscale | grep DERP

# 3. Verificar que el puerto UDP 3478 está accesible (ver arriba)
```

---

## 🗑️ Desinstalación

### Detener servicios sin eliminar datos

```bash
docker compose down
```

### Desinstalación completa

```bash
# Ejecutar script de desinstalación
./uninstall.sh

# Responder 'yes' a la confirmación
```

### Desinstalación con purga total de datos

```bash
# Elimina también volúmenes, configuraciones y datos
./uninstall.sh --purge

# ⚠️ ADVERTENCIA: Esto es IRREVERSIBLE
```

---

## 🤝 Contribuir

Las contribuciones son bienvenidas. Para contribuir:

1. Fork el proyecto
2. Crea una rama para tu feature (`git checkout -b feature/AmazingFeature`)
3. Commit tus cambios (`git commit -m 'Add some AmazingFeature'`)
4. Push a la rama (`git push origin feature/AmazingFeature`)
5. Abre un Pull Request

### Roadmap

- [ ] Soporte para PostgreSQL como base de datos
- [ ] Script de migración desde instalaciones manuales
- [ ] Dashboard de monitoreo (Prometheus + Grafana)
- [ ] Soporte para alta disponibilidad (HA)
- [ ] Integración con más proveedores OIDC
- [ ] Script de actualización automática de versiones

---

## 📄 Licencia

Este proyecto está bajo la Licencia MIT. Ver el archivo [LICENSE](LICENSE) para más detalles.

---

## 🙏 Agradecimientos

- [Headscale](https://github.com/juanfont/headscale) - Control plane open-source
- [Headplane](https://github.com/tale/headplane) - UI web moderna
- [Tailscale](https://tailscale.com/) - Por crear el protocolo WireGuard mesh
- [Caddy](https://caddyserver.com/) - Servidor web con HTTPS automático

---

## 📞 Soporte

Si tienes problemas:

1. Revisa la sección [Troubleshooting](#-troubleshooting)
2. Busca en [Issues](https://github.com/tu-usuario/tailscale-selfhosted/issues) existentes
3. Abre un [nuevo Issue](https://github.com/tu-usuario/tailscale-selfhosted/issues/new) con:
   - Descripción del problema
   - Output de `docker compose logs`
   - Output de `docker compose ps`
   - Tu archivo `.env` (sin secretos)

---

<div align="center">

**[⬆ Volver arriba](#headscale--headplane---despliegue-todo-en-uno)**

Hecho con ❤️ para la comunidad open-source

</div>