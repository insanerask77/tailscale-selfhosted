# Quickstart - Headscale + Headplane

Guía de inicio rápido para tener Headscale + Headplane funcionando en menos de 5 minutos.

## 🚀 Instalación en 3 Pasos

### 1. Ejecutar el Instalador

```bash
./install.sh
```

### 2. Responder las Preguntas

La primera pregunta es el **modo de despliegue** y condiciona todas las demás:

| Modo | Elígelo si... |
|------|---------------|
| **`standalone`** | Es una sola máquina y no tienes nada delante. Caddy saca el certificado solo. **Empieza por aquí.** |
| **`proxy-single`** | Ya tienes Nginx Proxy Manager / Traefik y quieres un único dominio. |
| **`proxy-split`** | Quieres `ts.midominio.com` para el control plane y `admin.midominio.com` para la UI. |
| **`plain`** | Sólo LAN o desarrollo, sin cifrado. |

Después:

- **Dominio(s)**: `vpn.midominio.com`, o los dos dominios si elegiste `proxy-split`
- **Certificado** (sólo en `standalone`): Let's Encrypt (necesita DNS público
  ya apuntando aquí) o autofirmado
- **Acceso desde el proxy** (sólo en los modos `proxy-*`): interfaz donde
  publicar los puertos, CIDR del proxy y la IP de esta máquina vista por él
- **Puertos**: Enter para los valores por defecto
- **Nombre del Tailnet**: `myorg` (o el nombre de tu empresa)
- **¿OIDC?**: `n` (no, a menos que tengas Keycloak/Authentik)

### 3. ¡Listo!

Al finalizar verás la API key para entrar en Headplane y las dos URLs:

```
✓ Headscale + Headplane están corriendo
Modo de despliegue: standalone

Interfaz web (Headplane): https://vpn.midominio.com/admin
Control plane (Headscale): https://vpn.midominio.com
```

En los modos `proxy-*` esas URLs **todavía no responden**: falta configurar la
otra máquina. El instalador deja todo escrito en `reverse-proxy/`:

```bash
ls reverse-proxy/
# REVERSE-PROXY.md        guía paso a paso para Nginx Proxy Manager
# nginx-headscale.conf    para un Nginx que gestiones tú
# nginx-headplane.conf    (sólo en proxy-split)
```

Cópialos a la máquina del proxy y sigue `REVERSE-PROXY.md`.

---

## 📝 Primeros Pasos

### 1. Entrar en la UI Web

El instalador ya ha creado el usuario administrador y una **API key**, que
muestra por pantalla al terminar. Ábre la UI y pega esa key en el login:

```
https://vpn.midominio.com/admin          # standalone / proxy-single
https://admin.midominio.com/admin        # proxy-split
http://vpn.midominio.com:3000/admin      # plain
```

> Headplane sirve la interfaz bajo la ruta `/admin`. La raíz (`/`) devuelve 404.
> Sin OIDC, la API key es la única credencial: no hay usuario/contraseña.

### 2. Generar Clave de Conexión

```bash
./scripts/utils.sh preauth:create admin
```

O directamente, teniendo en cuenta que desde Headscale 0.29 `--user` espera el
**ID numérico** del usuario, no su nombre:

```bash
docker exec headscale headscale users list     # busca el ID de 'admin'
docker exec headscale headscale preauthkeys create \
  --user 1 \
  --reusable \
  --expiration 24h
```

Copia la clave que se muestra (empieza por `hskey-auth-`).

### 3. Conectar un Dispositivo

