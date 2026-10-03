{{/*
_helpers.tpl — общие кусочки шаблонов («функции»). Файлы с «_» в начале Helm не превращает в ресурсы,
он только загружает из них определения. Вызываются так: {{ include "goapp.labels" . }}
*/}}

{{/*
Имя всех ресурсов = имя релиза (helm install <релиз> ...). У ArgoCD релиз задан в Application:
helm.releaseName: questlog → Deployment, Service, Ingress называются questlog.
*/}}
{{- define "goapp.name" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Метки-селекторы. ВАЖНО: spec.selector у Deployment менять нельзя (поле неизменяемое).
Поэтому здесь ровно та метка, что была в манифестах до перехода на Helm: app: <имя>.
*/}}
{{- define "goapp.selectorLabels" -}}
app: {{ include "goapp.name" . }}
{{- end -}}

{{/*
Полный набор меток — рекомендованные Kubernetes app.kubernetes.io/* плюс селекторные.
По ним видно, кто создал ресурс и какой версией чарта.
*/}}
{{- define "goapp.labels" -}}
{{ include "goapp.selectorLabels" . }}
app.kubernetes.io/name: {{ include "goapp.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
Образ целиком: repository:tag. required останавливает рендер с понятной ошибкой,
если в values приложения забыли указать образ или тег.
*/}}
{{- define "goapp.image" -}}
{{- $repo := required "image.repository обязателен — задай его в values приложения" .Values.image.repository -}}
{{- /* toString: тег из одних цифр (1234567) YAML прочитал бы как число */ -}}
{{- $tag := required "image.tag обязателен — его подставляет CI" .Values.image.tag | toString -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}
