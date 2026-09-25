# proyecto-devops-lambda

Formulario de contacto serverless en AWS, desplegado con Terraform desde un
pipeline de GitHub Actions que usa GitFlow y autenticación federada OIDC —
sin ninguna credencial estática almacenada.

No es solo el formulario: el objetivo del proyecto es el **camino completo
desde un `git push` hasta producción**, con dos ambientes aislados, control
de acceso a los datos y análisis de calidad como puerta de entrada.

---

## Contenido

- [Arquitectura](#arquitectura)
- [Ambientes](#ambientes)
- [Flujo de trabajo (GitFlow)](#flujo-de-trabajo-gitflow)
- [El pipeline](#el-pipeline)
- [Autenticación sin llaves estáticas](#autenticación-sin-llaves-estáticas)
- [Acceso a los datos](#acceso-a-los-datos)
- [Calidad de código](#calidad-de-código)
- [Levantar el proyecto desde cero](#levantar-el-proyecto-desde-cero)
- [Operación diaria](#operación-diaria)
- [Decisiones de diseño](#decisiones-de-diseño)
- [Costo](#costo)

---

## Arquitectura

```
Navegador
   │
   ├─── GET  ───►  S3 (sitio web estático)        el frontend
   │
   └─── POST ───►  Lambda Function URL            la API
                        │
                        └──►  DynamoDB            persistencia
```

Sin API Gateway, sin VPC, sin servidores. Todo escala a cero cuando nadie lo
usa, que es justamente lo que mantiene el costo en el nivel gratuito.

| Componente | Servicio | Detalle |
|---|---|---|
| Frontend | S3 + *website hosting* | HTML plano, sin build |
| API | Lambda + Function URL | Node.js 20, 128 MB, 3 s |
| Datos | DynamoDB | capacidad aprovisionada 1/1 |
| Infraestructura | Terraform | estado remoto en S3 + candado en DynamoDB |
| Pipeline | GitHub Actions | 4 jobs, despliegue por rama |

La URL de la API **no está escrita en el frontend**: el pipeline la lee del
*output* de Terraform y la inyecta en el `index.html` antes de publicarlo.
Cada ambiente termina apuntando a su propio backend sin intervención manual.

---

## Ambientes

Tres ambientes completos y aislados, en **regiones distintas a propósito** —
así un error de región nunca alcanza a los otros, y el nivel gratuito de
DynamoDB (25 RCU/WCU **por región**) no se reparte entre ellos.

| | ALPHA | TEST | PRODUCCIÓN |
|---|---|---|---|
| Región | `us-west-2` | `us-east-2` | `us-east-1` |
| Workspace de Terraform | `alpha` | `test` | `prod` |
| Lambda | `ContactoAPI_alpha` | `ContactoAPI_test` | `ContactoAPI_prod` |
| Tabla | `TablaContactosForm-alpha` | `TablaContactosForm-test` | `TablaContactosForm-prod` |
| Rol del pipeline | `gha-deploy-alpha` | `gha-deploy-test` | `gha-deploy-prod` |
| Se despliega desde | `feature/**`, `hotfix/**` | `develop`, `release/**` | `master` |
| Para qué sirve | trabajo en curso | lo integrado, lo valida QA | lo que usa la gente |

**Por qué ALPHA y TEST están separados.** Varias ramas de trabajo comparten
ALPHA y se pisan entre sí: eso está bien, es trabajo en curso. Lo que no puede
pasar es que pisen el ambiente donde QA valida lo que ya está integrado. Con un
solo ambiente para las dos cosas, la rama de un compañero sobrescribe aquello
que otro está probando.

Y no es solo convención: `gha-deploy-test` **no confía** en las ramas
`feature/*`, así que una feature no puede tocar TEST aunque alguien lo intente
desde el workflow. Quien lo impide es AWS al validar el token.

**Frontend TEST**
`http://form-devops-frontend--testf09ad3e4.s3-website.us-east-2.amazonaws.com`

**Frontend PRODUCCIÓN**
`http://form-devops-frontend--prod8c68f84f.s3-website-us-east-1.amazonaws.com`

Los *endpoints* de sitio web de S3 son HTTP: no soportan HTTPS. Para tener
certificado propio haría falta CloudFront delante, que está fuera del alcance
de este POC.

---

## Flujo de trabajo (GitFlow)

```
feature/**  ──push──►  ALPHA        trabajo en curso, cada quien el suyo
hotfix/**   ──push──►  ALPHA        correcciones urgentes, validadas antes de prod
     │
     └──PR + aprobación──►  develop  ──push──►  TEST   integración, lo valida QA
                   │
                   └─►  release/X.Y.Z  ──push──►  TEST  +  PR automático
                              │
                              └─[mergeás el PR]─►  master  ──►  PRODUCCIÓN
                                                      │         +  tag vX.Y.Z
                                                      │         +  Release
                                                      └─back-merge automático─►  develop
```

Reglas:

- **Nada se trabaja directo en `master` ni en `develop`.** Toda rama nace de
  `develop`, salvo los `hotfix/**`, que nacen de `master` y se mergean a
  ambas. En `develop` esto no es una convención: la rama está **protegida** y
  GitHub rechaza cualquier push directo.
- **A `develop` se entra por Pull Request aprobado.** El archivo
  [`.github/CODEOWNERS`](.github/CODEOWNERS) define quién puede aprobarlo. Los
  PR de feature se mergean con **«Squash and merge»**: cada funcionalidad entra
  como un commit, y `develop` se lee como una lista de features.
- **Tres ambientes, y la separación importa.** `alpha` es trabajo en curso y
  las ramas se pisan entre sí a propósito; `test` solo recibe lo ya integrado,
  así que es estable para que QA valide. Con un único ambiente, la rama de un
  compañero sobrescribe aquello que otro está probando.
- **A producción se entra solo por Pull Request.** El pipeline lo abre solo
  cuando el despliegue a TEST de la rama `release/**` termina bien: el PR es
  la señal de que la release está validada, no de que alguien la empujó.
- Dentro de `develop` los merges son **fast-forward**. El merge del PR a
  `master` sí genera un commit de merge — es inevitable, GitHub no tiene un
  botón de fast-forward — y por eso existe el back-merge del punto siguiente.
- **`develop` nunca queda atrás.** Tras cada despliegue a producción, el job
  `sincronizar_develop` mergea `master` de vuelta a `develop` y lo pushea. Sin
  eso, el commit de merge del PR vive solo en `master` y la siguiente rama
  nace sin él.
- **El tag lo genera el pipeline**, no una persona: al terminar un despliegue
  exitoso a producción, lee el último tag `v*`, incrementa el *patch* y
  publica el Release en GitHub. Nunca se crean tags a mano — en particular,
  **no uses `git flow release finish`**, que crea el tag por su cuenta y
  dejaría dos tags para la misma versión.

### Ciclo completo

```bash
git checkout develop && git pull
git flow feature start mi-cambio

# ... trabajar, commitear ...
git push -u origin feature/mi-cambio      # → despliega en TEST

# probar en el frontend de TEST, y cuando esté listo, integrar:
git checkout develop && git merge --ff-only feature/mi-cambio && git push
git branch -d feature/mi-cambio
git push origin --delete feature/mi-cambio

# cortar la release: se valida en TEST y el pipeline abre el PR hacia master
git flow release start 1.0.8
git push -u origin release/1.0.8

# → revisar el PR que apareció solo, y mergearlo desde GitHub
#   eso despliega PRODUCCIÓN, crea el tag y sincroniza develop hacia atrás

git checkout develop && git pull          # trae el back-merge del pipeline
git branch -d release/1.0.8
git push origin --delete release/1.0.8
```

La rama `release/**` no lleva un *bump* de versión: el número lo calcula el
pipeline desde el último tag. El nombre de la rama es solo para leerlo.

### Revisión por Pull Request

El ciclo de arriba mergea en local. Cuando el cambio necesita revisión, el
merge lo hace GitHub al aprobar un Pull Request:

```bash
git push -u origin feature/mi-cambio      # → despliega en TEST
gh pr create --base develop --head feature/mi-cambio
```

Abrir el PR **no despliega nada**: los jobs de despliegue comparan
`github.ref` contra `refs/heads/...`, y en un evento `pull_request` el ref es
`refs/pull/N/merge`, así que solo corre el análisis de SonarCloud. El
despliegue ocurre al mergear, con el `push` a la rama destino.

El PR hacia `master` **no hay que crearlo a mano**: lo abre el job
`abrir_pr_master` al pushear una rama `release/**`, y solo si el despliegue a
TEST pasó. Un PR abierto se actualiza solo con cada push a su rama, así que el
job no crea uno nuevo si ya existe.

Ese PR automático **no ejecuta sus propios checks**, porque GitHub no encadena
workflows a partir de acciones hechas con `GITHUB_TOKEN`: es su defensa contra
bucles infinitos. Lo que se ve en la práctica no es «ninguna corrida», sino una
corrida de `pull_request` detenida en `action_required` — esperando una
aprobación manual que nadie da — que termina marcada en rojo **con cero jobs
ejecutados**.

Ese rojo no significa que la release esté rota: no corrió nada, así que no
falló nada. La validación real ya ocurrió en el push a la rama `release/**`,
que es justamente lo que habilitó que el PR se abriera. Mirá esa corrida, no
la del PR.

**Requisito de la organización.** Para que el job pueda abrir el PR hace falta
*Settings de la organización → Actions → General → «Allow GitHub Actions to
create and approve pull requests»*. Es una política de organización: mientras
esté apagada, el interruptor del repositorio no se puede activar (la API
responde `409 Conflict`). Sin ese permiso el job **no falla**: avisa con un
`::warning::` y deja el enlace del PR en el resumen de la corrida, porque el
despliegue a TEST sí pasó y eso es lo que de verdad valida la release.

Ese mismo interruptor habilita crear **y aprobar** PRs. Hoy no agrega riesgo
porque ninguna rama exige aprobaciones; si alguna vez se configura *branch
protection* con revisores obligatorios, conviene revisarlo.

La GUI de GitFlow (repo `gui-gitflow`) cubre este flujo completo sin salir de
la ventana: crea y publica ramas de `feature`, `release` y `hotfix`, arma el
enlace del PR con origen y destino ya elegidos, publica la rama si todavía no
está en el remoto, y muestra las últimas corridas del pipeline. Lee los nombres
de rama de la configuración de git-flow del repositorio, así que no está atada a
`master`/`develop`.

Lo único que no hace es **mergear el PR**: ese es el punto donde decide una
persona.

---

## El pipeline

Archivo: [`.github/workflows/ci-cd.yml`](.github/workflows/ci-cd.yml)

| Job | Cuándo corre | Qué hace |
|---|---|---|
| `sonarcloud_quality_gate` | siempre | Análisis estático. **Bloqueante solo en `master`** |
| `deploy_alpha` | `feature/**`, `hotfix/**` | `terraform apply` en `us-west-2` |
| `deploy_test` | `develop`, `release/**` | `terraform apply` en `us-east-2` |
| `deploy_prod` | `master` | `terraform apply` en `us-east-1` |
| `release` | tras un `deploy_prod` exitoso | Calcula la versión, crea el tag y el Release |
| `abrir_pr_master` | tras un `deploy_test` exitoso de `release/**` | Abre el PR hacia `master` si no existe ya |
| `sincronizar_develop` | tras un `release` exitoso | Mergea `master` de vuelta a `develop` |

### Inyección de la URL de la API

El paso que evita tener el *endpoint* escrito a mano en el código:

1. Se consulta `terraform output -raw api_url`. Si el ambiente ya existe, la
   URL se conoce **antes** de aplicar y basta un solo `apply`.
2. Un `sed` reemplaza el marcador `URL_API_PLACEHOLDER` en el `index.html`.
3. `terraform apply` publica el archivo ya resuelto.

Solo el **primer** despliegue de un ambiente necesita dos `apply`: la URL no
existe hasta que la Lambda se crea.

Dos validaciones protegen ese mecanismo:

- Antes de inyectar, se exige que el marcador aparezca **exactamente una vez**.
  El `sed` reemplaza todas las ocurrencias, así que una segunda dentro de una
  comparación del JavaScript la dejaría apuntando contra sí misma.
- Después de inyectar, se verifica que **no quede ningún marcador sin
  reemplazar**, para no publicar un frontend sin destino.

### Concurrencia

Cada ambiente tiene su grupo de concurrencia (`deploy-test`, `deploy-prod`).
Dos ramas que se pushean a la vez se serializan en lugar de pelear por el
candado del estado de Terraform.

---

## Autenticación sin llaves estáticas

**En este repositorio no hay ningún secreto de AWS.** El pipeline no guarda
`AWS_ACCESS_KEY_ID` ni `AWS_SECRET_ACCESS_KEY`.

Cada job presenta un token que GitHub firma en el momento y que declara de qué
repositorio y rama viene. AWS lo verifica contra GitHub y devuelve credenciales
temporales de una hora.

```
GitHub emite un token efímero  →  AWS valida la firma y el origen
                               →  credenciales temporales (1 h)
                               →  el job termina y desaparecen
```

Definición: [`terraform/iam/oidc.tf`](terraform/iam/oidc.tf)

### Separación por rama, garantizada por AWS

Hay **dos roles**, no uno, y cada uno confía en un conjunto distinto de ramas:

| Rol | Ramas que pueden asumirlo | Alcance de los permisos |
|---|---|---|
| `gha-deploy-alpha` | `feature/*`, `hotfix/*` | solo recursos `*_alpha` |
| `gha-deploy-test` | `develop`, `release/*` | solo recursos `*_test` |
| `gha-deploy-prod` | **`master` únicamente** | solo recursos `*_prod` |

Esto importa: si alguien crea una rama con un workflow modificado que intente
desplegar en producción, **AWS rechaza el token**. La restricción no depende de
un `if` del pipeline, que se podría editar desde esa misma rama.

El filtro trabaja sobre el claim `sub` del token, que describe el origen:

```
repo:lvasqvera/proyecto-devops-lambda:ref:refs/heads/master
```

La política acepta **dos formatos** de ese claim: el plano y el que lleva los
identificadores numéricos incrustados. GitHub usa el segundo para cuentas que
fueron renombradas alguna vez, y la documentación oficial solo muestra el
primero.

### Variables del repositorio

Ninguna es un secreto: un ARN identifica, no autentica.

| Variable | Contenido |
|---|---|
| `AWS_ROLE_TEST` | ARN del rol de test |
| `AWS_ROLE_PROD` | ARN del rol de producción |

El único secreto del repositorio es `SONAR_TOKEN`.

---

## Acceso a los datos

Definición: [`terraform/iam/main.tf`](terraform/iam/main.tf)

El grupo `desarrolladores` implementa una regla simple: **en test se prueba
escribiendo, en producción no se escribe a mano**.

| Ambiente | Permiso |
|---|---|
| TEST | lectura y escritura |
| PRODUCCIÓN | **solo lectura** |

La prohibición de escribir en producción es un **`Deny` explícito**, no la
simple ausencia del permiso. Un `Deny` gana sobre cualquier `Allow`, así que
sigue vigente aunque más adelante se le adjunte al grupo una política más
amplia. Un intento de inserción devuelve:

```
AccessDeniedException: ... with an explicit deny in an identity-based policy
```

El control vive en IAM, así que aplica igual desde la consola de AWS, desde la
CLI o desde cualquier cliente gráfico.

> Este directorio **no lo aplica el pipeline**, a propósito: los accesos de
> personas no deben crearse ni destruirse solos en cada push. Se aplica a mano
> y queda versionado para auditoría.

---

## Calidad de código

Análisis estático con SonarCloud en cada push, sobre `backend/` y `frontend/`.

- Organización `lvasqvera`, proyecto `lvasqvera_proyecto-devops-lambda`
- **Bloqueante solo en `master`**: en ramas de desarrollo informa sin frenar
- El plan gratuito **analiza únicamente la rama principal**; los escaneos de
  otras ramas se aceptan pero sus datos no son consultables

---

## Levantar el proyecto desde cero

### Requisitos

- Terraform ≥ 1.10 (probado con 1.16)
- AWS CLI autenticada con permisos de administrador
- GitHub CLI (`gh`) autenticada

### 1. Estado remoto

Terraform guarda su estado en S3 con un candado en DynamoDB. Ese par debe
existir **antes** del primer `init`, porque no puede gestionarse a sí mismo:

```bash
aws s3api create-bucket --bucket TU-BUCKET-DE-ESTADO --region us-east-1
aws s3api put-bucket-versioning --bucket TU-BUCKET-DE-ESTADO \
  --versioning-configuration Status=Enabled

aws dynamodb create-table --table-name terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1
```

Actualiza el bloque `backend "s3"` de `terraform/main.tf` con esos nombres.

### 2. Los dos ambientes

```bash
cd terraform
terraform init

terraform workspace new test
terraform apply -var="environment=test" -var="aws_region=us-east-2"

terraform workspace new prod
terraform apply -var="environment=prod" -var="aws_region=us-east-1"
```

### 3. Roles del pipeline y accesos

```bash
cd terraform/iam
terraform init
terraform apply
```

Si en la cuenta **no existe todavía** un proveedor OIDC para GitHub, hay que
crearlo. Compruébalo primero:

```bash
aws iam list-open-id-connect-providers
```

Si aparece `token.actions.githubusercontent.com`, ya existe y `oidc.tf` lo
referencia con un `data`. Si la lista vuelve vacía, cambia ese `data` por un
`resource` — es un recurso **de cuenta**, uno solo para todos los repos.

### 4. Conectar GitHub

```bash
gh variable set AWS_ROLE_TEST -b "$(terraform output -raw rol_deploy_test)"
gh variable set AWS_ROLE_PROD -b "$(terraform output -raw rol_deploy_prod)"
gh secret   set SONAR_TOKEN   -b "TU_TOKEN_DE_SONARCLOUD"
```

---

## Operación diaria

```bash
# Ver el estado de un ambiente
terraform workspace select test
terraform plan -var="environment=test" -var="aws_region=us-east-2"

# Consultar los registros guardados
aws dynamodb scan --table-name TablaContactosForm-test --region us-east-2 \
  --query "Items[].{nombre:nombre.S,email:email.S,mensaje:mensaje.S}" --output table

# Lo mismo con sintaxis SQL (PartiQL)
aws dynamodb execute-statement --region us-east-2 \
  --statement "SELECT nombre, email FROM \"TablaContactosForm-test\""

# Probar la API sin navegador
curl -X POST "$(terraform output -raw api_url)" \
  -H "Content-Type: application/json" \
  -d '{"nombre":"Prueba","email":"a@b.cl","mensaje":"hola"}'
```

**Un `plan` local puede mostrar el `index.html` como modificado.** Es
esperable: en tu disco el archivo conserva el marcador `URL_API_PLACEHOLDER`,
mientras que el publicado tiene la URL ya inyectada por el pipeline. No es
*drift* real.

---

## Decisiones de diseño

Las que no son obvias leyendo el código, con el motivo detrás.

### El objeto de S3 declara `etag`

```hcl
etag = filemd5("../frontend/index.html")
```

Sin esa línea Terraform **no detecta cambios de contenido** del archivo, y un
push que solo toca el frontend nunca llega a publicarse. El `apply` sale en
verde y el sitio queda con la versión anterior.

### El frontend no tiene URL de respaldo

Si el marcador no fue reemplazado, el formulario muestra un error de
despliegue en lugar de intentar con un *endpoint* fijo. Una URL de respaldo
haría que el frontend de un ambiente escribiera en la base del otro —
silenciosamente y sin ningún error.

La validación comprueba la **forma** de la URL, no el literal del marcador:

```javascript
if (!targetUrl || !targetUrl.startsWith("https://")) { ... }
```

Comparar contra el literal no funcionaría: el `sed` reemplaza todas las
ocurrencias, incluida la que estuviera dentro de la propia comparación.

### Espera antes de la política del bucket

```hcl
resource "time_sleep" "espera_public_access_block" {
  depends_on      = [aws_s3_bucket_public_access_block.public_access]
  create_duration = "20s"
}
```

El *Block Public Access* de S3 es eventualmente consistente. `depends_on`
ordena las llamadas pero no espera a que la desactivación propague, así que el
`PutBucketPolicy` salía milisegundos después y AWS lo rechazaba. Afecta solo al
primer despliegue de un ambiente nuevo.

### Comodín acotado por recurso

Las políticas del pipeline usan `lambda:*` y `dynamodb:*` sobre **ARNs
concretos**, nunca sobre `"*"`. Si el rol ya puede borrar la función,
restringirle además `UpdateFunctionCode` no protege de nada — y enumerar
acciones una por una se paga con corridas de CI fallidas.

### Regiones distintas por ambiente

No es capricho: obliga a que la configuración esté realmente parametrizada, y
garantiza que un error de región no pueda alcanzar al otro ambiente.

---

## Costo

Aproximadamente **USD 0** con el uso de un POC. Todo cae en el nivel gratuito,
y los dos primeros son permanentes, no de 12 meses:

| Servicio | Nivel gratuito | Uso real |
|---|---|---|
| Lambda | 1 M peticiones + 400 000 GB-s al mes | decenas de invocaciones |
| DynamoDB | 25 RCU + 25 WCU **por región** | 1 + 1 por tabla |
| S3 | 5 GB | un archivo de 3 KB |

El cupo de DynamoDB es por región, así que los dos ambientes no compiten entre
sí. No hay ningún recurso con costo fijo por hora: sin tráfico, el gasto tiende
a cero.
