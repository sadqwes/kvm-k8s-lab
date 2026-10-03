# goapp — Helm-чарт для моих Go-сервисов

Один чарт — два сервиса: **questlog** и **jobhunter**. Они устроены одинаково (distroless-образ, порт http и порт metrics, пробы `/readyz` и `/healthz`, ingress, ServiceMonitor), отличаются только образом, хостом и переменными окружения. Поэтому шаблоны общие, а различия — в двух values-файлах.

```
charts/goapp/
├── Chart.yaml              паспорт чарта: имя, версия чарта
├── values.yaml             значения по умолчанию — «настройки» с комментариями
├── .helmignore             что не класть в пакет чарта
└── templates/
    ├── _helpers.tpl        общие кусочки: имя, метки, образ (не становится ресурсом)
    ├── deployment.yaml     Deployment: образ, порты, env, пробы, ресурсы, securityContext
    ├── service.yaml        Service: порты http и metrics
    ├── ingress.yaml        Ingress — только если ingress.enabled
    ├── servicemonitor.yaml ServiceMonitor — только если включён и в кластере есть его CRD
    ├── NOTES.txt           текст, который helm печатает после install/upgrade
    └── tests/
        └── test-healthz.yaml  под для `helm test`: проверяет /healthz

gitops/platform/questlog/values.yaml    чем questlog отличается от умолчаний
gitops/platform/jobhunter/values.yaml   чем jobhunter отличается от умолчаний
```

## Что за что отвечает

**Chart.yaml** — метаданные. `version` — версия *чарта* (поменяла шаблоны → подняла версию), `appVersion` — версия *приложения* (у нас её фактически задаёт `image.tag`).

**values.yaml** — значения по умолчанию. В шаблонах они доступны как `.Values`: `{{ .Values.image.repository }}`.