En tu ordenador/móvil con [Tailscale instalado](https://tailscale.com/download):

```bash
# Con TLS (standalone o proxy-*): el control plane vive en la raíz del dominio
tailscale up --login-server=https://ts.midominio.com --authkey=<tu-clave>

# Modo plain: hay que indicar el puerto de Headscale
tailscale up --login-server=http://vpn.midominio.com:8080 --authkey=<tu-clave>
```

> La URL exacta la muestra el instalador al terminar, y está en `.env` como
> `HEADSCALE_PUBLIC_URL`. **No es la misma** que la de la interfaz web.

---

## 🔧 Comandos Útiles

### Ver Estado

```bash
docker compose ps
```

### Ver Logs

```bash
# Todos los servicios
docker compose logs -f

# Solo Headscale
docker compose logs -f headscale
```

### Listar Dispositivos Conectados

```bash
docker exec headscale headscale nodes list
```

### Reiniciar Servicios

```bash
docker compose restart
```

### Detener Todo

```bash
docker compose down
```

### Iniciar de Nuevo

```bash
docker compose up -d
# O si tienes SSL habilitado:
docker compose --profile ssl up -d
```

---

## 🛠️ Script de Utilidades

Incluye un script con comandos útiles:

```bash
./scripts/utils.sh help

# Ejemplos:
./scripts/utils.sh status
./scripts/utils.sh users:create admin
./scripts/utils.sh preauth:create admin
./scripts/utils.sh backup
```

---

## ❓ Problemas Comunes

### "Connection refused" al acceder a la UI

**Solución**: Espera 30 segundos para que los servicios terminen de iniciar:

```bash
docker compose ps  # Verifica que estén "healthy"
```

### Con proxy externo: los dominios no responden

**Comprueba primero si el fallo está en el proxy o en el backend.** Desde la
máquina del proxy, saltándotelo:

```bash
curl -s http://<BACKEND_HOST>:8080/key?v=142      # Headscale
curl -sI http://<BACKEND_HOST>:3000/admin | head -1  # Headplane
```

- **Fallan los dos**: el problema está en la máquina de Headscale. Revisa el
  firewall y `BIND_ADDRESS` en `.env` (con `127.0.0.1` el proxy no llega).
- **Funcionan pero los dominios públicos no**: el problema está en el proxy.
  Revisa `reverse-proxy/REVERSE-PROXY.md`; lo más habitual es que falte
  *Websockets Support* o el `proxy_read_timeout` largo.

### Con proxy externo: los nodos se reconectan cada minuto

**Causa**: `/machine/map` es un long-poll permanente y el proxy lo corta con su
`proxy_read_timeout` por defecto (60 s).

**Solución**: en el bloque *Advanced* del proxy, `proxy_read_timeout 3600s;` y
`proxy_buffering off;` — ya vienen en los ficheros de `reverse-proxy/`.

### Let's Encrypt falla

**Causa**: DNS no apunta correctamente o puertos 80/443 bloqueados.

**Solución rápida**: Usa certificado autofirmado temporalmente:

```bash
./install.sh  # Re-ejecutar y elegir "autofirmado"
```

### `tailscale up` falla con `x509: certificate signed by unknown authority`

**Causa**: estás usando certificado autofirmado y el cliente Tailscale no
confía en la CA interna de Caddy. A diferencia del navegador, aquí no se puede
"aceptar el riesgo": no conecta.

**Solución**: instala `./caddy-root-ca.crt` (lo exporta el instalador) en el
dispositivo:

```bash
sudo cp caddy-root-ca.crt /usr/local/share/ca-certificates/
sudo update-ca-certificates
```

En móviles no es posible: usa Let's Encrypt. Ver
[README.md](README.md#certificado-autofirmado-hay-que-instalar-la-ca-en-cada-cliente).

### Error 500 `auth ID has invalid length: expected 38, got 101`

**Causa**: has pegado la **API key** (la del login, `hskey-api-…`, 87 caracteres)
en el diálogo *Register Machine Key* de Headplane. Ese campo sólo acepta el
**Auth ID** de 38 caracteres.

**Solución**: lanza `tailscale up` **sin** `--authkey` en el dispositivo:

```bash
tailscale up --login-server=https://vpn.midominio.com
# -> To authenticate, visit: .../register/hskey-authreq-XXXXXXXXXXXXXXXXXXXXXXXX
```

Pega en Headplane sólo el `hskey-authreq-…`. O sáltate la UI por completo usando
una pre-auth key con `--authkey` (paso 2 de arriba).

### Los dispositivos no se conectan entre sí

**Solución**: Verifica que el puerto UDP 3478 esté abierto:

```bash
sudo ufw allow 3478/udp
```

---

## 📚 Más Información

- Documentación completa: Ver [README.md](README.md)
- Troubleshooting detallado: [README.md#troubleshooting](README.md#troubleshooting)
- Reconfigurar: Re-ejecuta `./install.sh`
- Backup: `./scripts/utils.sh backup`

---

## 🗑️ Desinstalar

```bash
./uninstall.sh         # Mantiene datos
./uninstall.sh --purge # Elimina todo
```

---

**¡Eso es todo! Tu red privada VPN está lista para usar.**
