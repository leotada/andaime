import usecases.{{plural}};
import adapters.http.{{plural}} : {{Name}}Controller;
import adapters.memory.{{plural}} : Memory{{Name}}Repository;
{{#pg}}
import adapters.postgres.{{plural}} : Pg{{Name}}Repository;
{{/pg}}