**templates/** — обычные манифесты Kubernetes, в которые вставлены выражения Go-шаблонов `{{ … }}`. Helm подставляет значения и получает готовый YAML.

**_helpers.tpl** — «функции». `define` объявляет кусочек, `include` вставляет его:

```yaml
labels:
  {{- include "goapp.labels" . | nindent 4 }}
```

## Как собираются значения

Каждый следующий слой перекрывает предыдущий:

1. `charts/goapp/values.yaml` — общие умолчания;
2. `-f gitops/platform/questlog/values.yaml` — особенности сервиса;
3. `--set image.tag=abc1234` — точечно из командной строки.

Пример: `resources` в questlog не указаны → берутся умолчания чарта. `image.repository` указан в questlog → перекрывает пустое умолчание.

## Шпаргалка по синтаксису шаблонов

| Что | Пример | Зачем |
|---|---|---|
| Значение | `{{ .Values.replicaCount }}` | вставить настройку |
| Объекты | `.Release.Name`, `.Release.Namespace`, `.Chart.Version` | данные релиза и чарта |
| Обрезка пробелов | `{{-` и `-}}` | убрать лишние переносы строк |
| Условие | `{{- if .Values.ingress.enabled }} … {{- end }}` | создать ресурс по флагу |
| Цикл | `{{- range $name, $ref := .Values.secretEnv }}` | по списку или map |
| Контекст | `{{- with .Values.ingress.annotations }} … {{- end }}` | блок, только если значение не пустое |
| YAML-блок | `{{- toYaml .Values.resources \| nindent 12 }}` | вставить кусок values как есть, с нужным отступом |
| Обязательное | `{{ required "нужен image.tag" .Values.image.tag }}` | понятная ошибка вместо пустого поля |
| Кавычки | `{{ .Values.image.tag \| quote }}` | строка, а не число |
| Проверка API | `.Capabilities.APIVersions.Has "monitoring.coreos.com/v1"` | есть ли CRD в кластере |

## Команды

```bash
# проверить чарт на ошибки
helm lint charts/goapp -f gitops/platform/questlog/values.yaml

# посмотреть, какой YAML получится (ничего не ставит)
helm template questlog charts/goapp -f gitops/platform/questlog/values.yaml -n questlog \
  --api-versions monitoring.coreos.com/v1

# сравнить с тем, что сейчас в кластере (ничего не меняет)
helm template questlog charts/goapp -f gitops/platform/questlog/values.yaml -n questlog \
  --api-versions monitoring.coreos.com/v1 | kubectl diff -n questlog -f -
```

Команды для обычной установки через Helm (без ArgoCD) — знать для собеседования:

```bash
helm install   myapp charts/goapp -f values.yaml -n myapp --create-namespace
helm upgrade --install myapp charts/goapp -f values.yaml -n myapp   # поставить или обновить
helm history   myapp -n myapp        # история ревизий
helm rollback  myapp 2 -n myapp      # откат на ревизию 2
helm test      myapp -n myapp        # запустить тест из templates/tests
helm uninstall myapp -n myapp
helm get values myapp -n myapp       # какие values применены
```

## Как это работает в моей лабе (ArgoCD)

ArgoCD **не делает `helm install`**. Он рендерит чарт как `helm template` и применяет готовые манифесты сам. Поэтому:

- `helm list -A` не покажет questlog и jobhunter — release-секретов Helm в кластере нет;
- история и откат — через ArgoCD и Git (`git revert`), а не через `helm rollback`;
- хуки `helm test` ArgoCD не запускает — в values приложений тест выключен.

Application questlog собирается из **трёх источников** одного репозитория (multi-source):

1. `charts/goapp` — чарт, values берутся из `$values/gitops/platform/questlog/values.yaml`;
2. `ref: values` — ссылка на репозиторий, чтобы взять из него values-файл;
3. `gitops/platform/questlog` — всё, что не в чарте (SealedSecret'ы, CronJob бэкапа), кроме `values.yaml`.

CI после сборки образа меняет одно поле — `image.tag` в values-файле — через `yq`, коммитит в этот репозиторий, а ArgoCD видит коммит и обновляет Deployment.

## Ловушки, на которые я наткнулась

- **`spec.selector` у Deployment неизменяем.** При переходе с манифестов на чарт метка-селектор осталась прежней (`app: questlog`), иначе ArgoCD не смог бы обновить Deployment. Стандартные метки `app.kubernetes.io/*` добавлены только в `metadata.labels`.
- **Тег из цифр.** SHA вроде `1234567` YAML читает как число → в шаблоне `toString`, а CI пишет тег в кавычках.
- **Секреты не в чарте.** Чарт ссылается на Secret по имени (`secretEnv`), а сами секреты — SealedSecret'ы рядом с values. Так в Git не попадает ни одного открытого пароля.

## Вопросы с собеседования

**Что такое Helm и зачем он нужен?**
Пакетный менеджер для Kubernetes: шаблоны манифестов + значения. Один чарт можно поставить много раз с разными настройками (окружения, сервисы), а изменения версионируются как релизы с откатом.
*EN: Helm is a package manager for Kubernetes. A chart is a set of templates plus values, so one chart can be installed many times with different settings.*

**Из чего состоит чарт?**
`Chart.yaml` (метаданные), `values.yaml` (умолчания), `templates/` (шаблоны манифестов), `_helpers.tpl` (общие фрагменты), иногда `charts/` (зависимости) и `templates/tests/`.

**Чем `version` отличается от `appVersion`?**
`version` — версия чарта (шаблонов), `appVersion` — версия приложения внутри.

**Как переопределить значения?** `-f values.yaml` (несколько файлов — слоями, последний важнее) и `--set key=value`. Порядок: умолчания чарта → файлы `-f` → `--set`.

**`helm template` vs `helm install`?** `template` только печатает YAML и ничего не ставит (так работает ArgoCD); `install` ставит и создаёт релиз (секрет с историей в namespace).

**Как откатиться?** `helm history` + `helm rollback <релиз> <ревизия>`. В GitOps — откатом коммита в Git, ArgoCD вернёт состояние сам.

**Где хранить секреты?** Не в values в открытом виде. Варианты: SealedSecrets (как у меня), External Secrets, helm-secrets с SOPS. Чарт только ссылается на Secret по имени.

**Что такое хуки?** Аннотация `helm.sh/hook` (`pre-install`, `post-upgrade`, `test`…) — ресурс создаётся в определённый момент жизненного цикла, например миграции БД перед обновлением.

**Чем Helm отличается от Kustomize?** Helm — шаблоны и параметры (+ пакеты, релизы, хуки); Kustomize — накладывает патчи на обычный YAML без шаблонов. Часто используют вместе.

**Что ты сама писала?** «Общий чарт для двух своих Go-сервисов: Deployment, Service, Ingress и ServiceMonitor по флагам, `required` для обязательных значений, проверка CRD через `Capabilities`, тест через `helm test`. Деплой — ArgoCD multi-source: чарт + values из Git, CI меняет только `image.tag` через yq. При миграции с голых манифестов сохранила неизменяемый селектор Deployment».
