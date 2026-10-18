{
  "name": "{{app}}",
  "template": "{{template}}",
  "andaime_path": "{{andaimePath}}",
  "db": "{{db}}",
  "jobs": false,
  "layers": {
    "domain": { "modules": ["domain.*"], "may_import": ["andaime.http.optional"] },
    "usecases": { "modules": ["usecases.*"], "may_import": ["domain", "andaime.http.optional"] },
    "adapters": { "modules": ["adapters.*"], "may_import": ["usecases", "domain", "andaime.*"] },
    "main": { "modules": ["main", "app", "config", "jobs"], "may_import": ["*"] }
  }
}
